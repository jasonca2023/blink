#!/usr/bin/env bash
#
# release-dmg.sh — turn a built Blink.app into a SIGNED, NOTARIZED, STAPLED
# Blink.dmg that opens on anyone's Mac with no Gatekeeper friction.
#
# Four steps in one shot:
#   1. (re)sign the app with your Developer ID + hardened runtime   [if needed]
#   2. package it into a drag-to-Applications disk image
#   3. notarize the disk image with Apple
#   4. staple the ticket so it verifies offline, for everyone
#
# It does NOT build the app. xcodebuild is intentionally off-limits in this
# repo — build a UNIVERSAL Release archive in Xcode first (see RELEASE.md),
# then point this script at the exported Blink.app.
#
# ───────────────────────────── one-time setup ─────────────────────────────
#   • A "Developer ID Application: <name> (SJ559LLF89)" certificate in your
#     login keychain  (Xcode > Settings > Accounts > Manage Certificates > +).
#   • A stored notary credential profile (uses an app-specific password):
#       xcrun notarytool store-credentials blink-notary \
#         --apple-id "you@apple.id" --team-id SJ559LLF89 \
#         --password "abcd-efgh-ijkl-mnop"   # appleid.apple.com > App-Specific Password
#
# ─────────────────────────────── usage ────────────────────────────────────
#   ./release-dmg.sh /path/to/Blink.app
#
# Env knobs (all optional):
#   NOTARY_PROFILE   notary keychain profile name        (default: blink-notary)
#   SIGN_IDENTITY    Developer ID Application identity    (default: auto-detect)
#   FORCE_SIGN=1     re-sign even if already Developer ID signed
#   SKIP_SIGN=1      never sign (app must already be Developer ID signed)
#   SKIP_NOTARIZE=1  build + place the dmg but skip notarize/staple (dry run)
#   DEPLOY=1         on success, run `vercel --prod` from website/
#
# Alternative notary auth (instead of the keychain profile): set all three of
#   NOTARY_APPLE_ID, NOTARY_PASSWORD, NOTARY_TEAM_ID
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT_DIR="$HERE/downloads"
DMG_PATH="$OUT_DIR/Blink.dmg"
VOL_NAME="Blink"
BG_IMAGE="$REPO/dmg-background.png"
NOTARY_PROFILE="${NOTARY_PROFILE:-blink-notary}"

say() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

APP_PATH="${1:-}"
[[ -n "$APP_PATH" ]] || die "usage: ./release-dmg.sh /path/to/Blink.app"
[[ -d "$APP_PATH" ]] || die "not a bundle: $APP_PATH"
command -v xcrun >/dev/null || die "xcrun not found — install the Xcode command line tools."
xcrun notarytool --help >/dev/null 2>&1 || die "notarytool unavailable — needs Xcode 13 or newer."

# ── 0. sanity: architectures ───────────────────────────────────────────────
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXE_NAME" 2>/dev/null || echo unknown)"
say "App:           $APP_PATH"
say "Architectures: $ARCHS"
case "$ARCHS" in
  *arm64*x86_64* | *x86_64*arm64*) : ;; # universal — ideal
  *) warn "Not a universal binary ($ARCHS). It still runs, but Apple Silicon" \
          $'\n   users get Rosetta. Build for "Any Mac" in Xcode for native arm64.' ;;
esac

# ── 1. sign ────────────────────────────────────────────────────────────────
already_devid() { codesign -dvv "$APP_PATH" 2>&1 | grep -q 'Authority=Developer ID Application'; }

if [[ "${SKIP_SIGN:-0}" == "1" ]]; then
  say "SKIP_SIGN=1 — using the app's existing signature."
  already_devid || die "app is not Developer ID signed; cannot notarize. Unset SKIP_SIGN."
elif already_devid && [[ "${FORCE_SIGN:-0}" != "1" ]]; then
  say "Already Developer ID signed — skipping re-sign (set FORCE_SIGN=1 to override)."
else
  : "${SIGN_IDENTITY:=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
  [[ -n "${SIGN_IDENTITY:-}" ]] || die "no 'Developer ID Application' identity found. Create one in Xcode, or set SIGN_IDENTITY / SKIP_SIGN."
  say "Signing with: $SIGN_IDENTITY"

  ENT_PLIST="$(mktemp -t blink-ent).plist"
  if codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null >"$ENT_PLIST" && grep -q '<' "$ENT_PLIST"; then
    # get-task-allow is a debug entitlement that notarization rejects — drop it.
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ENT_PLIST" 2>/dev/null || true
    say "Reusing entitlements from the existing signature (minus get-task-allow)."
  else
    ENT_PLIST=""
  fi

  sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }

  say "Signing nested code inside-out…"
  # dynamic libraries
  while IFS= read -r -d '' f; do sign "$f"; done \
    < <(find "$APP_PATH/Contents" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
  # loose Mach-O helpers (e.g. Sparkle's Autoupdate) before their frameworks seal
  while IFS= read -r -d '' f; do
    file -b "$f" 2>/dev/null | grep -q 'Mach-O' && sign "$f" || true
  done < <(find "$APP_PATH/Contents/Frameworks" -type f -perm -100 -print0 2>/dev/null)
  # nested bundles, deepest first (post-order so children sign before parents)
  while IFS= read -r -d '' b; do sign "$b"; done \
    < <(find "$APP_PATH/Contents" -depth -type d \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' -o -name '*.bundle' \) -print0)
  # the app itself, last, with its entitlements
  if [[ -n "$ENT_PLIST" ]]; then sign --entitlements "$ENT_PLIST" "$APP_PATH"; else sign "$APP_PATH"; fi

  say "Verifying signature…"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH" || die "signature verification failed."
fi

# ── 2. package dmg ─────────────────────────────────────────────────────────
say "Packaging disk image…"
mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_PATH" "$STAGE/Blink.app"
ln -s /Applications "$STAGE/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  ARGS=(--volname "$VOL_NAME" --window-pos 200 120 --window-size 640 400
    --icon-size 120 --icon "Blink.app" 160 200 --app-drop-link 480 200 --no-internet-enable)
  [[ -f "$BG_IMAGE" ]] && ARGS+=(--background "$BG_IMAGE")
  create-dmg "${ARGS[@]}" "$DMG_PATH" "$STAGE/Blink.app" \
    || hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
else
  hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
fi

# ── 3. notarize + staple ───────────────────────────────────────────────────
if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  warn "SKIP_NOTARIZE=1 — the dmg is NOT notarized; other Macs will warn."
else
  if [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
    AUTH=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
    say "Notarizing with Apple ID credentials…"
  else
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
    say "Notarizing with keychain profile '$NOTARY_PROFILE'…"
  fi
  say "Submitting to Apple — this usually takes 1–5 minutes…"
  xcrun notarytool submit "$DMG_PATH" "${AUTH[@]}" --wait \
    || die "notarization failed. See the log: xcrun notarytool log <submission-id> ${AUTH[*]}"
  say "Stapling ticket…"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl -a -t open --context context:primary-signing -vv "$DMG_PATH" 2>&1 | sed 's/^/   /' || true
fi

SIZE="$(du -h "$DMG_PATH" | cut -f1)"
echo
say "Done → $DMG_PATH ($SIZE)"
if [[ "${DEPLOY:-0}" == "1" ]]; then
  say "Deploying to Vercel…"
  vercel --cwd "$HERE" --prod --yes
else
  printf '\nPublish it:\n  vercel --cwd %q --prod\n' "$HERE"
fi
