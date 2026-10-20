"""Package the signed Universal app, notices and user guide on macOS."""
from pathlib import Path
import json
import platform
import shutil
import subprocess
import sys
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
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(output)], check=True)
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
    print(output)


if __name__ == "__main__":
    main()
