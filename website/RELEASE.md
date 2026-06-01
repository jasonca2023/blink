# Shipping a Blink.dmg anyone can run

The DMG currently on the site is a real, fully functional, **universal** Blink —
it runs natively on Apple Silicon and Intel. But it's **ad-hoc signed** (not
notarized), so other people's Macs show a Gatekeeper warning on first launch;
they clear it once with `xattr -dr com.apple.quarantine /Applications/Blink.app`
(documented on the download page). To publish a download that opens cleanly on
*any* Mac with **no warning at all**, you need a **Developer-ID-signed, notarized**
build. This repo can do everything except the Xcode Archive itself.

There are two scripts in this folder:

| Script | Use it for | Result |
| --- | --- | --- |
| `build-dmg.sh` | quick local testing | unsigned/dev DMG, friction on other Macs |
| `release-dmg.sh` | **public distribution** | signed + notarized + stapled DMG, runs for everyone |

---

## One-time setup

1. **Developer ID certificate.** In Xcode → Settings → Accounts → your Apple ID →
   *Manage Certificates* → **＋** → **Developer ID Application**. Confirm it's there:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

   (You currently sign with an *Apple Development* cert — that one can't notarize.)

2. **Notary credentials.** Create an app-specific password at
   [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
   App-Specific Passwords, then store it once:

   ```sh
   xcrun notarytool store-credentials blink-notary \
     --apple-id "you@apple.id" --team-id SJ559LLF89 \
     --password "abcd-efgh-ijkl-mnop"
   ```

   > Never commit the password or the credentials. The keychain profile keeps it
   > out of the repo.

---

## Each release

1. **Build a universal Release via Archive** (xcodebuild is off-limits here, so do
   this in the IDE):
   - **Product → Archive.** This is mandatory for a universal binary — a normal
     ⌘B / Run build is single-arch, because Xcode forces "build active architecture
     only" for the run destination regardless of project settings. Archive (a
     distribution build) ignores that and builds arm64 + x86_64.
   - In the Organizer: **Distribute App → Developer ID → Export** (let Xcode sign
     with Developer ID). Save the exported `Blink.app`.

   This build is what carries your latest code — including the single-instance
   guard. The DMG on the site won't have it until you rebuild here.

2. **Sign, package, notarize, staple** in one command:

   ```sh
   ./release-dmg.sh /path/to/exported/Blink.app
   ```

   - If Xcode already signed it Developer ID, the script reuses that and just
     packages + notarizes + staples.
   - If not, it re-signs inside-out with hardened runtime first (set
     `SIGN_IDENTITY` to pick a cert; otherwise it auto-detects).
   - Output lands at `downloads/Blink.dmg`.

3. **Publish:**

   ```sh
   vercel --cwd "$(pwd)" --prod
   ```

   …or run the script with `DEPLOY=1 ./release-dmg.sh …` to do it in the same step.

---

## Notes

- The DMG is git-ignored on purpose; it's served from Vercel, not the repo.
  Vercel's CLI uploads it from your local `downloads/` folder, so re-run the
  deploy after each `release-dmg.sh`.
- Verify a finished DMG yourself:

  ```sh
  xcrun stapler validate downloads/Blink.dmg
  spctl -a -t open --context context:primary-signing -vv downloads/Blink.dmg
  ```

- Dry run without contacting Apple: `SKIP_NOTARIZE=1 ./release-dmg.sh Blink.app`.
- If notarization is rejected, read why with the submission id it prints:
  `xcrun notarytool log <id> --keychain-profile blink-notary`.
