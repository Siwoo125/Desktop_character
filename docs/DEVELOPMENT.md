# 개발 안내

사용자 조작은 [README](../README.md), Windows 상세 내용은 [Windows 안내](../windows/README.md)를 참고하세요.

## 구조

| 경로 | 역할 |
| --- | --- |
| `Sources/PetCollection.swift` | macOS 진입점, 공용 메뉴, 여러 캐릭터 복원·관리 |
| `Sources/DesktopDog.swift` | 개별 투명 창, 입력·물리·애니메이션 연결 |
| `Sources/PetPhysics.swift`, `WindowLedges.swift`, `ClimbPlanner.swift` | 중력, 창 테두리, 가림, 순차 등반 |
| `Sources/RoamingRhythm.swift` | 캐릭터별 독립 이동·휴식 시간표 |
| `Sources/IdlePlayback.swift`, `HopPlayback.swift`, `CursorPlay.swift` | 동작 프레임과 커서 잡기 상태 |
| `Sources/PetCharacter.swift`, `SpriteAtlas.swift` | 기본 캐릭터 정의, PNG·프레임 로딩 |
| `Sources/CharacterCreator.swift`, `CustomCharacter.swift` | 생성 UI, PNG 검사, 사용자 보관함 |
| `Sources/CharacterLibraryWindow.swift` | + / − 관리와 사용자 캐릭터 삭제 |
| `windows/desktop_pet/` | 동일 기능의 Qt/Win32 구현 |
| `img/` | 두 플랫폼 공용 PNG. 권리는 `ASSET_LICENSES.md` 참고 |

macOS 빌드에는 외부 Swift 패키지가 없습니다. Windows는 Python 3.11~3.14 x64를 대상으로 하며 릴리스 CI는 3.13을 사용합니다. 설정 폴더 이름 `DesktopFriends`와 macOS 번들 ID `local.desktopdog.idle`는 기존 설정 호환을 위해 유지합니다.

## 빌드·검사

저장소 최상위에서 실행합니다. macOS:

```sh
./scripts/build.sh
"build/바탕화면 강아지.app/Contents/MacOS/DesktopDog" --self-test --character bonobono --character-window-check --cursor-window-check --creator-window-check --collection-window-check
```

물리·좌우 연결·순차 등반·프레임·커서 상태·이미지·생성 UI·보관함·여러 캐릭터·기본 강아지 복원을 검사합니다. 테스트는 임시 보관함과 테스트용 커서를 사용합니다. `--keyboard-window-check`는 실제 창 포커스 환경을 요구하므로 무인 CI에는 포함하지 않습니다.

Windows:

```bat
python -m venv .venv-windows
.venv-windows\Scripts\python -m pip install -r windows\requirements.txt
.venv-windows\Scripts\python windows\launch.py --self-test --validate-assets --widget-check
.venv-windows\Scripts\python windows\launch.py --diagnose
```

`--widget-check`는 offscreen Qt와 테스트용 Win32를 사용하며 실제 포인터를 움직이지 않습니다. `--diagnose`는 실제 Windows 모니터·DPI·보이는 창 테두리를 읽기만 합니다. 창 제목이나 화면 내용은 수집하지 않습니다. `--check-report 경로`로 결과를 파일에 남길 수 있습니다. PyInstaller GUI 실행 파일은 콘솔이 없어 검사 시 이 옵션을 사용하며, 생략 시 임시 폴더의 `DesktopCharacter-checks.log`에 기록합니다.

macOS에서도 `python3 windows/launch.py --self-test`로 플랫폼 독립 로직을 검사할 수 있습니다. Qt 검사는 별도 가상환경에 requirements를 설치하세요. 쉼표·한글 경로에서 Qt의 자동 `qt.conf` 경로 해석 문제가 있어 `launch.py`에서 플러그인 경로를 명시합니다.

## 동작과 플랫폼 차이

캐릭터별 다음 행동 지연은 0.8~4.5초, 이동은 1.5~5.5초, 휴식은 1.2~6초입니다. 30%는 이동 없이 쉬며, 이동 중 달리기 선택은 40%입니다. 반복 타이머를 공유하지 않고 개별 다음 행동을 예약합니다. 진행 중인 낮은 창부터의 순차 등반은 끝까지 이어갑니다.

macOS는 현재 프로세스의 모든 창을 제외한 Core Graphics 창 정보로 발판을 구성합니다. 커서는 실제 좌표를 고정하지 않고 잠시 숨기며 앞발에 그립니다. 다른 앱에 포커스가 있을 때 숨기기 위해 SkyLight의 `SetsCursorInBackground` 속성을 런타임에 사용합니다. 이 **비공개 API**를 사용할 수 없으면 백그라운드 커서 잡기를 중단합니다. OS 호환성을 재검사해야 하며 App Store용 구현이 아닙니다.

Windows는 공개 Win32/DWM API와 PySide6 투명 창을 사용합니다. 실제 포인터를 손 접점으로 옮기고, 입력이 없었으면 원위치로 복구합니다. 사용자가 움직이거나 클릭하면 바로 해제합니다. 시스템 커서를 교체하거나 잠그지 않습니다. DLL 함수의 인자·반환형과 화면별 DPI/음수 좌표 변환은 `win32.py`에서 관리합니다.

두 플랫폼 모두 여러 캐릭터 중 한 마리만 커서 소유권을 갖습니다. 제거·캐릭터 변경·메뉴·숨기기·일시정지·종료 시 해제하며, 생성·관리 UI에서는 모든 캐릭터를 멈춥니다. 키보드는 활성 캐릭터 창의 이벤트를 사용하고 전역 키보드 후킹을 하지 않습니다.

## 에셋·사용자 데이터

강아지 기본 정지는 `유휴상태.png` 첫 프레임을 사용합니다. 원본 `정지상태.png`도 제작 예시로 유지합니다. 8프레임 시트는 4×2, 시선은 3×1입니다. 보노보노의 `08-cursor-jump.png`, `10-cursor-roll.png`는 커서가 그려진 참고 이미지라 런타임 재생에서는 제외합니다. 나머지 09·11번은 커서가 없는 실제 동작입니다.

사용자 PNG는 투명 배경·격자·빈 프레임·해상도를 검증하고 canonical 파일명과 `character.json`으로 새 UUID 폴더에 저장합니다. `.pending` 폴더에 작성한 뒤 이동하므로 실패한 저장이 유효한 캐릭터로 노출되지 않습니다. 사용자 이미지를 커밋하거나 릴리스에 포함하지 마세요.

## 수동 확인

자동 검사 후 실제 macOS/Windows에서 투명 창·트레이, 2종류와 중복 복사본의 독립 동작, 드래그·배율, 여러 창의 가림·이동·최소화, 혼합 DPI 모니터, 조종 포커스, 커서 잡기의 중단·복귀, 생성·삭제·재실행 복원을 확인하세요. 호스팅 CI 검사는 모든 실기기 환경을 대체하지 않습니다.
