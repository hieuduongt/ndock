#!/usr/bin/env -u DYLD_INSERT_LIBRARIES bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/build-app.sh"
ZIP="$DIR/dist/NDock.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$DIR/dist/NDock.app" "$ZIP"
echo "Zip: $ZIP ($(du -h "$ZIP" | cut -f1))"
