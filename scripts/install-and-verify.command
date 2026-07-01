#!/bin/bash
# Double-click trong Finder — gọi verify đầy đủ (build + install + kiểm tra widget).
exec "$(cd "$(dirname "$0")" && pwd)/verify_dock.sh" --install --gui
