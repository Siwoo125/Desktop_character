"""Check release version consistency, legal files and optionally built ZIPs."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import unicodedata
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archives", nargs="*", type=Path)
    args = parser.parse_args()
    version = (ROOT / "VERSION").read_text().strip()
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), version
    plist = plistlib.loads((ROOT / "Info.plist").read_bytes())
    assert plist["CFBundleShortVersionString"] == version
    assert f'__version__ = "{version}"' in (ROOT / "windows/desktop_pet/__init__.py").read_text()
    manifest = ET.parse(ROOT / "windows/app.manifest").getroot()
    assert manifest.find("{urn:schemas-microsoft-com:asm.v1}assemblyIdentity").get("version") == version + ".0"
    for name in ("LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md", "licenses/CC-BY-4.0.txt",
                 "windows/SOURCE-CODE.txt", f"docs/releases/{version}.md"):
        assert (ROOT / name).stat().st_size > 100, name
    assert "Creative Commons Attribution 4.0" in (ROOT / "licenses/CC-BY-4.0.txt").read_text()
    qt_lgpl = "licenses/Qt-6.10.2/pyside-setup/LICENSES/LGPL-3.0-only.txt"
    assert "GNU LESSER GENERAL PUBLIC LICENSE" in (ROOT / qt_lgpl).read_text()
    assets = {unicodedata.normalize("NFC", p.relative_to(ROOT / "img").as_posix())
              for p in (ROOT / "img").rglob("*.png")}
    assert len(assets) == 19, assets
    catalog = json.loads((ROOT / "ai/motions.json").read_text())
    assert set(catalog["defaults"]) == {"openai", "gemini", "anthropic"}
    installer = (ROOT / "installers/windows/DesktopCharacter.iss").read_text()
    assert "PrivilegesRequired=lowest" in installer
    launch = installer.split("[Run]", 1)[1]
    assert "postinstall" in launch and "skipifsilent" in launch and "unchecked" not in launch
    assert "[UninstallDelete]" not in installer, "Do not delete user data when removing the app"
    for path in args.archives or ():
        with zipfile.ZipFile(path) as archive:
            assert archive.testzip() is None, path
            names = {unicodedata.normalize("NFC", n): n for n in archive.namelist()}
            assert not any("../" in n or n.startswith("/") for n in names), path
            info_names = [n for n in names if n.endswith("/BUILD-INFO.json")]
            assert len(info_names) == 1, info_names
            info = json.loads(archive.read(names[info_names[0]]))
            assert info["version"] == version, info
            assert re.fullmatch(r"[a-f0-9]{40}", info["commit"]), info
            for asset in assets:
                assert any(n.endswith("/img/" + asset) for n in names), asset
            assert any(n.endswith("/ai/motions.json") for n in names), "AI motion catalog missing"
            for notice in ("LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md", "licenses/CC-BY-4.0.txt", qt_lgpl):
                assert "DesktopCharacter/" + notice in names, notice
            if "Windows" in path.name:
                assert "DesktopCharacter/DesktopCharacter.exe" in names
                assert "DesktopCharacter/SOURCE-CODE.txt" in names
                assert "DesktopCharacter/licenses/Python-LICENSE.txt" in names
                assert any(n.endswith("/Qt6Core.dll") for n in names)
                assert any("licenses/PySide6-Essentials/" in n and "license" in n.lower() for n in names)
            else:
                assert set(info["architectures"]) == {"arm64", "x86_64"}
                assert any(n.endswith(".app/Contents/MacOS/DesktopDog") for n in names)
        print(f"ZIP validated: {path}")
    print(f"Release metadata and 19 shared PNGs validated: {version}")


if __name__ == "__main__":
    main()
