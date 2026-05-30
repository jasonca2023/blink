#!/usr/bin/env bash
#
# publish.sh — make the public download current AND push the update to installed
# apps, in one step. Run it after an Xcode build (watch-and-publish.sh does this
# automatically). It does NOT build the app.
#
#   1. package the built Blink.app into downloads/Blink.dmg
#        - default: quick unsigned image (build-dmg.sh)
#        - SIGN=1:  Developer ID signed + notarized + stapled (release-dmg.sh)
#   2. (re)generate downloads/appcast.xml, EdDSA-signed with your Sparkle key,
#      so every installed Blink offers/auto-installs this version
#   3. deploy website/ to Vercel so both the dmg and the appcast go live
#
# Usage:
#   ./publish.sh [/path/to/Blink.app]      # defaults to newest build in DerivedData
#
# Env knobs:
#   SIGN=1         sign + notarize the dmg (needs Developer ID + notary creds)
#   NO_DEPLOY=1    build the dmg + appcast but don't deploy (dry run)
#   SITE_BASE=...  public origin (default: https://website-jason-guo.vercel.app)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$HERE/downloads"
SITE_BASE="${SITE_BASE:-https://website-jason-guo.vercel.app}"
APP_PATH="${1:-}"

say() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. package the dmg ─────────────────────────────────────────────────────
if [[ "${SIGN:-0}" == "1" ]]; then
  say "Packaging signed + notarized dmg…"
  DEPLOY=0 "$HERE/release-dmg.sh" ${APP_PATH:+"$APP_PATH"}
else
  say "Packaging dmg (unsigned — set SIGN=1 for Developer ID + notarization)…"
  "$HERE/build-dmg.sh" ${APP_PATH:+"$APP_PATH"}
fi
[[ -f "$OUT_DIR/Blink.dmg" ]] || die "expected $OUT_DIR/Blink.dmg — packaging failed."

# ── 2. EdDSA-signed appcast for Sparkle auto-update ────────────────────────
GA="$(find "$HOME/Library/Developer/Xcode/DerivedData"/Blink-* -path '*sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
[[ -x "${GA:-}" ]] || GA="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
[[ -x "$GA" ]] || die "generate_appcast not found. Build Blink once in Xcode so SPM fetches Sparkle's tools."

say "Signing appcast with your Sparkle key (first run shows a one-time keychain prompt)…"
"$GA" --download-url-prefix "$SITE_BASE/downloads/" "$OUT_DIR"
[[ -f "$OUT_DIR/appcast.xml" ]] || die "generate_appcast did not produce appcast.xml."

# version sanity — Sparkle only offers builds with a HIGHER CFBundleVersion
VER="$(grep -o 'sparkle:version="[0-9][0-9]*"' "$OUT_DIR/appcast.xml" | head -1 | grep -o '[0-9][0-9]*' || echo '?')"
LAST_FILE="$OUT_DIR/.last-version"
LAST="$(cat "$LAST_FILE" 2>/dev/null || echo '')"
if [[ -n "$LAST" && "$VER" == "$LAST" ]]; then
  warn "CFBundleVersion is still $VER — Sparkle won't treat this as an update."
  warn "Bump CURRENT_PROJECT_VERSION in Xcode before the next release."
fi
echo "$VER" >"$LAST_FILE"
say "Appcast points installed apps at build $VER → $SITE_BASE/downloads/Blink.dmg"

# ── 3. deploy ──────────────────────────────────────────────────────────────
if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  warn "NO_DEPLOY=1 — not deploying. To go live:  vercel --cwd $HERE --prod"
else
  say "Deploying to Vercel…"
  vercel --cwd "$HERE" --prod --yes
  say "Live. Installed apps will pick up build $VER on their next check."
fi
