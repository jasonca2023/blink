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

- **Auto-update starts from your *next* build.** The keypair whose public key was
  previously in `Info.plist` had no matching private key on this machine, so I
  generated a fresh one. `Blink/Info.plist` now carries the new `SUPublicEDKey`
  (`sA7Pp6…`) and the real feed URL
  (`https://website-jason-guo.vercel.app/downloads/appcast.xml`). Any copy built
  *before* this change (e.g. the build 6 currently on the site) can't verify the
  new signatures — so distribute the first new build manually (the website
  download), and everything after it updates itself.
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
