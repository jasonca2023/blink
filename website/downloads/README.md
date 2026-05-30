# downloads/

The Blink disk image lives here as `Blink.dmg`. It is **not committed** — the
app binary stays on your machine. The website links to it locally.

To create it:

1. Build Blink in Xcode (open `../Blink.xcodeproj`, set your signing team, Cmd+R).
2. From the `website/` folder run `./build-dmg.sh` (it finds the built `.app` in
   DerivedData, or pass the path explicitly).

The script writes `Blink.dmg` here. The site's download button goes live as soon
as the file exists.
