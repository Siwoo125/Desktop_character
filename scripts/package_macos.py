"""Package the signed Universal app, notices and user guide on macOS."""
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys
import unicodedata
import zipfile


def main():
    if sys.platform != "darwin":
        raise SystemExit("Run this script on macOS after the Universal build.")
    root = Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    app = root / "build" / "바탕화면 강아지.app"
    binary = app / "Contents" / "MacOS" / "DesktopDog"
    archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if set(archs) != {"arm64", "x86_64"}:
        raise SystemExit('Release requires DESKTOP_DOG_ARCHS="arm64 x86_64" ./scripts/build.sh')
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    stage = root / ".build" / "mac-package" / "DesktopCharacter"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copytree(app, stage / app.name)
    for name in ("README.md", "LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(root / name, stage / name)
    shutil.copytree(root / "licenses", stage / "licenses")
    shutil.copytree(root / "docs", stage / "docs")
    info = {"version": version, "platform": "macOS", "architectures": archs,
            "minimum_os": "13.0", "build_host": platform.platform(),
            "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
            "swift": subprocess.check_output(["swift", "--version"], text=True).strip(),
            "signing": "ad-hoc; not Developer ID signed or notarized"}
    (stage / "BUILD-INFO.json").write_text(json.dumps(info, indent=2) + "\n")
    output = root / "dist" / f"DesktopCharacter-{version}-macOS-Universal.zip"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        output.unlink()
    # ditto's ZIP output may omit the UTF-8 flag for Korean names. Python's
    # writer marks UTF-8 correctly and preserves Unix modes (including +x).
    # This app has no resource forks or symlinks that require AppleDouble.
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(stage.rglob("*")):
            if path.is_symlink():
                raise ValueError(f"Unexpected symlink in portable app: {path}")
            name = unicodedata.normalize("NFC", path.relative_to(stage.parent).as_posix())
            archive.write(path, name)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
    print(output)


if __name__ == "__main__":
    main()
