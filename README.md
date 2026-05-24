# Blink

Blink is a native macOS menu-bar app that turns your cursor into a buttcheek. Hold ctrl+option to eat jason or double-tap ctrl to eat wesley. Blink captures your screen, understands what you're looking at, replies in voice, and can drive the UI on your behalf — click buttons, open apps, run searches, fill in text — through the macOS Accessibility tree (no pixel guessing).

## Features

- **Voice push-to-talk.** Hold ctrl+option, ask anything, let go. Blink answers in one or two sentences and only speaks when asked.
- **Text mode.** Double-tap ctrl to summon a floating composer near the cursor. Slash commands (`/agent`, `/voice`, `/screen`, …) and `@` mentions are inline. The text bar uses the same brain router as voice, so "check the weather in tokyo" reaches `web_search` instead of dead-ending.
- **Agentic UI control.** Blink finds buttons, menu items, links, checkboxes, tabs in any focused app through the Accessibility tree and invokes them by label — "click Stop Sharing", "press Send", "start sharing screen". When a label miss happens, the agent calls `inspect_ui` to see what's actually on screen as structured data (role + label + coordinates), then clicks the right thing. No randomly-clicked pixels.
- **Composite actions.** `web_search`, `new_tab`, `open_app`, `click_button`, `inspect_ui`, `type_text`, `key_press`, `scroll`, `wait_for_app` cover most everyday tasks.
- **Sees your screen.** ScreenCaptureKit screenshots feed the model on demand, so questions like "what is this" or "where do I click" work against the actual UI.
- **App-aware RAG.** Built-in knowledge for Onshape, Blender, Photoshop, Illustrator, and Figma — answers to "how do I extrude this" use the bundled knowledge base, not just generic web facts.
- **Agent Mode.** Send Blink longer jobs — research, refactors, file work, settings tweaks — and it runs them in the background through a bundled Codex runtime without taking the screen.
- **Pluggable transcription.** Apple Speech (local), AssemblyAI, Deepgram, OpenAI Whisper, or Mistral Voxtral via the HuggingFace router. Picked from Settings → Voice.
- **Apple Liquid Glass throughout.** Every panel, overlay, and card uses translucent system materials. No dark gradients.
- **Local-only.** API keys live in `~/.config/blink/secrets.env`. Nothing ships through a hosted proxy. A local control bridge at `127.0.0.1:32123` lets other trusted local apps drive the overlay, screenshots, captions, and TTS.

## Requirements

- macOS 14.2 or newer
- Xcode 16 with the macOS SDK
- An Apple Developer team configured in Xcode for local signing

## Setup

```sh
mkdir -p ~/.config/blink
chmod 700 ~/.config/blink
$EDITOR ~/.config/blink/secrets.env
chmod 600 ~/.config/blink/secrets.env
```

Inside the file:

```sh
ANTHROPIC_API_KEY=your_anthropic_key
ELEVENLABS_API_KEY=your_elevenlabs_key
ELEVENLABS_VOICE_ID=your_elevenlabs_voice_id
OPENAI_API_KEY=your_openai_or_codex_key

# Optional: open-source Codex backend AND Voxtral transcription via the
# HuggingFace Inference Router. Set HUGGINGFACE_API_KEY here, then either:
#   - enable the HF agent backend:
#       defaults write com.blink.blink blinkAgentBackend huggingface
#     (default agent model is meta-llama/Llama-3.3-70B-Instruct)
#   - or pick Voxtral in Settings → Voice to use
#     mistralai/Voxtral-Small-24B-2507 for transcription.
HUGGINGFACE_API_KEY=your_hf_token
```

Then open the Xcode project, set your signing team, and Cmd+R:

```sh
open Blink.xcodeproj
```

On first launch, grant **Microphone**, **Accessibility**, and **Screen Recording** when macOS prompts. Accessibility is required for:

- the global ctrl+option push-to-talk shortcut to work outside Blink's own windows,
- the agent's `click_button` / `inspect_ui` tools to read and invoke other apps' UI controls,
- the cursor overlay to position itself over the focused window.

## Triggers

| Action | Shortcut |
| --- | --- |
| Push-to-talk | hold **ctrl + option** |
| Text bar | double-tap **ctrl** |
| Dismiss text bar | **esc** |
| Clear text bar draft | **x** button (right side of the bar) |
| Submit text bar | **return** or **↑** button |

## Project layout

- `Blink/` — app sources (SwiftUI + AppKit bridging)
  - `BlinkAgentLoop.swift` — direct tool-use agent loop, AX-based click helpers, intent router
  - `CompanionManager.swift` — central app state machine, text-mode bar, push-to-talk wiring
  - `Buddy*TranscriptionProvider.swift`, `VoxtralHFTranscriptionProvider.swift` — pluggable transcription providers
  - `BlinkComputerUseRuntime.swift` / `BlinkComputerUseModels.swift` — CGEvent mouse/keyboard primitives, window enumeration
- `BlinkTests/`, `BlinkUITests/` — unit and UI tests
- `BlinkWidgets/` — WidgetKit extension
- `AppResources/Blink/` — bundled Codex runtime, skill packs, and wiki seed

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT.
