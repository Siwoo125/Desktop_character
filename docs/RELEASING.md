# 빌드와 릴리스

버전은 루트 `VERSION`, `Info.plist`의 공개 버전, `windows/desktop_pet/__init__.py`, `windows/app.manifest`를 함께 갱신합니다. macOS 빌드 번호도 올리세요. `python3 scripts/check_release.py`로 일관성을 검사합니다.

## macOS Universal

macOS 13 이상과 Xcode Command Line Tools가 필요합니다.

```sh
DESKTOP_DOG_ARCHS="arm64 x86_64" ./scripts/build.sh
python3 scripts/package_macos.py
python3 scripts/package_macos_installer.py
python3 scripts/check_macos_installer.py
```

`dist/DesktopCharacter-1.1.0-macOS-Universal.zip`과 `dist/DesktopCharacter-1.1.0-macOS-Universal-Installer.dmg`에 두 CPU 아키텍처가 포함됩니다. DMG의 설치 앱은 관리자 권한 없이 `~/Applications`에 복사하고 완료 후 실행합니다. 업데이트 전 실행 중인 앱을 종료해야 합니다. 설치 트랜잭션 검사는 임시 폴더에서 최초 설치·업데이트·다른 파일/심볼릭 링크 보호를 확인합니다. 최종 DMG를 읽기 전용으로 마운트해 외부 설치 앱과 내부 앱의 서명·버전·아키텍처를 검사합니다. 앱은 ad-hoc 서명과 검증을 하며 Developer ID 서명·공증은 하지 않습니다. Universal 패키징은 두 아키텍처가 모두 있는지 검사합니다.

## Windows x64

Windows 10/11 x64와 Python 3.13 x64에서:

```bat
python -m venv .venv-windows
.venv-windows\Scripts\python -m pip install -r windows\requirements.txt pyinstaller==6.22.3
.venv-windows\Scripts\python windows\launch.py --self-test --validate-assets --widget-check
.venv-windows\Scripts\python windows\build.py
```

또는 `windows/build.cmd`를 실행하세요. 설치 파일은 PowerShell에서 `./scripts/package_windows_installer.ps1`로 만듭니다. 공식 Inno Setup 7.1.0 x64 도구를 고정 SHA-256으로 확인한 뒤 사용자 권한으로 설치합니다. 완성된 `dist/DesktopCharacter-1.1.0-Windows-x64-Setup.exe`는 앱 전체 폴더를 사용자별 경로에 설치하며 완료 화면의 실행 옵션은 기본 선택입니다. 무인 설치에서는 실행하지 않습니다. CI에서 `./scripts/check_windows_installer.ps1`로 무인 설치 → 설치된 EXE 검사 → 제거 → 사용자 데이터 유지까지 확인합니다. `dist/DesktopCharacter-1.1.0-Windows-x64.zip` 전체를 배포합니다. `--onedir` 구조로 Python·Qt DLL은 `_internal`에 동적으로 로딩되며 EXE에 정적 결합하지 않습니다. Qt Addons는 설치하지 않습니다. `BUILD-INFO.json`에는 정확한 Python·라이브러리 버전과 빌드 커밋이 기록됩니다.

배포된 LGPL 라이브러리는 같은 ABI의 수정 빌드로 교체할 수 있습니다. 원래 파일을 보관하고 `_internal`의 해당 DLL·모듈을 호환되는 빌드로 교체하거나 이 저장소에서 앱 전체를 다시 만드세요. 라이브러리 수정의 디버깅을 위한 역공학을 금지하지 않습니다. 활성화·무결성 잠금 등 교체를 제한하는 장치는 없습니다.

### 외부 라이브러리의 대응 소스

배포물의 `SOURCE-CODE.txt`에도 아래 경로를 제공합니다. 수정하지 않은 upstream 릴리스입니다. 각 소스에 자체 빌드 안내와 라이선스가 있습니다.

