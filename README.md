# Blink

Blink is a native macOS menu-bar companion by Blink. It hosts Blink, an AI companion that provides push-to-talk voice help, screen-aware responses, image gallery views, local agent work, and a cursor overlay for pointing at UI elements.

Blink uses local configuration only. There is no Google login requirement and no hosted key-sync flow.

## Blink At A Glance

Blink currently handles:

- fresh web search for facts and news
- image gallery display for visual results
- screen-aware guidance using `[POINT:x,y:label]` and `[TYPE:x,y:label]`
- child workers and agent spawning for larger tasks
- GitHub integration through Composio MCP
- local shell and file work inside the configured projects root
- frontend builds and previews
- reports, PDFs, DOCX files, and spreadsheets
- repo scaffolding and day-to-day dev work
- native computer-use fallback when direct routes are not enough

## Routing

Blink prefers structured routes over visible UI whenever possible:

- use direct answers for simple questions
- use web search for fresh information
- use image gallery flows for visual content
- spawn child workers for substantial builds, research, artifact work, connected-app actions, or multi-step GUI tasks
- keep same-context work in `sessions_send` and start new work in `sessions_spawn`
- prefer integration routes such as GitHub via Composio MCP before falling back to browser or window automation
- use Blink's computer-use path only as the last-mile fallback for native Mac or browser actions

## Requirements

- macOS 14.2 or newer
- Xcode with the macOS SDK
- A signing team configured in Xcode for local runs
- Local API keys supplied outside the repository

## Repository Layout

- `Blink.xcodeproj` and `Blink/` contain the macOS app target.
- `BlinkTests/` contains focused app tests.
- `BlinkUITests/` contains UI test scaffolding.
- `AppResources/Blink/` contains bundled model instructions, skills, wiki seed, Codex runtime, and completion audio.
- `appcast.xml`, `blink-demo.gif`, and `dmg-background.png` support distribution and release packaging.
- `docs/APP_UPDATES.md` documents the Sparkle update feed and direct-distribution release flow.

The legacy `Blink` folder and scheme names are kept for project continuity. The product, bundle display name, and app identity are Blink.

## Secrets

Do not commit API keys to this repository.

Blink can read local secrets from:

- the in-app Settings fields
- launch environment variables
- a secrets file at `~/.config/blink/secrets.env`
- a custom file path set with `BLINK_SECRETS_FILE`

Supported values:

```sh
ANTHROPIC_API_KEY=your_anthropic_key
ELEVENLABS_API_KEY=your_elevenlabs_key
ELEVENLABS_VOICE_ID=your_elevenlabs_voice_id
OPENAI_API_KEY=your_openai_or_codex_key
```

