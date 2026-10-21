"""Build an unprivileged Universal installer in a read-only DMG."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def main():
    if sys.platform != "darwin":
        raise SystemExit("Build the macOS installer on macOS.")
    root = Path(__file__).resolve().parents[1]
    version = (root / "VERSION").read_text().strip()
    payload = root / ".build/mac-package/DesktopCharacter/바탕화면 강아지.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(payload)], check=True)
    work = root / ".build/mac-installer"
    if work.exists():
        shutil.rmtree(work)
    image = work / "image"
    installer = image / "바탕화면 친구 설치.app"
    contents = installer / "Contents"
    (contents / "MacOS").mkdir(parents=True)
    (contents / "Resources").mkdir()
    binaries = []
    for arch in ("arm64", "x86_64"):
        binary = work / f"Installer-{arch}"
        subprocess.run(["swiftc", "-parse-as-library", "-O", "-target", f"{arch}-apple-macosx13.0",
                        "-module-cache-path", str(root / ".build/module-cache"),
                        str(root / "installers/macos/Installer.swift"), "-o", str(binary)], check=True)
        binaries.append(str(binary))
    executable = contents / "MacOS/Installer"
    subprocess.run(["lipo", "-create", *binaries, "-output", str(executable)], check=True)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": "local.desktopcharacter.installer", "CFBundleExecutable": "Installer",
                      "CFBundleName": "바탕화면 친구 설치", "CFBundlePackageType": "APPL",
                      "CFBundleShortVersionString": version, "CFBundleVersion": version.replace(".", ""),
                      "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": True}, stream)
    shutil.copytree(payload, contents / "Resources" / payload.name)
    for name in ("README.md", "LICENSE", "ASSET_LICENSES.md", "THIRD_PARTY_NOTICES.md", "BUILD-INFO.json"):
        shutil.copy2(payload.parent / name, image / name)
    (image / "설치 안내.txt").write_text(
        "바탕화면 친구 설치.app을 열고 ‘설치하고 실행’을 누르세요.\n"
        "~/Applications에 설치한 뒤 앱을 바로 실행합니다. 첫 실행에는 강아지 한 마리가 나타납니다.\n"
        "이미 실행 중이면 앱 메뉴에서 ‘모두 종료’ 후 설치하세요. 기존 캐릭터와 API 설정은 유지합니다.\n"
        "다운로드만으로 실행되지는 않습니다. 로그인 시 자동 실행도 설정하지 않습니다.\n"
        "Developer ID 서명·공증이 없는 배포입니다. macOS가 차단하면 출처를 확인하고 Apple 안내를 참고하세요:\n"
        "https://support.apple.com/ko-kr/102445\n"
        "삭제: 앱을 종료한 뒤 ~/Applications/바탕화면 강아지.app을 휴지통으로 옮기세요.\n", encoding="utf-8")
    subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(installer)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(installer)], check=True)
    subprocess.run([str(executable), "--self-test"], check=True)
    output = root / "dist" / f"DesktopCharacter-{version}-macOS-Universal-Installer.dmg"
    if output.exists():
        output.unlink()
    subprocess.run(["hdiutil", "create", "-volname", f"DesktopCharacter {version}", "-srcfolder", str(image),
                    "-format", "UDZO", "-ov", str(output)], check=True)
    subprocess.run(["hdiutil", "verify", str(output)], check=True)
    print(output)


if __name__ == "__main__":
    main()