- Qt 6.10.2: https://download.qt.io/archive/qt/6.10/6.10.2/submodules/ (QtCore/Gui/Widgets는 `qtbase`, SVG 플러그인은 `qtsvg`, 추가 이미지 플러그인은 `qtimageformats`; 해당 모듈의 `*-everywhere-src-6.10.2.tar.xz`)
- PySide6 / Shiboken6 6.10.2: https://download.qt.io/official_releases/QtForPython/pyside6/PySide6-6.10.2-src/ 및 https://code.qt.io/cgit/pyside/pyside-setup.git/tag/?h=v6.10.2
- Pillow 12.0.0: https://github.com/python-pillow/Pillow/releases/tag/12.0.0
- Python: `BUILD-INFO.json`의 버전에 해당하는 https://www.python.org/downloads/source/
- PyInstaller 6.22.3: https://github.com/pyinstaller/pyinstaller/releases/tag/v6.22.3

Qt 빌드: https://doc.qt.io/qt-6/windows-building.html

PySide 빌드: https://doc.qt.io/qtforpython-6/building_from_source/index.html

`licenses/`에는 설치한 패키지의 라이선스·저작권 파일, Python 라이선스와 프로젝트 에셋 라이선스를 보존합니다. 패키지에서 누락될 수 있는 Qt/PySide의 LGPL·GPL 전문과 외부 구성요소 고지는 `licenses/Qt-6.10.2/`에도 보관합니다. 이 파일들은 공식 소스 아카이브에서 수집했고 URL과 SHA-256을 함께 기록했습니다. 의존성 갱신 시 `python3 scripts/vendor_qt_notices.py`로 갱신하고 검토하세요. 이 수집에는 네트워크가 필요하지만 일반 앱 빌드는 저장소에 포함된 고지를 사용합니다. 별도 통지가 적용되는 플러그인·하위 라이브러리는 그 통지를 따릅니다.

## GitHub Actions

`release.yml`은 main 푸시·수동 실행·v* 태그에 대해 macOS Universal과 Windows x64를 실제 운영체제에서 빌드합니다. 소스 검사 후 Windows는 만들어진 EXE를 별도로 실행해 검사하고, ZIP 2개와 설치 파일(DMG / Setup EXE) 2개를 아티팩트로 보관합니다. v* 태그는 두 빌드가 모두 성공한 경우 배포 파일 4개와 `SHA256SUMS.txt`를 **초안 릴리스**로 올립니다. 외부 Action은 커밋 SHA로 고정합니다.

공개 순서:

1. main의 검사 결과와 아티팩트를 확인합니다.
2. 검증한 커밋에 `v1.1.0` 같은 태그를 만들어 푸시합니다.
3. 태그 실행이 만든 초안의 ZIP 2개·설치 파일 2개·버전·해시·릴리스 설명을 확인합니다.
4. `gh release edit v1.1.0 --draft=false --latest`로 공개합니다.

각 ZIP의 `BUILD-INFO.json`이 태그 커밋을 가리키는지 확인하세요. 공개한 버전 태그를 다른 커밋으로 이동하지 마세요. 해시는 다운로드 손상 확인용이며 배포자 코드 서명이나 안전성 보증을 대신하지 않습니다.

설치 파일을 사용자가 열고 설치에 동의한 후에만 자동 실행합니다. 브라우저 다운로드 즉시 실행, 로그인 자동 시작, Gatekeeper/SmartScreen 우회는 구현하지 않습니다. 설치 파일에도 배포자 인증서 서명·공증은 없습니다. DMG는 임시 서명된 Universal 설치 앱을 포함합니다. Windows 설치 파일 생성에 사용한 Inno Setup은 [공식 라이선스](https://github.com/jrsoftware/issrc/blob/is-7_1_0/license.txt)를 따르며 앱의 MIT/이미지 라이선스와 별개입니다.
