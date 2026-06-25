#!/bin/bash
set -e

DYLIB="NDock.dylib"
DOCK_BIN="/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

case "$1" in
  build)
    make
    ;;

  inject)
    if [ ! -f "$DYLIB" ]; then echo "Thiếu $DYLIB — chạy 'make' trước."; exit 1; fi
    DYLIB_ABS="$PWD/$DYLIB"

    echo "=== Kiểm tra ==="
    csrutil status 2>&1 | head -1
    LV=$(defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation 2>/dev/null || echo "0")
    echo "DisableLibraryValidation = $LV"
    if [ "$LV" != "1" ]; then
      echo "Cần: sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true && sudo reboot"
    fi

    launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB_ABS"
    killall Dock 2>/dev/null || true

    for _ in $(seq 1 30); do
      pgrep -x Dock >/dev/null && break
      sleep 0.2
    done
    sleep 2
    if ! pgrep -x Dock >/dev/null; then
      DYLD_INSERT_LIBRARIES="$DYLIB_ABS" "$DOCK_BIN" &
      sleep 2
    fi
    pgrep -x Dock >/dev/null || { echo "Không tìm thấy Dock."; exit 1; }
    echo "Dock pid=$(pgrep -x Dock | head -1)"
    echo "Gỡ inject: ./inject_test.sh uninject"
    ;;

  uninject)
    launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null || true
    killall Dock 2>/dev/null || true
    echo "Đã gỡ dylib, Dock restart sạch."
    ;;

  sipcheck)
    csrutil status
    defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation 2>/dev/null \
      || echo "DisableLibraryValidation chưa bật"
    ;;

  *)
    echo "N-Dock"
    echo "  $0 build     — build NDock.dylib"
    echo "  $0 inject    — inject vào Dock (SIP off + DisableLibraryValidation)"
    echo "  $0 uninject  — gỡ inject"
    echo "  $0 sipcheck  — kiểm tra điều kiện"
    ;;
esac
