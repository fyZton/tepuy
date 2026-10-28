import json
from collections.abc import Iterator
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace

import pytest
from eth_account import Account
from web3 import Web3

from oraculo import publicador as pub
from oraculo.tests.conftest import nodo_hardhat

FIX = Path(__file__).parent / "fixtures" / "20261027.dat"
ART = pub.RAIZ / "artifacts/contracts/Tepuy.sol/Tepuy.json"
# Claves públicas de prueba de Hardhat (solo para tests): cuentas 0, 1 y 6.
K0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
K1 = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
K6 = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"
PUERTO = 8546


def args(extra: list[str] | None = None) -> list[str]:
    return [str(FIX), "--ticker", "MVZ.A", "--rpc", f"http://127.0.0.1:{PUERTO + 50}", *(extra or [])]


def test_dry_run_sin_clave(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.delenv("TEPUY_ORACULO_KEY", raising=False)
    assert pub.main(args(["--dry-run"])) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["centimos"] == 1699999 and out["fecha"] == 20261027


def test_falta_clave(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.delenv("TEPUY_ORACULO_KEY", raising=False)
    assert pub.main(args()) == 1
    assert "TEPUY_ORACULO_KEY" in capsys.readouterr().err


def test_clave_no_se_imprime(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setenv("TEPUY_ORACULO_KEY", K6)
    assert pub.main(args()) == 1  # sin nodo: error de conexión
    c = capsys.readouterr()
    assert K6 not in c.out + c.err and K6[2:] not in c.out + c.err


@pytest.mark.parametrize("cid", [1, 421614])
def test_guardia_red(cid: int) -> None:
    with pytest.raises(pub.ErrorPublicador):
        pub.validar_red(cid)
    pub.validar_red(31337)


def test_error_decodificado() -> None:
    abi = json.loads(ART.read_text())["abi"]
    sel = Web3.keccak(text="FechaFutura(uint32,uint32)").hex()[:8]
    data = "0x" + sel + (20300101).to_bytes(32, "big").hex() + (20261030).to_bytes(32, "big").hex()
    assert pub.decodificar_error(abi, data) == "FechaFutura(20300101, 20261030)"
    sel = Web3.keccak(text="PrecioCero()").hex()[:8]
    assert pub.decodificar_error(abi, "0x" + sel) == "PrecioCero()"
    assert "AccessControlUnauthorizedAccount" in pub.decodificar_error(
        abi, "0x e2517d3f".replace(" ", "") + "00" * 12 + "11" * 20 + "22" * 32)


def test_decodificar_robusto() -> None:
    abi = json.loads(ART.read_text())["abi"]
    assert "sin datos" in pub.decodificar_error(abi, "0xabc")  # largo impar
    sel = Web3.keccak(text="FechaFutura(uint32,uint32)").hex()[:8]
    assert "no decodificables" in pub.decodificar_error(abi, "0x" + sel + "00")
    assert pub.decodificar_error(abi, "0x4e487b71" + (17).to_bytes(32, "big").hex()) == "Panic(17)"


def test_rpc_no_loopback() -> None:
    with pytest.raises(pub.ErrorPublicador):
        pub.validar_rpc("https://sepolia-rollup.arbitrum.io/rpc")
    pub.validar_rpc("http://[::1]:8545")


def test_chain_id_ajeno_por_publicar(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    monkeypatch.setenv("TEPUY_ORACULO_KEY", K6)
    class Falso:
        HTTPProvider = staticmethod(lambda *a, **k: None)
        is_address = staticmethod(Web3.is_address)
        to_checksum_address = staticmethod(Web3.to_checksum_address)

        def __init__(self, _: object) -> None:
            self.eth = SimpleNamespace(chain_id=421614)

    monkeypatch.setattr(pub, "Web3", Falso)
    assert pub.main(args()) == 1
    assert "421614" in capsys.readouterr().err


def test_puras() -> None:
    p = pub.preparar(FIX.read_bytes(), "MVZ.A")
    sha = bytes.fromhex(p["sha"])
    assert pub.verificar_lectura(p, (p["centimos"], sha, p["fecha"], 0))
    assert not pub.verificar_lectura(p, (p["centimos"] + 1, sha, p["fecha"], 0))
    assert pub.decidir(p, (0, b"\0" * 32, 0, 0)) == "publicar"
    assert pub.decidir(p, (1, sha, p["fecha"], 0)) == "ya"
    with pytest.raises(pub.ErrorPublicador):
        pub.decidir(p, (1, b"\1" * 32, p["fecha"], 0))
    with pytest.raises(pub.ErrorPublicador):
        pub.decidir(p, (1, sha, p["fecha"] + 1, 0))


@pytest.fixture(scope="module")
def nodo() -> Iterator[Web3]:
    with nodo_hardhat(PUERTO) as w3:
        yield w3


def _firmar(w3: Web3, clave: str, tx: dict) -> object:
    a = Account.from_key(clave)
    tx = {**tx, "from": a.address, "nonce": w3.eth.get_transaction_count(a.address), "chainId": 31337}
    tx["gas"] = w3.eth.estimate_gas(tx)
    return w3.eth.wait_for_transaction_receipt(w3.eth.send_raw_transaction(a.sign_transaction(tx).raw_transaction))


def test_integracion(nodo: Web3, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    w3 = nodo
    art = json.loads(ART.read_text())
    a0 = Account.from_key(K0).address
    rec = _firmar(w3, K0, w3.eth.contract(abi=art["abi"], bytecode=art["bytecode"]).constructor(86400, a0).build_transaction())
    c = w3.eth.contract(address=rec["contractAddress"], abi=art["abi"])  # type: ignore[index]
    _firmar(w3, K0, c.functions.grantRole(c.functions.ORACULO().call(), Account.from_key(K6).address).build_transaction())
    base = ["--rpc", f"http://127.0.0.1:{PUERTO}", "--contrato", c.address]
    cmd = [str(FIX), "--ticker", "MVZ.A", *base]

    monkeypatch.setenv("TEPUY_ORACULO_KEY", K6)
    assert pub.main(cmd) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["tx"].startswith("0x") and out["bloque"] > 0
    cent, sha, fecha, _ = c.functions.ultimoPrecio().call()
    assert (cent, fecha, sha.hex()) == (1699999, 20261027, out["sha"])

    n = w3.eth.block_number
    assert pub.main(cmd) == 0  # idempotente
    assert json.loads(capsys.readouterr().out)["ya_publicado"] is True
    assert w3.eth.block_number == n

    monkeypatch.setenv("TEPUY_ORACULO_KEY", K1)  # sin rol
    assert pub.main(cmd) == 1
    assert "ORACULO" in capsys.readouterr().err

    monkeypatch.setenv("TEPUY_ORACULO_KEY", K6)  # misma fecha, otro sha: error
    otro = FIX.parent / "otro.dat"
    otro.write_bytes(FIX.read_bytes() + b"\n")
    try:
        assert pub.main([str(otro), "--ticker", "MVZ.A", *base]) == 1
        err = capsys.readouterr().err
        assert "hash distinto" in err and K6 not in err
    finally:
        otro.unlink()

    # revert real (fecha futura): el error se decodifica por su nombre
    with pytest.raises(Exception) as ei:
        c.functions.publishPrice(1, 20991231, b"\x01" * 32).call({"from": Account.from_key(K6).address})
    d = pub._datos_revert(ei.value)
    assert d and pub.decodificar_error(art["abi"], d).startswith("FechaFutura(20991231")


@pytest.mark.parametrize("cid", [421614, 11155111])
def test_red_publica_confirmacion(monkeypatch: pytest.MonkeyPatch, cid: int) -> None:
    monkeypatch.delenv("CONFIRM_DEPLOY", raising=False)
    with pytest.raises(pub.ErrorPublicador, match="CONFIRM_DEPLOY"):
        pub.validar_red(cid)
    pub.validar_red(cid, escritura=False)  # lectura (monitor) sin confirmar
    monkeypatch.setenv("CONFIRM_DEPLOY", "yes")
    pub.validar_red(cid)
    with pytest.raises(pub.ErrorPublicador):
        pub.validar_red(1)


def test_rpc_remoto(monkeypatch: pytest.MonkeyPatch) -> None:
    url = "https://sepolia-rollup.arbitrum.io/rpc"
    monkeypatch.delenv("CONFIRM_DEPLOY", raising=False)
    with pytest.raises(pub.ErrorPublicador, match="CONFIRM_DEPLOY"):
        pub.validar_rpc(url)
    pub.validar_rpc(url, remoto=True)  # monitor: lectura
    monkeypatch.setenv("CONFIRM_DEPLOY", "yes")
    pub.validar_rpc(url)
    for malo in ("http://sepolia-rollup.arbitrum.io/rpc", "ftp://x.io", "//x.io"):
        with pytest.raises(pub.ErrorPublicador, match="https"):
            pub.validar_rpc(malo)
        with pytest.raises(pub.ErrorPublicador, match="https"):
            pub.validar_rpc(malo, remoto=True)


@pytest.mark.parametrize("confirm,ok", [(None, False), ("yes", True)])
def test_publicar_red_publica_simulada(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
                                       confirm: str | None, ok: bool) -> None:
    """chainId 421614 simulado (mock, sin red): sin confirmar rechaza; confirmado pasa la guardia."""
    monkeypatch.setenv("TEPUY_ORACULO_KEY", K6)
    monkeypatch.delenv("CONFIRM_DEPLOY", raising=False)
    if confirm:
        monkeypatch.setenv("CONFIRM_DEPLOY", confirm)

    class Falso:
        HTTPProvider = staticmethod(lambda *a, **k: None)
        is_address = staticmethod(Web3.is_address)
        to_checksum_address = staticmethod(Web3.to_checksum_address)

        def __init__(self, _: object) -> None:
            self.eth = SimpleNamespace(chain_id=421614)  # sin .contract: falla justo tras la guardia

    monkeypatch.setattr(pub, "Web3", Falso)
    assert pub.main(args()) == 1
    err = capsys.readouterr().err
    # Con confirmación supera validar_red y falla más adelante (.contract); sin ella, falla en la guardia.
    assert ("CONFIRM_DEPLOY" not in err) == ok
    assert ("AttributeError" in err) == ok


def test_dry_run_red_publica_sin_confirmar(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    """--dry-run con RPC https remoto y chainId 421614 simulado: pasa las guardias sin CONFIRM_DEPLOY."""
    monkeypatch.delenv("CONFIRM_DEPLOY", raising=False)

    class Falso:
        HTTPProvider = staticmethod(lambda *a, **k: None)
        is_address = staticmethod(Web3.is_address)
        to_checksum_address = staticmethod(Web3.to_checksum_address)

        def __init__(self, _: object) -> None:
            self.eth = SimpleNamespace(chain_id=421614)  # sin .contract: falla justo tras las guardias

    monkeypatch.setattr(pub, "Web3", Falso)
    a = ["--rpc", "https://ejemplo.org/rpc", "--dry-run"]
    assert pub.main([str(FIX), "--ticker", "MVZ.A", *a]) == 1
    err = capsys.readouterr().err
    assert "AttributeError" in err and "CONFIRM_DEPLOY" not in err
    assert pub.main([str(FIX), "--ticker", "MVZ.A", "--rpc", "https://ejemplo.org/rpc"]) == 1  # sin dry-run sigue rechazando
    assert "CONFIRM_DEPLOY" in capsys.readouterr().err
