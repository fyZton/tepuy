"""Vigila los eventos de Tepuy y avisa por Telegram (solo red local 31337)."""
import argparse
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

from web3 import Web3

from web3.exceptions import Web3Exception

from oraculo.publicador import RAIZ, ErrorPublicador, _cargar, validar_red, validar_rpc

CRITICO, AVISO, INFO = "CRITICO", "AVISO", "INFO"
ICONO = {CRITICO: "⛔", AVISO: "⚠️", INFO: "ℹ️"}
MAX_RANGO = 2000
DIAS_PRECIO_VIEJO = 4
MAX_COLA = 100
ROLES = {"0x" + "00" * 32: "ADMIN", **{
    Web3.keccak(text=n).to_0x_hex(): n
    for n in ("EMISOR", "CUSTODIO", "AGENTE_KYC", "SUPERVISOR", "ORACULO", "RECUPERADOR")}}


@dataclass(frozen=True)
class Alerta:
    nivel: str
    texto: str
    clave: str = ""  # identifica la condición de estado (los eventos no la usan)


def corto(a: Any) -> str:
    s = str(a)
    return f"{s[:6]}…{s[-4:]}" if s.startswith("0x") and len(s) > 12 else s


def _hex(x: Any) -> str:
    return x.hex() if isinstance(x, (bytes, bytearray)) else str(x)


def _bs(centimos: int) -> str:
    return f"Bs {centimos // 100:,}.{centimos % 100:02d}"


def _fecha(f: int) -> str:
    return f"{f % 100:02d}/{f // 100 % 100:02d}/{f // 10000}"


def _rol(r: Any) -> str:
    h = r if isinstance(r, str) else "0x" + _hex(r)
    return ROLES.get(h.lower(), corto(h))


def clasificar(ev: dict[str, Any], precio_previo: int | None = None) -> Alerta | None:
    """Pura: evento decodificado -> alerta (None si no alerta, p. ej. transferencia normal)."""
    n, a = ev["event"], ev["args"]
    cero = "0x" + "00" * 20
    r: tuple[str, str] | None
    if n == "Paused":
        r = (CRITICO, f"Contrato PAUSADO por {corto(a['account'])}")
    elif n == "Unpaused":
        r = (AVISO, f"Contrato reanudado por {corto(a['account'])}")
    elif n == "TransferenciaForzada":
        r = (CRITICO, f"Transferencia FORZADA de {a['amount']} acciones: {corto(a['from'])} -> {corto(a['to'])} "
                      f"por {corto(a['recuperador'])}. Motivo: {a['motivo']}")
    elif n == "CuentaRecuperada":
        r = (CRITICO, f"Cuenta RECUPERADA: {corto(a['perdida'])} -> {corto(a['nueva'])} "
                      f"({a['saldo']} acciones) por {corto(a['recuperador'])}. Motivo: {a['motivo']}")
    elif n == "DefaultAdminTransferScheduled":
        r = (CRITICO, f"Traspaso del ADMIN iniciado hacia {corto(a['newAdmin'])}")
    elif n == "RoleGranted":
        r = (CRITICO, f"Rol {_rol(a['role'])} OTORGADO a {corto(a['account'])} por {corto(a['sender'])}")
    elif n == "RoleRevoked":
        r = (CRITICO, f"Rol {_rol(a['role'])} REVOCADO a {corto(a['account'])} por {corto(a['sender'])}")
    elif n == "CongelamientoCambiado":
        r = ((AVISO, f"Cuenta {corto(a['cuenta'])} CONGELADA por {corto(a['supervisor'])}") if a["congelada"]
             else (INFO, f"Cuenta {corto(a['cuenta'])} descongelada por {corto(a['supervisor'])}"))
    elif n == "VerificacionCambiada":
        r = ((INFO, f"KYC aprobado para {corto(a['cuenta'])}") if a["verificado"]
             else (AVISO, f"KYC REVOCADO a {corto(a['cuenta'])} por {corto(a['agente'])}"))
    elif n == "DividendoOmitido":
        r = (AVISO, f"Dividendo omitido ({a['monto']} acciones) para {corto(a['tenedor'])} (snapshot {a['snapId']})")
    elif n == "AtestiguacionCambiada":
        r = (AVISO, f"Acciones atestiguadas: {a['anterior']} -> {a['nueva']} por {corto(a['custodio'])}")
    elif n in ("RoleAdminChanged", "DefaultAdminDelayChangeScheduled"):
        r = (CRITICO, f"Cambio de gobierno del contrato: {n}")
    elif n in ("DefaultAdminTransferCanceled", "DefaultAdminDelayChangeCanceled"):
        r = (AVISO, f"Cambio de gobierno del contrato: {n}")
    elif n == "PrecioPublicado":
        c = a["centimos"]
        txt = f"Precio publicado: {_bs(c)} al {_fecha(a['fecha'])}"
        if precio_previo and abs(c - precio_previo) * 100 > precio_previo * 10:
            r = (AVISO, f"{txt} (variación de {(c - precio_previo) * 100 / precio_previo:+.1f} % vs {_bs(precio_previo)})")
        else:
            r = (INFO, txt)
    elif n == "SnapshotCreado":
        r = (INFO, f"Snapshot {a['id']} creado (bloque {a['bloque']})")
    elif n == "DividendoDeclarado":
        r = (INFO, f"Dividendo declarado sobre snapshot {a['snapId']}: {a['numerador']}/{a['denominador']}")
    elif n == "DividendoPagado":
        r = (INFO, f"Dividendo pagado: {a['monto']} acciones a {corto(a['destino'])} (snapshot {a['snapId']})")
    elif n == "FraccionPendiente":
        r = (INFO, f"Fracción pendiente de {a['resto']} para {corto(a['tenedor'])} (snapshot {a['snapId']})")
    elif n == "Transfer":
        if a["from"] == cero:
            r = (INFO, f"Emisión (mint): {a['value']} acciones a {corto(a['to'])}")
        elif a["to"] == cero:
            r = (INFO, f"Quema (burn): {a['value']} acciones de {corto(a['from'])}")
        else:
            return None
    elif n == "Approval":
        return None
    else:
        r = (AVISO, f"Evento sin clasificar: {n}")  # evento nuevo del ABI: que alguien lo revise
    return Alerta(r[0], r[1])


