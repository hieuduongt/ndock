#!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="$ROOT/NDock.dylib"
STUB="$DIR/NDock.stub.dylib"

if [ -f "$STUB" ]; then
  cp -f "$STUB" "$OUT"
  codesign -f -s - "$OUT" 2>/dev/null || true
  echo "Stub: $OUT (from bootstrap/NDock.stub.dylib)"
  exit 0
fi

clang -dynamiclib -o "$OUT" "$DIR/empty.c" \
  -arch arm64 -arch arm64e \
  -mmacosx-version-min=12.0 \
  -install_name "@rpath/NDock.dylib"
codesign -f -s - "$OUT"
cp -f "$OUT" "$STUB"
echo "Stub: $OUT (+ saved bootstrap/NDock.stub.dylib)"
