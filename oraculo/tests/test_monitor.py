import io
import json
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Iterator
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

import pytest
from eth_account import Account
from web3 import Web3

from oraculo import monitor as mon
from oraculo.tests.conftest import nodo_hardhat
from oraculo.tests.test_publicador import ART, K0, K1, _firmar

PUERTO = 8547
A, B = "0x" + "ab" * 20, "0x" + "cd" * 20
CERO = "0x" + "00" * 20


def ev(nombre: str, **args: Any) -> dict[str, Any]:
    return {"event": nombre, "args": args, "transactionHash": b"\x01" * 32, "logIndex": 0}


@pytest.mark.parametrize("nombre,args,nivel", [
    ("Paused", {"account": A}, mon.CRITICO),
    ("TransferenciaForzada", {"from": A, "to": B, "amount": 5, "motivo": "orden", "recuperador": A}, mon.CRITICO),
    ("CuentaRecuperada", {"perdida": A, "nueva": B, "saldo": 3, "motivo": "x", "recuperador": A}, mon.CRITICO),
    ("DefaultAdminTransferScheduled", {"newAdmin": B, "acceptSchedule": 1}, mon.CRITICO),
    ("RoleGranted", {"role": Web3.keccak(text="EMISOR"), "account": B, "sender": A}, mon.CRITICO),
    ("RoleRevoked", {"role": b"\0" * 32, "account": B, "sender": A}, mon.CRITICO),
    ("CongelamientoCambiado", {"cuenta": A, "congelada": True, "supervisor": B}, mon.AVISO),
    ("VerificacionCambiada", {"cuenta": A, "verificado": False, "agente": B}, mon.AVISO),
    ("DividendoOmitido", {"snapId": 1, "tenedor": A, "destino": B, "monto": 2}, mon.AVISO),
    ("AtestiguacionCambiada", {"anterior": 1, "nueva": 2, "custodio": A}, mon.AVISO),
    ("Unpaused", {"account": A}, mon.AVISO),
    ("PrecioPublicado", {"fecha": 20261027, "centimos": 1000, "sha256Archivo": b"", "oraculo": A}, mon.INFO),
    ("SnapshotCreado", {"id": 1, "bloque": 9, "emisor": A}, mon.INFO),
    ("DividendoDeclarado", {"snapId": 1, "numerador": 1, "denominador": 10, "emisor": A}, mon.INFO),
    ("DividendoPagado", {"snapId": 1, "tenedor": A, "destino": B, "monto": 2}, mon.INFO),
    ("Transfer", {"from": CERO, "to": A, "value": 4}, mon.INFO),
    ("Transfer", {"from": A, "to": CERO, "value": 4}, mon.INFO),
])
def test_clasificar(nombre: str, args: dict[str, Any], nivel: str) -> None:
    al = mon.clasificar(ev(nombre, **args))
    assert al is not None and al.nivel == nivel
    assert mon.formatear(al).startswith(mon.ICONO[nivel])


def test_textos_y_sin_alerta() -> None:
    assert "PAUSADO por 0xabab…abab" in mon.formatear(mon.clasificar(ev("Paused", account=A)))  # type: ignore[arg-type]
    assert "Rol EMISOR" in mon.clasificar(ev("RoleGranted", role=Web3.keccak(text="EMISOR"), account=B, sender=A)).texto  # type: ignore[union-attr]
    assert mon.clasificar(ev("Transfer", **{"from": A, "to": B, "value": 1})) is None
    assert mon.clasificar(ev("Approval", owner=A, spender=B, value=1)) is None


def test_variacion_precio() -> None:
    def p(c: int) -> dict[str, Any]:
        return ev("PrecioPublicado", fecha=20261027, centimos=c, sha256Archivo=b"", oraculo=A)
    assert mon.clasificar(p(1110), 1000).nivel == mon.AVISO  # type: ignore[union-attr]
    assert mon.clasificar(p(890), 1000).nivel == mon.AVISO  # type: ignore[union-attr]
    assert mon.clasificar(p(1050), 1000).nivel == mon.INFO  # type: ignore[union-attr]
    assert mon.clasificar(p(1100), 1000).nivel == mon.INFO  # type: ignore[union-attr]  # exactamente 10 % no alerta


