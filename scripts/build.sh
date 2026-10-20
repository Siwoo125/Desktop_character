#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
APP_DIR="$PROJECT_DIR/build/바탕화면 강아지.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/img" "$PROJECT_DIR/.build/module-cache"
# Set DESKTOP_DOG_ARCHS="arm64 x86_64" for the Universal release.
ARCHS="${DESKTOP_DOG_ARCHS:-$(uname -m)}"
BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; esac
  BINARY="$PROJECT_DIR/.build/DesktopDog-$ARCH"
  swiftc -parse-as-library -O -target "$ARCH-apple-macosx13.0" \
    -module-cache-path "$PROJECT_DIR/.build/module-cache" \
    Sources/*.swift -o "$BINARY"
  BINARIES+=("$BINARY")
done
if [ "${#BINARIES[@]}" -gt 1 ]; then
  xcrun lipo -create "${BINARIES[@]}" -output "$APP_DIR/Contents/MacOS/DesktopDog"
else
  cp "${BINARIES[0]}" "$APP_DIR/Contents/MacOS/DesktopDog"
fi
cp img/정지상태.png img/유휴상태.png "img/오른쪽으로 걷는 상태.png" \
  "img/오른쪽 뛰는 상태.png" \
  "img/세 방향으로 올려보는 픽셀 강아지.png" \
  "img/puppy-jump-8frames-no-cursor.png" \
  "img/puppy-roll-8frames-no-cursor.png" \
  "img/픽셀 강아지의 힘찬 도약 스프라이트 시트.png" "$APP_DIR/Contents/Resources/img/"
mkdir -p "$APP_DIR/Contents/Resources/img/bonobono-sprites"
cp img/bonobono-sprites/*.png "$APP_DIR/Contents/Resources/img/bonobono-sprites/"
cp img/bonobono-sprites/*.txt "$APP_DIR/Contents/Resources/img/bonobono-sprites/"
cp LICENSE ASSET_LICENSES.md THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/"
mkdir -p "$APP_DIR/Contents/Resources/licenses"
cp licenses/* "$APP_DIR/Contents/Resources/licenses/"
cp Info.plist "$APP_DIR/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
printf '빌드 완료: %s\n' "$APP_DIR"
