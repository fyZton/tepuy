"""Publica el cierre del archivo diario en Tepuy.publishPrice (31337, o testnets con CONFIRM_DEPLOY=yes)."""
import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from eth_account import Account
from web3 import Web3
from web3.exceptions import TimeExhausted

from oraculo.parser import ArchivoInvalido, leer, precio

RAIZ = Path(__file__).resolve().parent.parent
CHAIN_ID_LOCAL = 31337
CHAIN_IDS_PUBLICOS = {421614, 11155111}  # Arbitrum Sepolia, Sepolia


class ErrorPublicador(Exception):
    pass


def confirmado() -> bool:
    return os.environ.get("CONFIRM_DEPLOY") == "yes"


def validar_red(chain_id: int, escritura: bool = True) -> None:
    """31337 siempre; testnets públicas: escribir exige CONFIRM_DEPLOY=yes, leer no."""
    if chain_id == CHAIN_ID_LOCAL or (chain_id in CHAIN_IDS_PUBLICOS and (not escritura or confirmado())):
        return
    if chain_id in CHAIN_IDS_PUBLICOS:
        raise ErrorPublicador(f"La red {chain_id} es pública: escribir exige CONFIRM_DEPLOY=yes")
    raise ErrorPublicador(f"Red no permitida (chainId {chain_id}): solo {CHAIN_ID_LOCAL} (local), "
                          f"{sorted(CHAIN_IDS_PUBLICOS)} (testnets)")


def validar_rpc(rpc: str, remoto: bool | None = None) -> None:
    """Loopback siempre; remoto solo https y solo si `remoto` (por defecto: CONFIRM_DEPLOY=yes)."""
    u = urlparse(rpc)
    if u.hostname in ("127.0.0.1", "localhost", "::1"):
        return
    if not (confirmado() if remoto is None else remoto):
        raise ErrorPublicador("RPC no permitido: solo 127.0.0.1, localhost o ::1 (remoto exige CONFIRM_DEPLOY=yes)")
    if u.scheme != "https" or not u.hostname:
        raise ErrorPublicador("RPC remoto no permitido: solo https")


def preparar(datos: bytes, ticker: str) -> dict[str, Any]:
    """Pura: céntimos, fecha y sha (bytes32) a publicar."""
    cent, fecha, sha = precio(datos, ticker)
    return {"ticker": ticker, "centimos": cent, "fecha": fecha, "sha": sha}


def verificar_lectura(prep: dict[str, Any], lectura: tuple[int, bytes, int, int]) -> bool:
    """Pura: ¿lo leído de ultimoPrecio() coincide con lo enviado?"""
    cent, sha, fecha, _ = lectura
    return cent == prep["centimos"] and fecha == prep["fecha"] and bytes(sha).hex() == prep["sha"]


def decidir(prep: dict[str, Any], ultimo: tuple[int, bytes, int, int]) -> str:
    """Pura: 'publicar' | 'ya' | lanza error según la fecha del último precio."""
    ult_fecha, ult_sha = ultimo[2], bytes(ultimo[1]).hex()
    if prep["fecha"] > ult_fecha:
        return "publicar"
    if prep["fecha"] == ult_fecha:
        if ult_sha == prep["sha"]:
            return "ya"
        raise ErrorPublicador(f"Ya hay un precio con fecha {ult_fecha} y hash distinto; no se puede reemplazar")
    raise ErrorPublicador(f"La fecha {prep['fecha']} no es mayor que la del último precio ({ult_fecha})")


def decodificar_error(abi: list[dict[str, Any]], data: str) -> str:
    """Nombra un revert por su selector (errores del ABI, Error(string) y Panic)."""
    if not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", data) or len(data) < 10:
        return f"revert sin datos reconocibles ({data[:80]})"
    sel, cuerpo = data[:10].lower(), bytes.fromhex(data[10:])
    firmas = {"0x08c379a0": ("Error", ["string"]), "0x4e487b71": ("Panic", ["uint256"])}
    for e in (x for x in abi if x["type"] == "error"):
        tipos = [i["type"] for i in e["inputs"]]
        firmas[Web3.keccak(text=f"{e['name']}({','.join(tipos)})").to_0x_hex()[:10]] = (e["name"], tipos)
    if sel not in firmas:
        return f"error desconocido (selector {sel})"
    nombre, tipos = firmas[sel]
    try:
        args = Web3().codec.decode(tipos, cuerpo) if tipos else ()
    except Exception:
        return f"{nombre}(<argumentos no decodificables>)"
    return f"{nombre}({', '.join(str(a) for a in args)})"


def _datos_revert(exc: Exception) -> str | None:
    for c in (getattr(exc, "data", None), *exc.args):
        if isinstance(c, str) and c.startswith("0x"):
            return c
        if isinstance(c, dict) and isinstance(c.get("data"), str):
            return c["data"]
    return None


