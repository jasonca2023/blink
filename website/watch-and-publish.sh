#!/usr/bin/env bash
#
# watch-and-publish.sh — leave this running; every time you build Blink in Xcode
# it auto-packages the dmg, signs the Sparkle appcast, and deploys to Vercel. So
# "update Blink here" → the public download refreshes AND installed apps update.
#
# It does NOT build the app (xcodebuild is off-limits here). It watches Xcode's
# build output and reacts to a new Blink.app.
#
# Usage:
#   ./watch-and-publish.sh            # wait for the NEXT build, then publish
#   PUBLISH_NOW=1 ./watch-and-publish.sh   # also publish the current build now
#   SIGN=1 ./watch-and-publish.sh     # sign + notarize each release (slower)
#
# Pass-through env: SIGN, NO_DEPLOY, SITE_BASE (see publish.sh).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DD="$HOME/Library/Developer/Xcode/DerivedData"
POLL="${POLL:-5}"

say() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }

newest_app() {
  find "$DD"/Blink-* -path '*/Build/Products/*/Blink.app' -type d 2>/dev/null \
    | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}
build_sig() { stat -f '%m' "$1/Contents/MacOS/Blink" 2>/dev/null || echo 0; }

APP="$(newest_app)"
[[ -n "$APP" ]] || say "No Blink.app in DerivedData yet — build once in Xcode. Watching…"

if [[ "${PUBLISH_NOW:-0}" == "1" && -n "$APP" ]]; then
  say "Publishing current build: $APP"
  "$HERE/publish.sh" "$APP" || say "publish failed — will retry on the next build."
fi

last="$(build_sig "$APP")"
say "Watching for new Blink builds (polling ${POLL}s). Build in Xcode; Ctrl-C to stop."

while true; do
  sleep "$POLL"
  APP="$(newest_app)"
  [[ -n "$APP" ]] || continue
  sig="$(build_sig "$APP")"
  [[ "$sig" == "$last" || "$sig" == 0 ]] && continue

  # let the build settle: wait until the executable stops changing
  while :; do
    sleep 2
    sig2="$(build_sig "$APP")"
    [[ "$sig2" == "$sig" ]] && break
    sig="$sig2"
  done

  say "New build detected ($(date '+%H:%M:%S')): $APP"
  if "$HERE/publish.sh" "$APP"; then
    last="$(build_sig "$APP")"
  else
    say "publish failed — will retry on the next build."
    last="$sig2"
  fi
done
