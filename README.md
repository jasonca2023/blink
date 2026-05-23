# Blink

Blink is a native macOS menu-bar app that turns your cursor into a voice-driven assistant. Hold ctrl+option to push-to-talk: Blink captures your screen, understands what you're looking at, replies in voice, and flies a triangle cursor to whatever it's pointing at.

## Features

- **Voice push-to-talk.** Hold ctrl+option, ask anything, let go. Blink answers in one or two sentences and only speaks when asked.
- **Sees your screen.** ScreenCaptureKit screenshots feed the model on demand, so questions like "what is this" or "where do I click" work against the actual UI.
- **App-aware RAG.** Built-in knowledge for Onshape, Blender, Photoshop, Illustrator, and Figma — answers to "how do I extrude this" use the bundled knowledge base, not just generic web facts.
- **Agent Mode.** Send Blink longer jobs — research, refactors, file work, settings tweaks — and it runs them in the background through a bundled Codex runtime without taking the screen.
- **Feature tour slideshow.** Open the slideshow from the panel footer to walk through what Blink can do.
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

# Optional: open-source Codex backend via HuggingFace Inference Router.
# Set HUGGINGFACE_API_KEY here, then enable the HF backend with:
#   defaults write com.blink.blink blinkAgentBackend huggingface
# Default model is Qwen/Qwen2.5-Coder-32B-Instruct.
HUGGINGFACE_API_KEY=your_hf_token
```

Then open the Xcode project, set your signing team, and Cmd+R:

```sh
open Blink.xcodeproj
```

On first launch, grant Microphone, Accessibility, and Screen Recording when macOS prompts. Accessibility is what lets the global ctrl+option push-to-talk shortcut work outside Blink's own windows.

## Project layout

- `Blink/` — app sources (SwiftUI + AppKit bridging)
- `BlinkTests/`, `BlinkUITests/` — unit and UI tests
- `BlinkWidgets/` — WidgetKit extension
- `AppResources/Blink/` — bundled Codex runtime, skill packs, and wiki seed

## License

MIT.