def _cargar(contrato: str | None) -> tuple[list[dict[str, Any]], str]:
    abi = json.loads((RAIZ / "artifacts/contracts/Tepuy.sol/Tepuy.json").read_text())["abi"]
    addr = contrato or json.loads((RAIZ / "web/deployment.json").read_text())["address"]
    if not Web3.is_address(addr):
        raise ErrorPublicador(f"Dirección de contrato inválida: {addr}")
    return abi, Web3.to_checksum_address(addr)


def _ultimo(c: Any) -> tuple[int, bytes, int, int]:
    return tuple(c.functions.ultimoPrecio().call())  # type: ignore[return-value]


def publicar(args: argparse.Namespace) -> dict[str, Any]:
    prep = preparar(leer(args.archivo), args.ticker)
    rpc = args.rpc or os.environ.get("TEPUY_RPC") or "http://127.0.0.1:8545"
    validar_rpc(rpc, remoto=True if args.dry_run else None)  # dry-run: solo lectura
    abi, addr = _cargar(args.contrato)
    clave = os.environ.get("TEPUY_ORACULO_KEY")
    if not args.dry_run and not clave:
        raise ErrorPublicador("Falta la variable de entorno TEPUY_ORACULO_KEY")
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
    try:
        chain_id = w3.eth.chain_id
    except Exception as e:
        if not args.dry_run:
            raise ErrorPublicador(f"No hay conexión con {rpc}") from e
        chain_id = None
    if chain_id is not None:
        validar_red(chain_id, escritura=not args.dry_run)
    c = w3.eth.contract(address=addr, abi=abi) if chain_id is not None else None
    ultimo = None
    if c is not None:
        if not w3.eth.get_code(addr):
            raise ErrorPublicador(f"No hay contrato en {addr}")
        ultimo = _ultimo(c)
    resumen = {**prep, "contrato": addr, "red": chain_id, "ultimo_onchain": (
        None if ultimo is None else {"centimos": ultimo[0], "fecha": ultimo[2], "sha": bytes(ultimo[1]).hex()})}
    if args.dry_run:
        return {"dry_run": True, **resumen}
    if c is None or ultimo is None or clave is None:
        raise ErrorPublicador("Estado inconsistente: sin conexión o sin clave")
    try:
        cuenta = Account.from_key(clave)
    except Exception:
        raise ErrorPublicador("TEPUY_ORACULO_KEY no es una clave privada válida") from None
    if not c.functions.hasRole(c.functions.ORACULO().call(), cuenta.address).call():
        raise ErrorPublicador(f"La cuenta {cuenta.address} no tiene el rol ORACULO")
    # publishPrice no usa whenNotPaused: la pausa no bloquea al oráculo, no se comprueba.
    if decidir(prep, ultimo) == "ya":
        return {"ya_publicado": True, **resumen}
    fn = c.functions.publishPrice(prep["centimos"], prep["fecha"], bytes.fromhex(prep["sha"]))
    h = None
    try:
        tx = fn.build_transaction({"from": cuenta.address, "chainId": chain_id,
                                   "nonce": w3.eth.get_transaction_count(cuenta.address, "pending")})
        h = w3.eth.send_raw_transaction(cuenta.sign_transaction(tx).raw_transaction)
        recibo = w3.eth.wait_for_transaction_receipt(h)
    except TimeExhausted:
        raise ErrorPublicador(f"Sin recibo a tiempo; la tx puede seguir pendiente: {h.to_0x_hex() if h else '?'}") from None
    except Exception as e:
        d = _datos_revert(e)
        raise ErrorPublicador(f"La transacción revirtió: {decodificar_error(abi, d)}" if d
                              else f"Falló el envío: {type(e).__name__}: {str(e)[:200]}") from None
    if recibo["status"] != 1:
        raise ErrorPublicador("La transacción fue minada con status 0")
    if not verificar_lectura(prep, _ultimo(c)):
        raise ErrorPublicador("Lo leído de ultimoPrecio() no coincide con lo enviado")
    return {**resumen, "tx": recibo["transactionHash"].to_0x_hex(), "bloque": recibo["blockNumber"]}


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(prog="oraculo.publicador")
    p.add_argument("archivo")
    p.add_argument("--ticker", required=True)
    p.add_argument("--rpc")
    p.add_argument("--contrato")
    p.add_argument("--dry-run", action="store_true")
    try:
        print(json.dumps(publicar(p.parse_args(argv)), indent=2))
    except (ErrorPublicador, ArchivoInvalido, OSError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Error inesperado: {type(e).__name__}: {str(e)[:200]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