def lec(**kw: Any) -> dict[str, Any]:
    return {"pausado": False, "supply": 0, "tope": 100, "ultima_fecha": 20261027, "hoy": date(2026, 10, 28), **kw}


def test_chequeos_estado() -> None:
    assert mon.chequear_estado(lec()) == []
    assert [a.clave for a in mon.chequear_estado(lec(hoy=date(2026, 10, 31)))] == []  # 4 días: aún no
    assert [a.clave for a in mon.chequear_estado(lec(hoy=date(2026, 11, 1)))] == ["estado:precio_viejo"]
    assert mon.chequear_estado(lec(ultima_fecha=0, hoy=date(2030, 1, 1))) == []
    assert [a.clave for a in mon.chequear_estado(lec(supply=91))] == ["estado:tope"]
    assert mon.chequear_estado(lec(supply=90)) == []
    assert mon.chequear_estado(lec(tope=0, supply=0)) == []


def test_pausa_se_recuerda_una_vez() -> None:
    est: dict[str, Any] = {}
    assert len(mon.nuevas_condiciones(est, mon.chequear_estado(lec(pausado=True)))) == 1
    assert mon.nuevas_condiciones(est, mon.chequear_estado(lec(pausado=True))) == []
    assert mon.nuevas_condiciones(est, mon.chequear_estado(lec())) == []
    assert len(mon.nuevas_condiciones(est, mon.chequear_estado(lec(pausado=True)))) == 1  # otro cambio de estado


def test_telegram_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    vistos: list[Any] = []

    class Resp:
        status = 200
        def __enter__(self) -> "Resp": return self
        def __exit__(self, *a: object) -> None: return None

    def falso(req: urllib.request.Request, timeout: float) -> Resp:
        vistos.append((req, timeout))
        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", falso)
    assert mon.enviar_telegram("⛔ hola", "TOK123", "42")
    req, timeout = vistos[0]
    assert timeout == 10 and req.full_url == "https://api.telegram.org/botTOK123/sendMessage"
    assert urllib.parse.parse_qs(req.data.decode()) == {"chat_id": ["42"], "text": ["⛔ hola"]}


