#!/usr/bin/env bash
#
# build-dmg.sh — package an already-built Blink.app into website/downloads/Blink.dmg
#
# This does NOT build the app. Build Blink in Xcode first (Product > Archive, or
# just Cmd+R then grab the .app from DerivedData), then run this to wrap it in a
# drag-to-Applications disk image that the local website serves.
#
# Usage:
#   ./build-dmg.sh [/path/to/Blink.app]
#
# If no path is given, the script tries to locate the most recent Blink.app in
# the default Xcode DerivedData location.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT_DIR="$HERE/downloads"
DMG_PATH="$OUT_DIR/Blink.dmg"
VOL_NAME="Blink"
BG_IMAGE="$REPO/dmg-background.png"

APP_PATH="${1:-}"

if [[ -z "$APP_PATH" ]]; then
  echo "No app path given — searching DerivedData…"
  APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "Blink.app" -type d 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: could not find a built Blink.app." >&2
  echo "       Build Blink in Xcode, then pass the path, e.g.:" >&2
  echo "       ./build-dmg.sh ~/Library/Developer/Xcode/DerivedData/Blink-xxxx/Build/Products/Debug/Blink.app" >&2
  exit 1
fi

echo "Packaging: $APP_PATH"
mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"

# staging dir with the app + an Applications symlink for drag-install
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/Blink.app"
ln -s /Applications "$STAGE/Applications"

# Prefer create-dmg (nicer layout + background) if installed; fall back to hdiutil.
if command -v create-dmg >/dev/null 2>&1; then
  echo "Using create-dmg…"
  CREATE_DMG_ARGS=(
    --volname "$VOL_NAME"
    --window-pos 200 120
    --window-size 640 400
    --icon-size 120
    --icon "Blink.app" 160 200
    --app-drop-link 480 200
    --no-internet-enable
  )
  [[ -f "$BG_IMAGE" ]] && CREATE_DMG_ARGS+=(--background "$BG_IMAGE")
  create-dmg "${CREATE_DMG_ARGS[@]}" "$DMG_PATH" "$STAGE/Blink.app" || {
    echo "create-dmg returned nonzero; falling back to hdiutil." >&2
    hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
  }
else
  echo "create-dmg not found (brew install create-dmg for a prettier image)."
  echo "Using hdiutil…"
  hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
fi

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "Done → $DMG_PATH ($SIZE)"
echo "Preview the site with:  ./serve.sh"
