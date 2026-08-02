#!/bin/bash
# Builds the app and packages it into a double-clickable "Memory Card Test.app" bundle.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Compiling (release)…"
swift build -c release

BIN=".build/release/MemoryCardTest"
APP="Memory Card Test.app"

echo "==> Packaging $APP…"
rm -rf "$APP" "CardCheck.app"   # remove old-named bundle too
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MemoryCardTest"
cp "Info.plist" "$APP/Contents/Info.plist"

# Generate the app icon from icon.png (a square PNG, ideally 1024x1024) if present.
ICON_SRC="icon.png"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> Generating AppIcon.icns from $ICON_SRC…"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz         "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
        sips -z $((sz*2)) $((sz*2)) "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET")"
else
    echo "==> (No $ICON_SRC found — building without a custom icon.)"
fi

# Ad-hoc sign so Gatekeeper/launchd is happy running it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: $(pwd)/$APP"
echo "    Launch with:  open \"$APP\""
