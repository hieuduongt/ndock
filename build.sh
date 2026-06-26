#!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
set -e
cd "$(dirname "$0")"

TARGET="${1:-build}"

nd_is_stub_dylib() {
  [ -f "$1" ] || return 1
  [ "$(wc -c < "$1" | tr -d ' ')" -lt 100000 ]
}

nd_restore_stub() {
  ./bootstrap/build-stub.sh
}

case "$TARGET" in
  build|all|app|package)
    if nd_is_stub_dylib NDock.dylib; then
      rm -f NDock.dylib
    fi
    ;;
  clean|clean-all)
    exec env -i \
      HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
      SHELL="/bin/bash" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
      /usr/bin/make "$@"
    ;;
esac

if [ ! -f NDock.dylib ]; then
  case "$TARGET" in
    build|all)
      : # make sẽ tạo dylib thật
      ;;
    *)
      nd_restore_stub || {
        echo "Thiếu NDock.dylib — chạy: source ./recover.zsh stub" >&2
        exit 1
      }
      ;;
  esac
fi

exec env -i \
  HOME="$HOME" \
  USER="${USER:-$(id -un)}" \
  LOGNAME="${LOGNAME:-$(id -un)}" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
  SHELL="/bin/bash" \
  LANG="${LANG:-en_US.UTF-8}" \
  TMPDIR="${TMPDIR:-/tmp}" \
  /usr/bin/make "$@"