def test_token_no_se_imprime(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    def falla(req: urllib.request.Request, timeout: float) -> None:
        raise OSError(f"fallo conectando a {req.full_url}")

    monkeypatch.setattr(urllib.request, "urlopen", falla)
    assert mon.enviar_telegram("x", "SECRETO999", "42") is False
    c = capsys.readouterr()
    assert "SECRETO999" not in c.out + c.err


def test_outbox_reintenta_y_descarta(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("TELEGRAM_TOKEN", "t")
    monkeypatch.setenv("TELEGRAM_CHAT_ID", "1")
    resultados: list[bool | None] = [False]
    monkeypatch.setattr(mon, "enviar_telegram", lambda t, *_: resultados[0])
    r = tmp_path / "e.json"
    est: dict[str, Any] = {"pendientes": ["a", "b", "c"]}
    mon._vaciar_outbox(est, r)
    assert est["pendientes"] == ["a", "b", "c"]  # falló: no se pierde
    resultados[0] = None  # rechazo permanente: se descarta
    mon._vaciar_outbox(est, r)
    assert est["pendientes"] == []
    est["pendientes"] = ["a", "b"]
    resultados[0] = True
    mon._vaciar_outbox(est, r)
    assert est["pendientes"] == [] and mon.cargar_estado(r)["pendientes"] == []  # guardado tras enviar


def test_cola_tope_100(capsys: pytest.CaptureFixture[str]) -> None:
    est: dict[str, Any] = {}
    mon._emitir(est, [mon.Alerta(mon.INFO, f"n{i}") for i in range(150)], dry=False)
    assert len(est["pendientes"]) == 100 and est["pendientes"][-1].endswith("n149")


@pytest.mark.parametrize("code,esperado", [(400, None), (403, None), (429, False), (500, False)])
def test_http_permanente_o_transitorio(monkeypatch: pytest.MonkeyPatch, code: int, esperado: bool | None) -> None:
    def falla(req: urllib.request.Request, timeout: float) -> None:
        raise urllib.error.HTTPError(req.full_url, code, "x", None, io.BytesIO())  # type: ignore[arg-type]

    monkeypatch.setattr(urllib.request, "urlopen", falla)
    assert mon.enviar_telegram("x", "tok", "1") is esperado


def test_token_con_salto_de_linea_y_corte(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]) -> None:
    tok = "123456:ABCDEFGHIJKLMNOPQRSTUVWXYZ-secreto"
    monkeypatch.setenv("TELEGRAM_TOKEN", tok + "\n")  # con salto de línea: se limpia al leer
    monkeypatch.setenv("TELEGRAM_CHAT_ID", "777\n")
    assert mon._secretos() == (tok, "777")
    # token con salto de línea directo a urllib: InvalidURL con la URL en el mensaje
    assert mon.enviar_telegram("x", tok + "\n", "777") is None
    c = capsys.readouterr()
    assert tok[:10] not in c.out + c.err
    # mensaje largo que corta el token justo en el borde del recorte de 200
    seguro = mon._seguro(ValueError("a" * 183 + tok))  # sin redactar, el recorte dejaría "12345"
    assert tok[:5] not in seguro and "***" in seguro


def test_estado_invalido(tmp_path: Path) -> None:
    r = tmp_path / "e.json"
    for malo in ("[]", "{", '{"ultimo_bloque": "7"}', '{"ultimo_bloque": -5}', '{"ultimo_bloque": true}',
                 '{"pendientes": 3}'):
        r.write_text(malo, encoding="utf-8")
        with pytest.raises(mon.ErrorPublicador):
            mon.cargar_estado(r)
    r.write_text('{"ultimo_bloque": -1}', encoding="utf-8")
    assert mon.cargar_estado(r)["ultimo_bloque"] == -1


def test_gobierno_y_desconocidos() -> None:
    assert mon.clasificar(ev("RoleAdminChanged")).nivel == mon.CRITICO  # type: ignore[union-attr]
    assert mon.clasificar(ev("DefaultAdminDelayChangeScheduled")).nivel == mon.CRITICO  # type: ignore[union-attr]
    assert mon.clasificar(ev("EventoNuevo")).nivel == mon.AVISO  # type: ignore[union-attr]


def test_bucle_no_traga_errores_ajenos(tmp_path: Path) -> None:
    def paso() -> None:
        raise KeyError("bug")
    with pytest.raises(KeyError):
        mon.bucle(paso, {}, tmp_path / "e.json", True, 1, lambda _: None, ciclos=2)


def test_bucle_dry_no_escribe_y_caido_se_limpia(tmp_path: Path) -> None:
    r = tmp_path / "e.json"
    n = [0]

    def paso() -> None:
        n[0] += 1
        if n[0] <= 3:
            raise ConnectionError("x")

    est: dict[str, Any] = {}
    mon.bucle(paso, est, r, True, 1, lambda _: None, ciclos=4)
    assert not r.exists() and "caido" not in est


def test_estado_persiste_atomico(tmp_path: Path) -> None:
    r = tmp_path / "e.json"
    assert mon.cargar_estado(r) == {}
    mon.guardar_estado(r, {"ultimo_bloque": 7})
    assert mon.cargar_estado(r) == {"ultimo_bloque": 7}
    assert not list(tmp_path.glob("*.tmp"))


def test_dry_run_sin_telegram(monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str], tmp_path: Path) -> None:
    monkeypatch.delenv("TELEGRAM_TOKEN", raising=False)
    # sin dry-run exige las variables; con dry-run falla después, por conexión (no por Telegram)
    base = ["--rpc", "http://127.0.0.1:8599", "--una-vez", "--estado", str(tmp_path / "e.json")]
    assert mon.main(base) == 1 and "TELEGRAM_TOKEN" in capsys.readouterr().err
    assert mon.main([*base, "--dry-run"]) == 1 and "conexión" in capsys.readouterr().err


def test_rpc_remoto_rechazado(capsys: pytest.CaptureFixture[str]) -> None:
    assert mon.main(["--rpc", "https://ejemplo.org/rpc", "--dry-run"]) == 1
    assert "RPC no permitido" in capsys.readouterr().err


@pytest.fixture(scope="module")
def nodo() -> Iterator[Web3]:
    with nodo_hardhat(PUERTO) as w3:
        yield w3


