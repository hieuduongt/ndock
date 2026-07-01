#!/usr/bin/env bash
# Smoke test: build/install dylib → Dock chạy + inject active.
#   bash scripts/verify_dock.sh
#   bash scripts/verify_dock.sh --install
#   bash scripts/verify_dock.sh --gui
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
unset DYLD_INSERT_LIBRARIES 2>/dev/null || true

cd "$ROOT"

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

sleep 2

if ! pgrep -x Dock >/dev/null; then
  echo "FAIL: Dock not running"
  [[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
  exit 1
fi

INJECTED="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || true)"
if [[ -z "$INJECTED" ]] || [[ "$INJECTED" != "$DYLIB" ]]; then
  echo "FAIL: DYLD_INSERT_LIBRARIES not set to $DYLIB"
  [[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
  exit 1
fi

if [[ ! -f "$DYLIB" ]]; then
  echo "FAIL: dylib missing at $DYLIB"
  [[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
  exit 1
fi

echo "RESULT: PASS (Dock pid=$(pgrep -x Dock), inject ok)"
[[ "$GUI" -eq 1 ]] && read -r -p "Nhấn Enter để đóng..." _
exit 0
