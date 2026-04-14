#!/usr/bin/env bash
# Build Glance as a sandboxed macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP="Glance.app"
HLJS_VERSION="11.9.0"
HLJS_BASE="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/${HLJS_VERSION}"

# ---------------------------------------------------------------------------
# 1. Fetch syntax-highlighting assets (cached on subsequent builds)
# ---------------------------------------------------------------------------
RES="Sources/glance/Resources"
mkdir -p "$RES"
fetch() {
    local url="$1" out="$2"
    if [ ! -s "$out" ]; then
        echo "→ fetching $(basename "$out")"
        curl -fsSL "$url" -o "$out"
    fi
}
fetch "$HLJS_BASE/highlight.min.js"               "$RES/highlight.min.js"
fetch "$HLJS_BASE/styles/atom-one-light.min.css"  "$RES/atom-one-light.min.css"
fetch "$HLJS_BASE/styles/atom-one-dark.min.css"   "$RES/atom-one-dark.min.css"

# ---------------------------------------------------------------------------
# 2. Render the app icon (regenerate when the script changes)
# ---------------------------------------------------------------------------
if [ ! -f AppIcon.icns ] || [ tools/make_icon.swift -nt AppIcon.icns ]; then
    echo "→ rendering AppIcon.icns"
    swift tools/make_icon.swift glance.iconset
    iconutil -c icns glance.iconset -o AppIcon.icns
    rm -rf glance.iconset
fi

# ---------------------------------------------------------------------------
# 3. Compile
# ---------------------------------------------------------------------------
echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/glance"

# ---------------------------------------------------------------------------
# 4. Assemble the .app bundle
# ---------------------------------------------------------------------------
echo "→ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN"                              "$APP/Contents/MacOS/glance"
cp Info.plist                          "$APP/Contents/Info.plist"
cp AppIcon.icns                        "$APP/Contents/Resources/AppIcon.icns"
cp "$RES/highlight.min.js"             "$APP/Contents/Resources/"
cp "$RES/atom-one-light.min.css"       "$APP/Contents/Resources/"
cp "$RES/atom-one-dark.min.css"        "$APP/Contents/Resources/"

# ---------------------------------------------------------------------------
# 5. Sign with sandbox entitlements
#    Ad-hoc signing (`-`) is fine for local use; for the App Store replace
#    with your Developer ID and add `--options runtime`.
# ---------------------------------------------------------------------------
echo "→ codesigning with sandbox entitlements"
codesign --force --deep --sign - \
    --entitlements glance.entitlements \
    "$APP" >/dev/null

# Verify
codesign --display --entitlements - --xml "$APP" >/dev/null 2>&1 \
    && echo "  ✓ entitlements embedded"

echo "✓ built ./$APP"
echo "  open ./$APP                 # launch"
echo "  open -a ./$APP file.md      # open a file"