def formatear(al: Alerta) -> str:
    return f"{ICONO[al.nivel]} {al.texto}"


def chequear_estado(lec: dict[str, Any]) -> list[Alerta]:
    """Pura: condiciones activas ahora. lec: pausado, supply, tope, ultima_fecha (AAAAMMDD, 0 = ninguna), hoy."""
    out: list[Alerta] = []
    if lec["pausado"]:
        out.append(Alerta(AVISO, "Recordatorio: el contrato sigue PAUSADO", "estado:pausado"))
    f = lec["ultima_fecha"]
    if f:
        # ponytail: días naturales > 4 en vez de 3 días hábiles; usar calendario bursátil si molesta en feriados
        dias = (lec["hoy"] - date(f // 10000, f // 100 % 100, f % 100)).days
        if dias > DIAS_PRECIO_VIEJO:
            out.append(Alerta(AVISO, f"Precio viejo: el último es del {_fecha(f)} (hace {dias} días)", "estado:precio_viejo"))
    if lec["tope"] and lec["supply"] * 100 > lec["tope"] * 90:
        out.append(Alerta(AVISO, f"Uso del tope al {lec['supply'] * 100 / lec['tope']:.1f} % "
                                 f"({lec['supply']} de {lec['tope']} atestiguadas)", "estado:tope"))
    return out


def nuevas_condiciones(estado: dict[str, Any], actuales: list[Alerta]) -> list[Alerta]:
    """Solo las condiciones que no estaban activas en el ciclo anterior (avisa una vez por cambio)."""
    previas = set(estado.get("activas", []))
    estado["activas"] = [a.clave for a in actuales]
    return [a for a in actuales if a.clave not in previas]


def _secretos() -> tuple[str, str]:
    return os.environ.get("TELEGRAM_TOKEN", "").strip(), os.environ.get("TELEGRAM_CHAT_ID", "").strip()


def _seguro(e: BaseException) -> str:
    """Texto de una excepción sin token ni chat_id (se redacta ANTES de recortar)."""
    t = f"{type(e).__name__}: {e}"
    for sec in _secretos():
        if sec:
            t = t.replace(sec, "***")
    return t[:200]


def enviar_telegram(texto: str, token: str, chat_id: str) -> bool | None:
    """Bot API. True = enviado, False = reintentar luego, None = rechazo permanente (descartar).
    Solo se imprime el tipo de error y el código HTTP: la URL lleva el token."""
    try:
        req = urllib.request.Request(f"https://api.telegram.org/bot{token}/sendMessage",
                                     data=urllib.parse.urlencode({"chat_id": chat_id, "text": texto}).encode())
        with urllib.request.urlopen(req, timeout=10) as r:
            return bool(200 <= r.status < 300)
    except Exception as e:
        code = e.code if isinstance(e, urllib.error.HTTPError) else None
        print(f"Telegram falló ({type(e).__name__}{f' HTTP {code}' if code else ''})", file=sys.stderr)
        permanente = (code is not None and 400 <= code < 500 and code != 429) or isinstance(e, (ValueError, http.client.InvalidURL))
        return None if permanente else False


def cargar_estado(ruta: Path) -> dict[str, Any]:
    try:
        e = json.loads(ruta.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except ValueError:
        raise ErrorPublicador(f"Archivo de estado ilegible ({ruta}); revísalo o bórralo") from None
    ub = e.get("ultimo_bloque", -1) if isinstance(e, dict) else None
    if not (isinstance(ub, int) and not isinstance(ub, bool) and ub >= -1
            and isinstance(e.get("pendientes", []), list) and isinstance(e.get("activas", []), list)):
        raise ErrorPublicador(f"Archivo de estado con formato inválido ({ruta}); revísalo o bórralo")
    return e  # type: ignore[no-any-return]


def guardar_estado(ruta: Path, estado: dict[str, Any]) -> None:
    tmp = ruta.with_name(ruta.name + ".tmp")
    tmp.write_text(json.dumps(estado, indent=2), encoding="utf-8")
    os.replace(tmp, ruta)


def _guardar(ruta: Path, estado: dict[str, Any], dry: bool) -> None:
    if not dry:  # dry-run no deja rastro en disco
        guardar_estado(ruta, estado)


def _log(texto: str, dry: bool) -> None:
    """Dry-run imprime en stdout; en producción el log local va a stderr y stdout queda limpio."""
    print(texto, file=sys.stdout if dry else sys.stderr, flush=True)


def _emitir(estado: dict[str, Any], alertas: list[Alerta], dry: bool) -> None:
    for al in alertas:
        t = formatear(al)
        _log(t, dry)
        if not dry:
            cola: list[str] = estado.setdefault("pendientes", [])
            cola.append(t)
            if len(cola) > MAX_COLA:
                del cola[:-MAX_COLA]
                _log("Cola de Telegram llena: se descartaron alertas antiguas", dry)


def _vaciar_outbox(estado: dict[str, Any], ruta: Path) -> None:
    token, chat = _secretos()
    pend: list[str] = estado.get("pendientes", [])
    while pend:
        ok = enviar_telegram(pend[0], token, chat)
        if ok is False:
            break
        if ok is None:
            _log("Telegram rechazó una alerta de forma permanente; se descarta (queda en este log)", False)
        pend.pop(0)
        guardar_estado(ruta, estado)  # una vez enviada no se reenvía tras un reinicio


def topics(c: Any) -> dict[str, Any]:
    """topic0 -> evento del ABI (se calcula una sola vez)."""
    return {Web3.keccak(text=f"{e['name']}({','.join(i['type'] for i in e['inputs'])})").to_0x_hex():
            c.events[e["name"]]() for e in c.abi if e["type"] == "event"}


def ciclo(w3: Web3, c: Any, estado: dict[str, Any], ruta: Path, dry: bool,
          por_topic: dict[str, Any], reiniciar: bool = False) -> None:
    """Un ciclo: eventos nuevos por rangos, chequeos de estado y envío de pendientes."""
    cabeza = w3.eth.block_number
    if estado["ultimo_bloque"] > cabeza:
        if not reiniciar:
            _emitir(estado, [Alerta(CRITICO, "estado adelantado a la cadena (¿nodo reiniciado?)")], dry)
            _guardar(ruta, estado, dry)
            if not dry:
                _vaciar_outbox(estado, ruta)
            raise ErrorPublicador("El estado está adelantado a la cadena (¿nodo reiniciado?); "
                                  "usa --reiniciar o borra el archivo de estado")
        estado.update(ultimo_bloque=-1, precio_previo=None, activas=[])
    cuentas: dict[str, int] = {}
    desde = estado["ultimo_bloque"] + 1
    while desde <= cabeza:
        hasta = min(desde + MAX_RANGO - 1, cabeza)
        logs = w3.eth.get_logs({"address": c.address, "fromBlock": desde, "toBlock": hasta})
        nuevas: list[Alerta] = []
        previo = estado.get("precio_previo")
        for lg in sorted(logs, key=lambda x: (x["blockNumber"], x["logIndex"])):
            ev = por_topic.get(lg["topics"][0].to_0x_hex()) if lg["topics"] else None
            if ev is None:
                continue
            d = ev.process_log(lg)
            al = clasificar(d, previo)
            if d["event"] == "PrecioPublicado":
                previo = d["args"]["centimos"]
            if al is None:
                cuentas[d["event"]] = cuentas.get(d["event"], 0) + 1
            else:
                nuevas.append(al)
        _emitir(estado, nuevas, dry)
        estado["ultimo_bloque"], estado["precio_previo"] = hasta, previo
        _guardar(ruta, estado, dry)  # alertas y bloque se guardan juntos: sin repetir ni saltar
        desde = hasta + 1
    ult = c.functions.ultimoPrecio().call()
    lec = {"pausado": c.functions.paused().call(), "supply": c.functions.totalSupply().call(),
           "tope": c.functions.accionesAtestiguadas().call(), "ultima_fecha": ult[2],
           "hoy": datetime.fromtimestamp(w3.eth.get_block("latest")["timestamp"], UTC).date()}  # hora de la cadena
    _emitir(estado, nuevas_condiciones(estado, chequear_estado(lec)), dry)
    if cuentas:
        _log(f"Resumen: {cuentas.get('Transfer', 0)} transferencias normales", dry)
    _guardar(ruta, estado, dry)
    if not dry:
        _vaciar_outbox(estado, ruta)


def bucle(paso: Callable[[], None], estado: dict[str, Any], ruta: Path, dry: bool, intervalo: float,
          dormir: Callable[[float], None] = time.sleep, ciclos: int | None = None) -> None:
    """Repite `paso`; ante errores reintenta con espera creciente y avisa de la caída una vez."""
    fallos = 0
    while ciclos is None or ciclos > 0:
        ciclos = None if ciclos is None else ciclos - 1
        try:
            paso()
        except (OSError, Web3Exception) as e:  # solo caídas de red/RPC; lo demás es un bug y debe fallar
            fallos += 1
            _log(f"Error de conexión/RPC ({type(e).__name__}); intento {fallos}", dry)
            if fallos >= 3 and not estado.get("caido"):
                estado["caido"] = True
                _emitir(estado, [Alerta(CRITICO, "monitor sin conexión", "estado:sin_conexion")], dry)
                _guardar(ruta, estado, dry)
            if estado.get("caido") and not dry:
                _vaciar_outbox(estado, ruta)
            dormir(min(intervalo * 2 ** min(fallos, 10), 300))
            continue
        fallos = 0
        if estado.pop("caido", False):
            _emitir(estado, [Alerta(INFO, "conexión restablecida", "estado:conexion")], dry)
            _guardar(ruta, estado, dry)
            if not dry:
                _vaciar_outbox(estado, ruta)
        dormir(intervalo)


def monitorear(args: argparse.Namespace) -> None:
    rpc = args.rpc or os.environ.get("TEPUY_RPC") or "http://127.0.0.1:8545"
    validar_rpc(rpc)
    if not args.dry_run and not all(_secretos()):
        raise ErrorPublicador("Faltan TELEGRAM_TOKEN y TELEGRAM_CHAT_ID (o usa --dry-run)")
    abi, addr = _cargar(args.contrato)
    w3 = Web3(Web3.HTTPProvider(rpc, request_kwargs={"timeout": 30}))
    try:
        chain_id = w3.eth.chain_id
    except Exception as e:
        raise ErrorPublicador(f"No hay conexión con {rpc}") from e
    validar_red(chain_id)
    if not w3.eth.get_code(addr):
        raise ErrorPublicador(f"No hay contrato en {addr}")
    c = w3.eth.contract(address=addr, abi=abi)
    ruta = Path(args.estado)
    estado = cargar_estado(ruta)
    if estado.get("contrato", addr) != addr:
        raise ErrorPublicador(f"El archivo de estado es de otro contrato ({estado['contrato']}); bórralo o usa --estado")
    estado["contrato"] = addr
    estado.setdefault("ultimo_bloque", max(args.desde - 1, -1))  # --desde solo aplica sin estado previo
    por_topic = topics(c)

    def paso() -> None:
        ciclo(w3, c, estado, ruta, args.dry_run, por_topic, args.reiniciar)

    if args.una_vez:
        paso()
        return
    bucle(paso, estado, ruta, args.dry_run, args.intervalo)


def main(argv: list[str]) -> int:
    for f in (sys.stdout, sys.stderr):  # las alertas llevan emojis y tildes
        if hasattr(f, "reconfigure"):
            f.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(prog="oraculo.monitor", description="Una sola instancia por archivo de estado (no hay candado).")
    p.add_argument("--rpc")
    p.add_argument("--contrato")
    p.add_argument("--desde", type=int, default=0)
    p.add_argument("--una-vez", action="store_true")
    p.add_argument("--intervalo", type=float, default=30)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--estado", default=str(RAIZ / ".monitor-estado.json"))
    p.add_argument("--reiniciar", action="store_true",
                   help="si el nodo se reinició (estado adelantado a la cadena), empezar de cero")
    try:
        monitorear(p.parse_args(argv))
    except KeyboardInterrupt:
        return 0
    except (ErrorPublicador, OSError) as e:
        print(f"Error: {_seguro(e)}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Error inesperado: {_seguro(e)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
