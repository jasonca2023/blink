# Blink website

A static landing page for Blink with a download button for the macOS app.

The **site is public** — drop this folder on any static host (GitHub Pages,
Netlify, Vercel, Cloudflare Pages, or even `python3 -m http.server`). The
**app binary stays local**: the DMG is served from `downloads/Blink.dmg`, which
is git-ignored and never uploaded unless you choose to.

```
website/
├── index.html        landing page
├── styles.css        dark glass theme
├── main.js           nav, reveal animations, DMG availability check
├── assets/           app icon + demo gif
├── downloads/        Blink.dmg goes here (local, git-ignored)
├── build-dmg.sh      package a built Blink.app into downloads/Blink.dmg
└── serve.sh          preview over HTTP
```

## Preview

```sh
cd website
./serve.sh            # → http://localhost:8080
```

Serve over HTTP (not `file://`) so the download and the availability check work.

## Publishing the DMG

1. Build Blink in Xcode (`../Blink.xcodeproj`, set signing team, Cmd+R).
2. `./build-dmg.sh` — packages the built `.app` into `downloads/Blink.dmg`
   with a drag-to-Applications layout. (`brew install create-dmg` for a prettier
   image; otherwise it falls back to `hdiutil`.)

The download button activates automatically once `downloads/Blink.dmg` exists.
If it's missing, the site shows build instructions instead of a broken link.