Google Workspace access is intentionally handled through local tooling, not Blink-hosted Google login or key sync. See [Google Workspace via gogcli](#google-workspace-via-gogcli).

Recommended local setup:

```sh
mkdir -p ~/.config/blink
chmod 700 ~/.config/blink
$EDITOR ~/.config/blink/secrets.env
chmod 600 ~/.config/blink/secrets.env
```

The repo `.gitignore` excludes `.env` and `.env.local`, but the app no longer reads repo-local `.env` files. Keep secrets outside the project directory.

## Build And Run

Open the project in Xcode:

```sh
open Blink.xcodeproj
```

In Xcode:

1. Select the `Blink` scheme.
2. Select the Blink app target.
3. Set your signing team.
4. Run the app with `Cmd+R`.
5. Grant Accessibility, Microphone, and Screen Recording permissions when macOS asks.

Do not use terminal `xcodebuild` for permission testing. macOS TCC permissions are tied to the signed app identity and install path, and throwaway command-line builds can cause permission loops.

## Development Verification

For a lightweight syntax check that does not disturb macOS permissions, run `swiftc -parse` over the changed source files. Avoid launching unsigned or temporary build products for permission testing.

The external-control bridge can be checked with:

```sh
scripts/test-external-control-bridge.sh
```

The script performs Swift parse/typecheck checks, verifies the local bridge, exercises MCP descriptors, screenshot capture, captions, secondary cursors, SSE events, and confirms that primary cursor guidance uses Blink's native choreography without warping the real system pointer.

## External Control Bridge

Blink exposes a local-only control bridge for agents and other trusted local apps:

```text
http://127.0.0.1:32123
```

The bridge is intentionally non-invasive. It drives Blink's overlay, screenshots, and TTS, but does not start dictation, submit prompts, create new agent sessions, or mutate the normal Blink conversation state.

Useful endpoints:

- `GET /health` checks bridge status.
- `GET /mcp/tools` lists MCP-style tool descriptors.
- `POST /cursor` points with the primary Blink cursor, or creates one secondary marker with `mode: "secondary"`.
- `POST /cursors` shows multiple temporary secondary markers at once.
- `POST /caption` shows a short caption near a coordinate or the current cursor.
- `POST /screenshot` captures local screenshots with display-frame metadata for locating UI.
- `POST /speak` speaks through Blink's TTS without entering voice mode.
- `POST /clear` clears bridge-created overlay elements.
- `GET /events` streams server-sent bridge events.

Primary cursor behavior matters: default `/cursor` uses Blink's existing smooth pointing choreography, the same behavior used by voice prompts like "show me the Apple menu". The Blink triangle zips to the target, shows the caption, and returns to the real pointer. It should not warp the macOS pointer and should not draw a duplicate primary cursor.

Secondary cursors are explicit temporary markers. Use them for multi-point explanations, alternatives, or screen-tour overlays. They automatically disappear after `durationMs` or can be cleared with `/clear`.

Example primary pointer cue:

```sh
curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":640,"y":520,"caption":"Click this menu","durationMs":4500}'
```

Example simultaneous multi-marker cue:

```sh
curl -s -X POST http://127.0.0.1:32123/cursors \
  -H 'Content-Type: application/json' \
  -d '{"durationMs":4500,"cursors":[{"x":640,"y":520,"caption":"Editor","accentHex":"#60A5FA"},{"x":900,"y":520,"caption":"Logs","accentHex":"#F59E0B"}]}'
```

Example screenshot-to-pointer workflow:

```sh
curl -s -X POST http://127.0.0.1:32123/screenshot \
  -H 'Content-Type: application/json' \
  -d '{"focused":false}'

curl -s -X POST http://127.0.0.1:32123/cursor \
  -H 'Content-Type: application/json' \
  -d '{"x":1180,"y":760,"caption":"Use this button"}'
```

Bundled agent skills for this bridge live in `AppResources/Blink/BlinkBundledSkills/`:

- `google-workspace-gogcli`: local Google Workspace access through `gogcli` for Gmail, Calendar, Drive, Docs, Sheets, Slides, Chat, Contacts, Tasks, Admin, Groups, and related Google services.
- `blink-screen-control`: quick point, caption, screenshot, speak, and clear commands.
- `blink-screen-tour`: recordable visual tours with multiple simultaneous markers, area-focused overlays, speech, and primary cursor choreography.

## Google Workspace via gogcli

Blink can connect agents to Google Workspace through the local [`gogcli`](https://github.com/steipete/gogcli) command, installed as `gog`. This keeps Google authentication local to the user's machine and avoids adding hosted OAuth, Google login, or cloud key sync to Blink.

If gogcli uses the encrypted file keyring, Blink agents need the same keyring password non-interactively. Put it in `~/.config/blink/secrets.env` as `GOG_KEYRING_PASSWORD=...`, or migrate gogcli to the macOS Keychain backend. If Google's OAuth screen says "Blink", that branding comes from the local OAuth client stored in `~/Library/Application Support/gogcli/credentials.json`; replace it with an Blink-owned Desktop OAuth client to change the consent-screen app name.

Install on macOS:

```sh
brew install gogcli
```

Check status from Blink Settings → Google, or from the terminal:

```sh
scripts/check-gogcli-workspace.sh
```

Or manually:

```sh
gog --version
gog auth status --json
gog auth list
```

Initial setup requires a Google Cloud Desktop OAuth client JSON owned by the user or their Workspace organization. Store it in gogcli, not in this repository:

```sh
gog auth credentials ~/Downloads/client_secret_....json
```

Authorize with least-privilege scopes for the services needed:

```sh
# Read-only Gmail + Drive example
gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly

# Calendar + Tasks read-only example
gog auth add you@example.com --services calendar,tasks --readonly
```

For Workspace-specific clients/domains:

```sh
gog --client work auth credentials ~/Downloads/work-client.json --domain example.com
gog auth alias set work you@example.com
```

Common read commands:

```sh
gog gmail search 'newer_than:7d' --account work --json
gog calendar events --account work --json
gog drive search "name contains 'proposal'" --account work --json
gog contacts search 'Jane Doe' --account work --json
```

Write actions such as sending email, posting Chat messages, modifying Drive files, changing calendar events, contacts, groups, or admin state should only run after explicit user intent. The bundled `google-workspace-gogcli` skill documents safe usage patterns for agents.

## Swift SDK Embedding (Windowed)

For Swift hosts that want an in-window Blink instance that is separate from the OS-level menu-bar companion, use `BlinkSDKSession` from `Blink/BlinkSDK.swift`.

Example:

```swift
import SwiftUI

let sdk = BlinkSDKSession(mode: .embeddedWindow)

// In app startup
sdk.start()

// In SwiftUI
var body: some View {
    sdk.makePanelView(actions: .init(
        onPanelDismiss: { /* dismiss host panel */ },
        onQuit: { /* close host window if needed */ }
    ))
}

// Send input
sdk.submitTextPrompt("Summarize this page")
```

The host can either use SDK actions for Settings/HUD/Memory, or keep them no-op and route that experience separately.

See [Blink SDK Integration Guide](docs/BlinkSDKIntegration.md) for step-by-step host app integration instructions.

## Direct Updates

Blink uses Sparkle for direct-distribution OTA updates. Installed builds check the signed `appcast.xml` feed from this repository's `main` branch, then download and install signed release DMGs from GitHub Releases. See [docs/APP_UPDATES.md](docs/APP_UPDATES.md) for the release checklist and appcast item template.

## Credits And Upstream Work

Blink is maintained by [Blink](https://github.com/blink).

This project builds on the original open-source Blink work:

- Original project: [blink/blink](https://github.com/blink/blink)
- Original creator: Blink, GitHub [@blink](https://github.com/blink), X [@BlinkTV](https://x.com/blinktv)

Blink has also incorporated ideas and implementation patterns from these forks:

- [@danpeg](https://github.com/danpeg)'s [danpeg/blink](https://github.com/danpeg/blink), reviewed locally as `blink-teach`, for tutor-mode direction and idle observation behavior.
- [@milind-soni](https://github.com/milind-soni)'s [milind-soni/tiptour-macos](https://github.com/milind-soni/tiptour-macos), for developer-menu/debug tooling patterns and related teaching-assistant UX ideas.

## License

MIT. Copyright 2026 Blink. Portions are derived from or informed by the upstream MIT-licensed projects credited above.
