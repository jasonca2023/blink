# Auto-update: never ship a stale Blink again

When you build Blink in Xcode, two things should refresh by themselves:

1. **The public download** (`downloads/Blink.dmg` on the site)
2. **Already-installed copies**, which pull the new version in-app via **Sparkle**

This is handled by `watch-and-publish.sh` → `publish.sh`. Neither builds the app
(xcodebuild is off-limits here); they react to your Xcode build.

```
┌──────────────┐   you build    ┌──────────────────────┐   detects new .app
│   Xcode      │ ─────────────▶ │ watch-and-publish.sh  │ ───────────┐
└──────────────┘                └──────────────────────┘            ▼
                                                          ┌────────────────────┐
   site download refreshes  ◀───  vercel deploy  ◀─────── │     publish.sh      │
   installed apps auto-update ◀── appcast.xml (signed) ◀─ │ dmg + appcast + ship│
                                                          └────────────────────┘
```

## Daily use

Leave the watcher running in a terminal:

```sh
cd website
./watch-and-publish.sh           # add SIGN=1 to notarize each release
```

Then just build in Xcode (Cmd+R, or Archive). On each new build the watcher
packages the dmg, regenerates the **EdDSA-signed `appcast.xml`**, and deploys.
Installed apps (which check daily) then download and self-install it.

> **The build number bumps itself.** Sparkle only offers a version whose
> `CFBundleVersion` is *higher* than what's installed — so `publish.sh` now
> mints the next number automatically (one higher than the last published: 7 →
> 8 → 9 …) and stamps it onto the build it ships. You never touch
> **CURRENT_PROJECT_VERSION** in Xcode again. The number it assigns is the max of
> `downloads/.last-version`, the live appcast, and the built app's own version,
> plus one, so it never repeats or regresses even across machines or dry runs.

## Two one-time facts

- **Auto-update continuity reset on 2026-06-15 at build 14.** The previous key
  (`sA7Pp6…`, used through the **build 13** that was live on the site) existed
  only in the keychain of the laptop it was generated on, and did not migrate
  when machines changed — it was unrecoverable from any available Mac or backup.
  So a fresh keypair was generated and `Blink/Info.plist` now carries the new
  `SUPublicEDKey` (`h3WpgK…`) with the real feed URL
  (`https://blink-jason-guo.vercel.app/downloads/appcast.xml`). **Build 14 is the
  first build signed with the new key.** Every existing install (anyone on build
  ≤13, all on the old key) can't verify the new signatures, so they must download
  build 14 manually once from the website; everything after that updates itself.
  **The new private key is backed up on paper — also store it in a password
  manager and keep a copy on every machine you publish from, so a single-keychain
  loss can't happen again.**
- **First signing shows a keychain prompt.** The Sparkle private key lives in
  your login keychain. The first time `publish.sh` signs an appcast, macOS asks
  to allow access — click **Always Allow**. Back it up once and keep it safe:

  ```sh
  # export (store offline; this IS the secret that authorizes updates)
  "$(find ~/Library/Developer/Xcode/DerivedData -path '*sparkle/Sparkle/bin/generate_keys' | head -1)" -x sparkle_private_key.txt
  ```

## Signed vs unsigned releases

- Default: the dmg is **unsigned** (fast). Sparkle still installs it because the
  appcast is EdDSA-signed — fine for your own testing.
- For public installs with no Gatekeeper friction, run the watcher with `SIGN=1`
  so each release is Developer ID signed + notarized (see `RELEASE.md` for the
  one-time cert/notary setup). Slower: notarization adds a few minutes per build.