def test_integracion(nodo: Web3, capsys: pytest.CaptureFixture[str], tmp_path: Path,
                     monkeypatch: pytest.MonkeyPatch) -> None:
    w3 = nodo
    art = json.loads(ART.read_text())
    a0, a1 = Account.from_key(K0).address, Account.from_key(K1).address
    rec = _firmar(w3, K0, w3.eth.contract(abi=art["abi"], bytecode=art["bytecode"]).constructor(86400, a0).build_transaction())
    c = w3.eth.contract(address=rec["contractAddress"], abi=art["abi"])  # type: ignore[index]
    for rol in ("SUPERVISOR", "ORACULO"):
        _firmar(w3, K0, c.functions.grantRole(Web3.keccak(text=rol), a0).build_transaction())
    _firmar(w3, K0, c.functions.pause().build_transaction())
    _firmar(w3, K0, c.functions.setAddressFrozen(a1, True).build_transaction())
    hoy = int(datetime.now(UTC).strftime("%Y%m%d"))
    _firmar(w3, K0, c.functions.publishPrice(1699999, hoy, b"\x01" * 32).build_transaction())

    estado = tmp_path / "e.json"
    base = ["--rpc", f"http://127.0.0.1:{PUERTO}", "--contrato", c.address, "--una-vez", "--estado", str(estado)]
    # dry-run: imprime en stdout, no envía y no deja estado en disco (se puede repetir)
    for _ in range(2):
        assert mon.main([*base, "--dry-run"]) == 0
        out = capsys.readouterr().out
        assert "PAUSADO" in out and "CONGELADA" in out and "Precio publicado: Bs 16,999.99" in out
        assert "OTORGADO" in out and "sigue PAUSADO" in out
        assert not estado.exists()

    # modo real con Telegram simulado
    enviados: list[str] = []

    class Resp:
        status = 200
        def __enter__(self) -> "Resp": return self
        def __exit__(self, *a: object) -> None: return None

    def falso(req: urllib.request.Request, timeout: float) -> Resp:
        enviados.append(urllib.parse.parse_qs(req.data.decode())["text"][0])  # type: ignore[union-attr]
        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", falso)
    monkeypatch.setenv("TELEGRAM_TOKEN", "TOK")
    monkeypatch.setenv("TELEGRAM_CHAT_ID", "42")
    assert mon.main(base) == 0
    c1 = capsys.readouterr()
    assert c1.out == "" and "PAUSADO" in c1.err  # el log local va a stderr
    assert any("PAUSADO" in t for t in enviados) and any("CONGELADA" in t for t in enviados)
    n = len(enviados)
    assert estado.exists()

    assert mon.main(base) == 0  # segunda corrida: nada repetido
    c2 = capsys.readouterr()
    assert c2.out == "" and c2.err == "" and len(enviados) == n

    _firmar(w3, K0, c.functions.unpause().build_transaction())
    assert mon.main(base) == 0
    capsys.readouterr()
    nuevos = enviados[n:]
    assert any("reanudado" in t for t in nuevos) and not any("PAUSADO" in t for t in nuevos)
    assert not any("Precio viejo" in t for t in nuevos)

    # la cadena avanza 10 días (el reloj real no): el precio viejo se mide con la hora del bloque
    n = len(enviados)
    w3.provider.make_request("evm_increaseTime", [10 * 86400])  # type: ignore[arg-type]
    w3.provider.make_request("evm_mine", [])
    assert mon.main(base) == 0
    capsys.readouterr()
    assert any("Precio viejo" in t for t in enviados[n:])

    # estado adelantado a la cadena (nodo reiniciado): se detiene con alerta CRITICA salvo --reiniciar
    otro = tmp_path / "otro.json"
    otro.write_text(json.dumps({"contrato": c.address, "ultimo_bloque": 10**6}), encoding="utf-8")
    ad = [*base[:-1], str(otro)]
    n = len(enviados)
    assert mon.main(ad) == 1
    assert "adelantado" in capsys.readouterr().err and any("adelantado" in t for t in enviados[n:])
    assert mon.main([*ad, "--reiniciar"]) == 0
    assert mon.cargar_estado(otro)["ultimo_bloque"] == w3.eth.block_number
