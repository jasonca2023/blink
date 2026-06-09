#!/usr/bin/env bash
#
# publish.sh — make the public download current AND push the update to installed
# apps, in one step. Run it after an Xcode build (watch-and-publish.sh does this
# automatically). It does NOT build the app.
#
#   1. auto-assign the next build number — one higher than the last published —
#      and stamp it onto a copy of the built app. You NEVER bump
#      CURRENT_PROJECT_VERSION in Xcode by hand anymore.
#   2. package that copy into downloads/Blink.dmg
#        - default: quick unsigned image (build-dmg.sh)
#        - SIGN=1:  Developer ID signed + notarized + stapled (release-dmg.sh)
#   3. (re)generate downloads/appcast.xml, EdDSA-signed with your Sparkle key,
#      so every installed Blink offers/auto-installs this version
#   4. deploy website/ to Vercel so both the dmg and the appcast go live
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
REPO="$(cd "$HERE/.." && pwd)"
OUT_DIR="$HERE/downloads"
SITE_BASE="${SITE_BASE:-https://website-jason-guo.vercel.app}"
APP_PATH="${1:-}"

say() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. pick the right build + assign the next version ──────────────────────
# Sparkle only offers a build whose EdDSA signature it can verify, so we must
# publish an app whose SUPublicEDKey matches the source (= the keychain signing
# key). DerivedData mtimes are unreliable here and a stale build can carry an
# orphaned key, so select by key-match + highest CFBundleVersion, NOT by mtime.
EXPECT_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$REPO/Blink/Info.plist" 2>/dev/null || true)"
key_of() { /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$1/Contents/Info.plist" 2>/dev/null || true; }
ver_of() { local v; v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$1/Contents/Info.plist" 2>/dev/null || true)"; [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'; }

pick_signable_app() {
  local best="" bestv=-1 app v
  while IFS= read -r app; do
    [[ -d "$app" ]] || continue
    [[ -n "$EXPECT_KEY" && "$(key_of "$app")" == "$EXPECT_KEY" ]] || continue
    v="$(ver_of "$app")"
    if (( v > bestv )); then bestv="$v"; best="$app"; fi
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/*/Blink.app' -type d 2>/dev/null)
  printf '%s' "$best"
}

# Honor an explicit path only if it carries the current key; otherwise auto-pick.
if [[ -n "$APP_PATH" && -n "$EXPECT_KEY" && "$(key_of "$APP_PATH")" != "$EXPECT_KEY" ]]; then
  warn "the build passed in carries an old Sparkle key — installed apps would reject it."
  warn "Auto-selecting the newest build with the current key instead."
  APP_PATH=""
fi
SRC_APP="${APP_PATH:-$(pick_signable_app)}"
[[ -n "$SRC_APP" && -d "$SRC_APP" ]] \
  || die "no built Blink.app with the current Sparkle key ($EXPECT_KEY) in DerivedData — build from the current source in Xcode first."

# Universal-binary guard — a thin (single-arch) build excludes half of all Macs:
# an Intel-only app needs Rosetta on Apple Silicon, an arm64-only one won't launch
# on Intel at all. IMPORTANT: a normal Xcode ⌘B/Run build is single-arch — Xcode
# injects ONLY_ACTIVE_ARCH=YES for the active run destination, overriding the
# project setting, so it only builds the host arch. Only Product → Archive (a
# distribution build) produces a universal binary. Pass that archived app to this
# script (see message below). Refuse to ship a thin binary unless overridden.
SRC_EXEC="$SRC_APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SRC_APP/Contents/Info.plist" 2>/dev/null || echo Blink)"
SRC_ARCHS="$(lipo -archs "$SRC_EXEC" 2>/dev/null || true)"
if [[ "${ALLOW_SINGLE_ARCH:-0}" != "1" ]] && ! [[ "$SRC_ARCHS" == *arm64* && "$SRC_ARCHS" == *x86_64* ]]; then
  die "built app is NOT universal (archs: ${SRC_ARCHS:-unknown}) — it would force Rosetta or fail to launch on half of all Macs. A normal ⌘B build is single-arch here; in Xcode use Product → Archive, then re-run pointing at the archived app:
       ./publish.sh \"\$(ls -dt \$HOME/Library/Developer/Xcode/Archives/*/*.xcarchive | head -1)/Products/Applications/Blink.app\"
     To ship a thin build anyway: ALLOW_SINGLE_ARCH=1 ./publish.sh"
fi
say "Build is universal (archs: $SRC_ARCHS)."

# Next build number = one higher than anything we've already published. We never
# regress: take the max of .last-version, the live appcast, and the built app's
# own CFBundleVersion, then add one. This is the bump that used to be manual.
floor=0
floor_with() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 10#${1} > floor )) && floor="$((10#${1}))"; return 0; }
floor_with "$(cat "$OUT_DIR/.last-version" 2>/dev/null || true)"
floor_with "$(grep -oE '<sparkle:version>[0-9]+' "$OUT_DIR/appcast.xml" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
floor_with "$(ver_of "$SRC_APP")"
NEXT=$((floor + 1))
say "Auto-assigning build $NEXT (last published: $floor) — no manual version bump needed."

# Stamp the new number onto a COPY (touching the DerivedData original would
# retrigger the watcher). Editing Info.plist breaks the signature, so re-seal it
# — otherwise Gatekeeper reports the downloaded dmg as "damaged".
STAMP_DIR="$(mktemp -d)"
trap 'rm -rf "$STAMP_DIR"' EXIT
cp -R "$SRC_APP" "$STAMP_DIR/Blink.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT" "$STAMP_DIR/Blink.app/Contents/Info.plist" \
  || die "failed to stamp build $NEXT onto the app copy."
if [[ "${SIGN:-0}" != "1" ]]; then
  # Re-seal with the stable Apple Development cert, NOT ad-hoc. An ad-hoc
  # signature's identity is a per-build hash, so macOS TCC treats every
  # update as a new app and wipes Accessibility / Screen Recording / Mic /
  # Full Disk Access grants. A certificate-anchored signature keeps the
  # same identity across builds, so users grant permissions once and every
  # later update inherits them. Pin by SHA-1 because the keychain also
  # holds a revoked copy of the same-named cert.
  RESEAL_IDENTITY="${RESEAL_IDENTITY:-B2013FCF5572628D956F05916938E0351C9EBB3A}"
  if codesign --force --deep --timestamp --preserve-metadata=entitlements \
       --sign "$RESEAL_IDENTITY" "$STAMP_DIR/Blink.app" >/dev/null 2>&1; then
    say "Re-sealed with Apple Development cert — TCC permissions persist across updates."
  else
    warn "cert re-seal failed — falling back to ad-hoc (permissions will reset on update)."
    codesign --force --deep --sign - "$STAMP_DIR/Blink.app" >/dev/null 2>&1 \
      || warn "ad-hoc re-seal failed — the unsigned dmg may read as damaged on other Macs."
  fi
fi
APP_PATH="$STAMP_DIR/Blink.app"

# ── 2. package the dmg ─────────────────────────────────────────────────────
if [[ "${SIGN:-0}" == "1" ]]; then
  say "Packaging signed + notarized dmg…"
  # FORCE_SIGN: the stamp invalidated the signature, so re-sign with Developer ID.
  DEPLOY=0 FORCE_SIGN=1 "$HERE/release-dmg.sh" "$APP_PATH"
else
  say "Packaging dmg (unsigned — set SIGN=1 for Developer ID + notarization)…"
  "$HERE/build-dmg.sh" "$APP_PATH"
fi
[[ -f "$OUT_DIR/Blink.dmg" ]] || die "expected $OUT_DIR/Blink.dmg — packaging failed."

# ── 3. EdDSA-signed appcast for Sparkle auto-update ────────────────────────
GA="$(find "$HOME/Library/Developer/Xcode/DerivedData"/Blink-* -path '*sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
[[ -x "${GA:-}" ]] || GA="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
[[ -x "$GA" ]] || die "generate_appcast not found. Build Blink once in Xcode so SPM fetches Sparkle's tools."

say "Signing appcast with your Sparkle key (first run shows a one-time keychain prompt)…"
# We ship a single rolling Blink.dmg (always the latest), so the feed should hold
# exactly one entry. Regenerate clean — otherwise generate_appcast preserves older
# items that still point at the reused dmg URL, which now serves a different build.
rm -f "$OUT_DIR/appcast.xml"
"$GA" --download-url-prefix "$SITE_BASE/downloads/" "$OUT_DIR"
[[ -f "$OUT_DIR/appcast.xml" ]] || die "generate_appcast did not produce appcast.xml."

# the update is worthless to installed apps unless it carries an EdDSA signature
if ! grep -q 'sparkle:edSignature' "$OUT_DIR/appcast.xml"; then
  warn "appcast.xml has NO EdDSA signature — installed apps will REJECT this update."
  warn "Cause: the keychain prompt was denied, or the built app's SUPublicEDKey does"
  warn "not match your Sparkle signing key (e.g. an old build). Approve the keychain"
  warn "dialog (Always Allow) and rebuild Blink with the current key, then re-run."
fi

# version sanity — the appcast should carry exactly the number we just minted.
VER="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$OUT_DIR/appcast.xml" | head -1 | grep -oE '[0-9]+' || echo '?')"
if [[ "$VER" != "$NEXT" ]]; then
  warn "appcast build is $VER but we stamped $NEXT — check generate_appcast / the dmg."
fi
echo "$VER" >"$OUT_DIR/.last-version"
say "Appcast points installed apps at build $VER → $SITE_BASE/downloads/Blink.dmg"

# ── 4. deploy ──────────────────────────────────────────────────────────────
if [[ "${NO_DEPLOY:-0}" == "1" ]]; then
  warn "NO_DEPLOY=1 — not deploying. To go live:  vercel --cwd $HERE --prod"
else
  say "Deploying to Vercel…"
  vercel --cwd "$HERE" --prod --yes
  say "Live. Installed apps will pick up build $VER on their next check."
fi
