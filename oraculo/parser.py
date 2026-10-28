"""Parser del archivo diario .dat de la BVC: cierres en céntimos + SHA-256."""
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path


class ArchivoInvalido(ValueError):
    pass


@dataclass(frozen=True)
class Cierre:
    fecha: int  # AAAAMMDD
    cierres: dict[str, int]  # ticker -> céntimos


def leer(ruta: str | Path) -> bytes:
    return Path(ruta).read_bytes()


def sha256_hex(datos: bytes) -> str:
    return hashlib.sha256(datos).hexdigest()


MAX_CENTIMOS = 2**128 - 1  # uint128 del contrato (PrecioExcesivo)
_NUM = re.compile(r"\d+(\.\d{1,2})?|\.\d{1,2}", re.ASCII)


def _centimos(texto: str, ticker: str) -> int:
    t = texto.strip(" ")
    if not _NUM.fullmatch(t):
        raise ArchivoInvalido(f"Cierre inválido para {ticker}: {texto!r}")
    ent, _, dec = t.partition(".")  # enteros puros: Decimal redondea con el contexto
    c = int(ent or "0") * 100 + int(dec.ljust(2, "0"))
    if c <= 0:
        raise ArchivoInvalido(f"Cierre no positivo para {ticker}: {texto!r}")
    if c > MAX_CENTIMOS:
        raise ArchivoInvalido(f"Cierre excesivo para {ticker}: {texto!r}")
    return c


def parsear(datos: bytes) -> Cierre:
    if not datos.strip():
        raise ArchivoInvalido("Archivo vacío")
    texto = datos.decode("latin-1")  # latin-1 decodifica cualquier byte
    # no splitlines: 0x85 es válido en nombres latin-1
    lineas = [x.strip(" \t") for x in re.split(r"\r*\n|\r", texto)]
    lineas = [x for x in lineas if x]
    igs = [x for x in lineas if x.startswith("IG|")]
    if not igs:
        raise ArchivoInvalido("Falta la línea IG|DDMMAAAA|")
    if len(igs) > 1:
        raise ArchivoInvalido("Línea IG duplicada")
    f = igs[0].split("|")[1]
    try:
        if not re.fullmatch(r"[0-9]{8}", f):
            raise ValueError
        fecha = date(int(f[4:]), int(f[2:4]), int(f[:2]))
        if fecha.year < 2000:
            raise ValueError
    except ValueError:
        raise ArchivoInvalido(f"Fecha IG inválida: {f!r}") from None
    cierres: dict[str, int] = {}
    for linea in lineas:
        if not linea.startswith("R|"):
            continue
        c = linea.split("|")
        if len(c) < 5:
            raise ArchivoInvalido(f"Renglón R con campos insuficientes: {linea!r}")
        ticker = c[2].strip(" ")
        if not ticker:
            raise ArchivoInvalido(f"Ticker R vacío: {linea!r}")
        if ticker in cierres:
            raise ArchivoInvalido(f"Ticker R duplicado: {ticker}")
        cierres[ticker] = _centimos(c[4], ticker)
    if not cierres:
        raise ArchivoInvalido("No hay renglones R")
    return Cierre(fecha.year * 10000 + fecha.month * 100 + fecha.day, cierres)


def precio(datos: bytes, ticker: str) -> tuple[int, int, str]:
    c = parsear(datos)
    if ticker not in c.cierres:
        raise ArchivoInvalido(f"Ticker {ticker} no está en el archivo")
    return c.cierres[ticker], c.fecha, sha256_hex(datos)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("uso: python -m oraculo.parser ARCHIVO TICKER", file=sys.stderr)
        return 1
    try:
        cent, fecha, sha = precio(leer(argv[0]), argv[1])
    except (ArchivoInvalido, OSError) as e:
        print(e, file=sys.stderr)
        return 1
    print(json.dumps({"ticker": argv[1], "centimos": cent, "fecha": fecha, "sha256": sha}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
