#!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
OUT="$ROOT/NDock.dylib"
STUB="$DIR/NDock.stub.dylib"

nd_stub_valid() {
  [ -f "$1" ] && codesign -f -s - "$1" >/dev/null 2>&1
}

nd_is_real_dylib() {
  [ -f "$OUT" ] && [ "$(wc -c < "$OUT" | tr -d ' ')" -ge 100000 ]
}

nd_build_stub() {
  local dest="$1"
  clang -dynamiclib -o "$dest" "$DIR/empty.c" \
    -arch arm64 -arch arm64e \
    -mmacosx-version-min=12.0 \
    -install_name "@rpath/NDock.dylib"
  codesign -f -s - "$dest"
}

if nd_stub_valid "$STUB"; then
  if nd_is_real_dylib; then
    echo "Stub: $STUB (valid)"
  else
    cp -f "$STUB" "$OUT"
    codesign -f -s - "$OUT"
    echo "Stub: $OUT (from $STUB)"
  fi
  exit 0
fi

echo "Stub hỏng hoặc thiếu — rebuild $STUB" >&2
rm -f "$STUB"
nd_build_stub "$STUB"

if nd_is_real_dylib; then
  echo "Stub: $STUB (rebuilt, giữ nguyên $OUT)"
else
  cp -f "$STUB" "$OUT"
  echo "Stub: $OUT (+ saved $STUB)"
fi
