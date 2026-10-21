"""Build the Windows EXE on Windows, then ZIP the complete portable directory."""
from __future__ import annotations

from importlib import metadata
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys


def main() -> int:
    if sys.platform != "win32":
        print("Windows EXEs must be built on Windows. Use windows/build.cmd there.")
        return 2
    root = Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    work = root / ".build" / "windows-pyinstaller"
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--onedir", "--windowed",
                    "--name", "DesktopCharacter", "--manifest", str(root / "windows" / "app.manifest"),
                    "--paths", str(root / "windows"), "--add-data", f"{root / 'img'}:img",
                    "--add-data", f"{root / 'ai'}:ai",
                    "--distpath", str(root / "dist" / "windows"), "--workpath", str(work / "work"),
                    "--specpath", str(work), str(root / "windows" / "launch.py")], check=True)
    output = root / "dist" / "windows" / "DesktopCharacter"
    for name in ("README.md", "LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, output / name)
    shutil.copytree(root / "docs", output / "docs", dirs_exist_ok=True)
    shutil.copy2(root / "windows" / "THIRD_PARTY_NOTICES.txt", output / "THIRD_PARTY_NOTICES.txt")
    # Keep the installed license files alongside the portable Qt/Pillow distribution.
    licenses = output / "licenses"
    shutil.copytree(root / "licenses", licenses, dirs_exist_ok=True)
    packages = ("PySide6-Essentials", "shiboken6", "Pillow", "pyinstaller")
    for package in packages:
        distribution = metadata.distribution(package)
        for file in distribution.files or ():
            if "license" in str(file).lower() or "copying" in str(file).lower():
                source = distribution.locate_file(file)
                if source.is_file():
                    destination = licenses / package / str(file).replace("..", "_parent")
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
    python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if not python_license.exists():
        raise FileNotFoundError(f"Python license missing: {python_license}")
    shutil.copy2(python_license, licenses / "Python-LICENSE.txt")
    shutil.copy2(root / "windows" / "SOURCE-CODE.txt", output / "SOURCE-CODE.txt")
    info = {"version": version, "platform": platform.platform(), "architecture": platform.machine(),
            "python": platform.python_version(), "libraries": {p: metadata.version(p) for p in packages},
            "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
            "signing": "unsigned"}
    (output / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n", encoding="utf-8")
    archive = shutil.make_archive(str(root / "dist" / f"DesktopCharacter-{version}-Windows-x64"), "zip", output.parent, output.name)
    print(f"EXE: {output / 'DesktopCharacter.exe'}")
    print(f"ZIP: {archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
