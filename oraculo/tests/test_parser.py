import json
import os
import subprocess
import sys
from collections import Counter
from pathlib import Path

import pytest

from oraculo.parser import ArchivoInvalido, parsear, precio, sha256_hex

RAIZ = Path(__file__).resolve().parents[2]
FIX = Path(__file__).parent / "fixtures" / "20261027.dat"
SHA = "972a85a50f005b54db7edaa08d4ad49fd5c416f2a1dccd70a1cd1ee5b689c1b3"
IG = b"IG|27102026|1|2|3|\n"


def test_fixture_mvz():
    datos = FIX.read_bytes()
    assert precio(datos, "MVZ.A") == (1699999, 20261027, SHA)
    assert sha256_hex(datos) == SHA


def test_otros_tickers():
    c = parsear(FIX.read_bytes()).cierres
    assert (c["BPV"], c["BNC"], c["ARC.B"]) == (845000, 24500, 128445)


def test_formatos_y_finales_mixtos():
    d = IG + b"R|X|AAA|.94|17000|-.01|-.5|1|2|3|4|5|6||\r\r\nR|Y|BBB|1|16999.99|0|0|\n"
    c = parsear(d)
    assert c.cierres == {"AAA": 1700000, "BBB": 1699999}


def test_p_se_ignora():
    d = IG + b"R|X|AAA|1|5|0|0|\nP|X|AAA|1|999|\n"
    assert parsear(d).cierres == {"AAA": 500}


R = b"R|X|AAA|1|5|0|0|\n"
MALOS = {
    "vacio": b"",
    "sin_ig": R,
    "fecha_mala": b"IG|31022026|\n" + R,
    "fecha_corta": b"IG|2710|\n" + R,
    "duplicado": IG + R + R,
    "pocos_campos": IG + b"R|X|AAA|1|\n",
    "sin_r": IG + b"P|X|AAA|1|5|\n",
    "decimales": IG + b"R|X|AAA|1|5.123|0|\n",
    "negativo": IG + b"R|X|AAA|1|-5|0|\n",
    "cero": IG + b"R|X|AAA|1|0|0|\n",
    "invalido": IG + b"R|X|AAA|1|abc|0|\n",
    "nan": IG + b"R|X|AAA|1|NaN|0|\n",
    "exponente": IG + b"R|X|AAA|1|1e3|0|\n",
    "E": IG + b"R|X|AAA|1|1E3|0|\n",
    "guion_bajo": IG + b"R|X|AAA|1|1_000|0|\n",
    "mas": IG + b"R|X|AAA|1|+5|0|\n",
    "punto_final": IG + b"R|X|AAA|1|5.|0|\n",
    "infinity": IG + b"R|X|AAA|1|Infinity|0|\n",
    "snan": IG + b"R|X|AAA|1|sNaN|0|\n",
    "miles": IG + b"R|X|AAA|1|1,000.50|0|\n",
    "nbsp": IG + b"R|X|AAA|1|\xa05|0|\n",
    "redondeo_30": IG + b"R|X|AAA|1|1." + b"0" * 29 + b"1|0|\n",
    "enorme": IG + b"R|X|AAA|1|" + str(2**128).encode() + b"|0|\n",
    "ticker_vacio": IG + b"R|X||1|5|0|\n",
    "ig_duplicada": IG + IG + R,
    "fecha_cero": b"IG|00000000|\n" + R,
    "fecha_letra": b"IG|2710202a|\n" + R,
    "fecha_espacio": b"IG| 27102026|\n" + R,
    "anio_1999": b"IG|01011999|\n" + R,
}


@pytest.mark.parametrize("datos", MALOS.values(), ids=MALOS.keys())
def test_malos(datos):
    with pytest.raises(ArchivoInvalido):
        parsear(datos)


def test_ticker_ausente():
    with pytest.raises(ArchivoInvalido):
        precio(FIX.read_bytes(), "NOPE")


def _cli(*args: str):
    return subprocess.run([sys.executable, "-m", "oraculo.parser", *args], cwd=RAIZ, capture_output=True, text=True)


def test_cli():
    r = _cli(str(FIX), "MVZ.A")
    assert r.returncode == 0
    assert json.loads(r.stdout) == {"ticker": "MVZ.A", "centimos": 1699999, "fecha": 20261027, "sha256": SHA}
    r = _cli(str(FIX), "NOPE")
    assert r.returncode == 1 and r.stderr


def test_humo_bvc_dir():
    d = os.environ.get("BVC_DIR")
    if not d:
        pytest.skip("BVC_DIR no definida")
    ok, fallos = 0, Counter()
    for f in sorted(Path(d).glob("*.dat")):
        try:
            parsear(f.read_bytes())
            ok += 1
        except ArchivoInvalido as e:
            fallos[str(e).split(":")[0]] += 1
    print(f"\nparsearon={ok} fallaron={sum(fallos.values())} motivos={dict(fallos)}")


def test_maximo_exacto():
    m = 2**128 - 1
    d = IG + b"R|X|AAA|1|%d.%02d|0|\n" % (m // 100, m % 100)
    assert parsear(d).cierres["AAA"] == m


def test_x85_en_nombre():
    d = IG + b"R|NOM\x85BRE|AAA|1|5|0|\nR|Y|BBB|1|7|0|\n"
    assert parsear(d).cierres == {"AAA": 500, "BBB": 700}


def test_p_antes_de_r():
    d = IG + b"P|X|AAA|1|999|\nR|X|AAA|1|5|0|\n"
    assert precio(d, "AAA")[0] == 500


def test_sha_bytes_crudos():
    import hashlib
    d = IG + b"R|X|AAA|1|5|0|\r\r\nR|Y|BBB|1|7|0|\n"
    assert precio(d, "AAA")[2] == hashlib.sha256(d).hexdigest()


def test_cli_errores(tmp_path):
    malo = tmp_path / "malo.dat"
    malo.write_bytes(b"basura")
    for args in ([], [str(FIX)], [str(tmp_path / "no.dat"), "X"], [str(malo), "X"]):
        r = _cli(*args)
        assert r.returncode == 1 and r.stderr.strip() and not r.stdout
