import contextlib
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from collections.abc import Iterator
from pathlib import Path

import pytest
from web3 import Web3

RAIZ = Path(__file__).resolve().parents[2]


@contextlib.contextmanager
def nodo_hardhat(puerto: int) -> Iterator[Web3]:
    """Levanta `hardhat node` en el puerto y lo apaga por PID (árbol completo) al salir."""
    npx = shutil.which("npx")
    if not npx:
        pytest.skip("sin npx")
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", puerto)) == 0:
            pytest.skip(f"puerto {puerto} ocupado")
    proc = subprocess.Popen([npx, "hardhat", "node", "--port", str(puerto)], cwd=RAIZ,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            start_new_session=sys.platform != "win32")
    try:
        w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{puerto}"))
        for _ in range(120):
            if proc.poll() is not None:
                pytest.skip("el nodo terminó al arrancar")
            try:
                if w3.eth.chain_id == 31337:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            pytest.skip("el nodo no arrancó")
        yield w3
    finally:
        if sys.platform == "win32":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True)
        else:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
