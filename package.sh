#!/bin/bash
# Builds the app and produces a downloadable zip containing the app bundle,
# README.rtf, and LICENSE.txt inside a "Memory Card Test" folder.
set -euo pipefail
cd "$(dirname "$0")"

APP="Memory Card Test.app"
ZIP="Memory Card Test.zip"

# 1) Build the .app (also (re)generates the icon).
./build.sh

# 2) Stage the release folder.
STAGE="$(mktemp -d)/Memory Card Test"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "README.rtf" "LICENSE.txt" "$STAGE/"

# 3) Zip it with ditto so the .app bundle + signature are preserved.
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIP"
rm -rf "$(dirname "$STAGE")"

echo "==> Wrote $(pwd)/$ZIP"
ditto -x -k "$ZIP" "$(mktemp -d)" >/dev/null 2>&1 && echo "    (verified: archive extracts cleanly)"
ls -lh "$ZIP"
