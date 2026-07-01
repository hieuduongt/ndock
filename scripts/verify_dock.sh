#!/usr/bin/env bash
# Verify widget inject: build (hoặc install đầy đủ) → restart Dock → chờ VERIFY trong log.
#   bash scripts/verify_dock.sh           # nhanh: build + copy dylib
#   bash scripts/verify_dock.sh --install # clean build + ./ndock install
#   bash scripts/verify_dock.sh --gui     # chờ Enter khi xong (Finder)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="/tmp/ndock_debug.log"
DYLIB="$HOME/Library/Application Support/N-Dock/NDock.dylib"
MODE="quick"
GUI=0

for arg in "$@"; do
  case "$arg" in
    --install) MODE=install ;;
    --gui) GUI=1 ;;
  esac
done

launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null || true
launchctl unsetenv NDOCK_DEBUG 2>/dev/null || true
unset DYLD_INSERT_LIBRARIES 2>/dev/null || true

cd "$ROOT"
rm -f "$LOG"
launchctl setenv NDOCK_DEBUG 1

if [[ "$MODE" == "install" ]]; then
  echo "=== build ==="
  env -u DYLD_INSERT_LIBRARIES make clean-all build
  codesign -f -s - "$ROOT/NDock.dylib" >/dev/null
  echo "=== install ==="
  ./ndock install
else
  env -u DYLD_INSERT_LIBRARIES make build >/dev/null
  codesign -f -s - "$ROOT/NDock.dylib" >/dev/null
  mkdir -p "$(dirname "$DYLIB")"
  cp -f "$ROOT/NDock.dylib" "$DYLIB"
  codesign -f -s - "$DYLIB" >/dev/null
  launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB"
  killall Dock 2>/dev/null || true
  sleep 3
  for _ in $(seq 1 15); do
    pgrep -x Dock >/dev/null && break
    sleep 0.5
  done
  if ! pgrep -x Dock >/dev/null; then
    DYLD_INSERT_LIBRARIES="$DYLIB" \
      /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock >/dev/null 2>&1 &
    sleep 6
  fi
fi

for _ in $(seq 1 40); do
  [[ -f "$LOG" ]] && grep -q "VERIFY widgets=PASS" "$LOG" 2>/dev/null && break
  sleep 1
done

if ! pgrep -x Dock >/dev/null; then
  echo "FAIL: Dock not running"
  [[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
  exit 1
fi

echo "=== verify log ==="
grep "VERIFY" "$LOG" 2>/dev/null | tail -3 || true

if grep -q "VERIFY widgets=PASS" "$LOG" 2>/dev/null; then
  echo "RESULT: ALL PASS (Dock alive)"
  launchctl unsetenv NDOCK_DEBUG 2>/dev/null || true
  [[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
  exit 0
fi

echo "RESULT: FAIL"
grep "VERIFY" "$LOG" 2>/dev/null | tail -1 || echo "(no VERIFY line)"
[[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
exit 1
