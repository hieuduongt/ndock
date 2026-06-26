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
  rm -f "$HOME/Library/LaunchAgents/com.ndock.inject.plist"
  launchctl unsetenv DYLD_INSERT_LIBRARIES 2>/dev/null
  rm -rf "$NDOCK_HOME"
  killall Dock 2>/dev/null
  print "Đã gỡ N-Dock."
  print "DYLD_INSERT_LIBRARIES=$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null || print '(unset)')"
}

case "${1:-help}" in
  uninstall)
    ndock_uninstall
    ;;
  stub)
    ndock_ensure_stub
    ;;
  build)
    shift
    ndock_ensure_stub || return 1
    "$NDOCK_ROOT/build.sh" "$@"
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
    print "  source ./recover.zsh stub"
    print "  source ./recover.zsh build"
    print "  source ./recover.zsh app"
    print "  source ./recover.zsh package"
    ;;
esac
