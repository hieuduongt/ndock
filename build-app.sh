#!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/dist/NDock.app"
BIN="$APP/Contents/MacOS/NDock"
RES="$APP/Contents/Resources"
ICONSET="$DIR/App/AppIcon.iconset"

cd "$DIR"
"$DIR/build.sh" build
[ -f NDock.dylib ] || { echo "Build dylib thất bại."; exit 1; }
if [ "$(wc -c < NDock.dylib | tr -d ' ')" -lt 100000 ]; then
  echo "NDock.dylib vẫn là stub — build thất bại." >&2
  exit 1
fi
[ -d "$ICONSET" ] || { echo "Thiếu App/AppIcon.iconset" >&2; exit 1; }
if ! codesign -f -s - bootstrap/NDock.stub.dylib >/dev/null 2>&1; then
  rm -f bootstrap/NDock.stub.dylib
  "$DIR/bootstrap/build-stub.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc "$DIR/App/NDockCore.swift" "$DIR/App/main.swift" \
  -O \
  -target arm64-apple-macos12.0 \
  -framework AppKit \
  -framework Foundation \
  -o "$BIN"

cp App/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
cp NDock.dylib "$RES/NDock.dylib"
cp bootstrap/NDock.stub.dylib "$RES/NDock.stub.dylib"

codesign -f -s - "$RES/NDock.dylib"
codesign -f -s - "$RES/NDock.stub.dylib"
codesign -f -s - "$BIN"
codesign -f -s - "$APP"
touch "$APP"

echo "Đã tạo: $APP ($(du -sh "$APP" | cut -f1))"
echo "Mở: open $APP"