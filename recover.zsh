#!/bin/zsh
# KHÔNG chạy: ./recover.zsh          ← sẽ crash (dyld inject)
# PHẢI chạy: source ./recover.zsh

emulate -L zsh
setopt NO_UNSET

unset DYLD_INSERT_LIBRARIES
typeset -g DYLD_INSERT_LIBRARIES

NDOCK_ROOT="${${(%):-%x}:A:h}"
NDOCK_HOME="${NDOCK_HOME:-$HOME/Library/Application Support/N-Dock}"
GUI_DOMAIN="gui/$(id -u)"

ndock_ensure_stub() {
  if [[ -f "$NDOCK_ROOT/NDock.dylib" ]]; then
    return 0
  fi
  "$NDOCK_ROOT/bootstrap/build-stub.sh"
}

ndock_uninstall() {
  launchctl bootout "$GUI_DOMAIN/com.ndock.inject" 2>/dev/null
  launchctl bootout "$GUI_DOMAIN/com.ndock.autoinstall" 2>/dev/null
  rm -f "$HOME/Library/LaunchAgents/com.ndock.inject.plist"
  rm -f "$HOME/Library/LaunchAgents/com.ndock.autoinstall.plist"

  local stub="$NDOCK_ROOT/bootstrap/NDock.stub.dylib"
  if [[ -f "$stub" ]] && codesign -f -s - "$stub" >/dev/null 2>&1; then
    command mkdir -p "$NDOCK_HOME"
    command cp -f "$stub" "$NDOCK_HOME/NDock.dylib"
    command codesign -f -s - "$NDOCK_HOME/NDock.dylib" 2>/dev/null
  elif [[ -f "$stub" ]]; then
    command rm -f "$stub"
    "$NDOCK_ROOT/bootstrap/build-stub.sh" >/dev/null
    command mkdir -p "$NDOCK_HOME"
    command cp -f "$stub" "$NDOCK_HOME/NDock.dylib"
    command codesign -f -s - "$NDOCK_HOME/NDock.dylib" 2>/dev/null
  fi

  launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null
  command killall Dock 2>/dev/null
  sleep 2
  command rm -f "$NDOCK_HOME/boot.sh" "$NDOCK_HOME/settings.plist"
  print "Đã gỡ N-Dock."
  if [[ -f "$NDOCK_HOME/NDock.dylib" ]]; then
    print "Giữ stub tại $NDOCK_HOME/NDock.dylib"
  fi
  print "DYLD_INSERT_LIBRARIES=$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || print '(unset)')"
}

ndock_restore_stub() {
  ndock_ensure_stub || return 1
  command mkdir -p "$NDOCK_HOME"
  command cp -f "$NDOCK_ROOT/bootstrap/NDock.stub.dylib" "$NDOCK_HOME/NDock.dylib"
  command codesign -f -s - "$NDOCK_HOME/NDock.dylib" 2>/dev/null
  print "Đã đặt stub tại $NDOCK_HOME/NDock.dylib"
  print "Tiếp theo: source ./recover.zsh uninstall"
}

case "${1:-help}" in
  uninstall)
    ndock_uninstall
    ;;
  restore-stub)
    ndock_restore_stub
    ;;
  stub)
    ndock_ensure_stub
    ;;
  build)
    shift
    ndock_ensure_stub || return 1
    "$NDOCK_ROOT/build.sh" "$@"
    ;;
  install-verify)
    launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null
    launchctl unsetenv NDOCK_DEBUG 2>/dev/null
    command bash "$NDOCK_ROOT/scripts/verify_dock.sh" --install
    ;;
  app)
    ndock_ensure_stub || return 1
    "$NDOCK_ROOT/build.sh" build
    "$NDOCK_ROOT/build-app.sh"
    ;;
  package)
    ndock_ensure_stub || return 1
    "$NDOCK_ROOT/build.sh" build
    "$NDOCK_ROOT/package.sh"
    ;;
  help|*)
    print "N-Dock recover (chạy bằng source, KHÔNG ./recover.zsh)"
    print ""
    print "  source ./recover.zsh uninstall"
    print "  source ./recover.zsh restore-stub   # khi Terminal crash vì thiếu dylib"
    print "  source ./recover.zsh stub"
    print "  source ./recover.zsh install-verify # build + install + verify"
    print "  source ./recover.zsh build"
    print "  source ./recover.zsh app"
    print "  source ./recover.zsh package"
    ;;
esac
