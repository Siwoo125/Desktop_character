"""Create a project-local Windows venv; never install into the user's base Python."""
from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import subprocess
import sys


def main() -> int:
    if sys.platform != "win32":
        print("Run this setup on Windows.")
        return 2
    if not (3, 11) <= sys.version_info[:2] < (3, 15) or struct.calcsize("P") != 8:
        print("Install 64-bit Python 3.11-3.14 (3.13 recommended): https://www.python.org/downloads/windows/")
        return 2
    root = Path(__file__).resolve().parents[1]
    environment = root / ".venv-windows"
    python = environment / "Scripts" / "python.exe"
    requirements = root / "windows" / "requirements.txt"
    if not python.is_file():
        subprocess.run([sys.executable, "-m", "venv", str(environment)], check=True)
    digest = hashlib.sha256(requirements.read_bytes()).hexdigest()
    marker = environment / ".desktop-friends-dependencies"
    installed = subprocess.run([str(python), "-c", "import PySide6.QtWidgets, PIL.Image"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not installed or not marker.exists() or marker.read_text(encoding="ascii").strip() != digest:
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(requirements)], check=True)
        subprocess.run([str(python), "-c", "import PySide6.QtWidgets, PIL.Image"], check=True)
        marker.write_text(digest, encoding="ascii")
    print("DesktopFriends setup is ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        print(f"Setup failed (exit {error.returncode}). Check Python and your internet connection.", file=sys.stderr)
        raise SystemExit(error.returncode)
