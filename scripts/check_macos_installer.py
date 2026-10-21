"""Mount the final DMG read-only and validate its signed Universal payload."""
from pathlib import Path
import json
import plistlib
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    image = root / "dist" / f"DesktopCharacter-{version}-macOS-Universal-Installer.dmg"
    with tempfile.TemporaryDirectory(prefix="desktopcharacter-dmg-") as directory:
        mount = Path(directory) / "volume"
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)], check=True)
        try:
            installer = mount / "바탕화면 친구 설치.app"
            payload = installer / "Contents/Resources/바탕화면 강아지.app"
            for bundle, executable in ((installer, "Installer"), (payload, "DesktopDog")):
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
                info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                assert info["CFBundleShortVersionString"] == version
                binary = bundle / "Contents/MacOS" / executable
                archs = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
                assert set(archs) == {"arm64", "x86_64"}
            build_info = json.loads((mount / "BUILD-INFO.json").read_text())
            assert build_info["version"] == version
            assert build_info["commit"] == subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            assert (payload / "Contents/Resources/ai/motions.json").is_file()
            assert (payload / "Contents/Resources/licenses/CC-BY-4.0.txt").is_file()
            subprocess.run([str(installer / "Contents/MacOS/Installer"), "--self-test"], check=True)
            print(f"DMG installer, signed payload and installation checks passed: {version}")
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True)


if __name__ == "__main__":
    main()
