#!/bin/bash
# Builds the app and packages it into a double-clickable "Memory Card Test.app" bundle.
#
# By default this produces a UNIVERSAL binary (Apple Silicon + Intel) so the app
# runs on any Mac running macOS 13 or later. Building both slices takes about
# twice as long; for quick local iteration set NATIVE_ONLY=1 to build just this
# machine's architecture.
set -euo pipefail
cd "$(dirname "$0")"

APP="Memory Card Test.app"
DEPLOY_TARGET="13.0"

if [[ "${NATIVE_ONLY:-0}" == "1" ]]; then
    echo "==> Compiling (release, native arch only)…"
    swift build -c release
    BIN=".build/release/MemoryCardTest"
else
    echo "==> Compiling (release, arm64)…"
    swift build -c release --triple "arm64-apple-macosx${DEPLOY_TARGET}"  --scratch-path .build-arm64
    echo "==> Compiling (release, x86_64)…"
    swift build -c release --triple "x86_64-apple-macosx${DEPLOY_TARGET}" --scratch-path .build-x86_64

    echo "==> Merging into a universal binary…"
    BIN="$(mktemp -d)/MemoryCardTest"
    lipo -create -output "$BIN" \
        .build-arm64/release/MemoryCardTest \
        .build-x86_64/release/MemoryCardTest
fi

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
echo "    Architectures: $(lipo -archs "$APP/Contents/MacOS/MemoryCardTest")"
echo "    Launch with:  open \"$APP\""
