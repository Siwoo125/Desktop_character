"""Package only Windows sources + shared sprites, with NFC filenames and CRLF CMDs."""
from pathlib import Path
import unicodedata
import zipfile

root = Path(__file__).resolve().parents[1]
version = (root / "VERSION").read_text().strip()
output = root / "dist" / f"DesktopCharacter-{version}-Windows-Source.zip"
output.parent.mkdir(parents=True, exist_ok=True)
files = [root / "Start-Windows.cmd"]
files += [root / name for name in ("VERSION", "README.md", "LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md")]
files += [p for directory in ("licenses", "docs") for p in (root / directory).rglob("*") if p.is_file()]
files += [p for p in (root / "windows").rglob("*") if p.is_file() and "__pycache__" not in p.parts]
files += list((root / "img").rglob("*.png"))
files += list((root / "ai").glob("*.json"))
prefix = "DesktopFriends-Windows/"
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(files):
        data = path.read_bytes()
        if path.suffix.lower() == ".cmd":
            data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        name = unicodedata.normalize("NFC", path.relative_to(root).as_posix())
        archive.writestr(prefix + name, data)
    archive.writestr(prefix + "README-Windows.md", (root / "windows" / "README.md").read_bytes())
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert all(unicodedata.is_normalized("NFC", name) for name in archive.namelist())
    assert b"\r\n" in archive.read(prefix + "Start-Windows.cmd")
print(output)
