# Blink Agent Instructions

## Non-Negotiable Rules

1. Check model validity before making assumptions about current model releases or identifiers.
2. Never use emoji unless the user explicitly asks for them.
3. Do not run `xcodebuild` from the terminal. Use Xcode for app builds and permission testing.

## Overview

Blink is a macOS menu-bar companion app by Blink. It uses SwiftUI with AppKit bridging for a custom floating panel, cursor overlay, Agent Mode dashboard, and macOS permission flows.

The product identity is Blink:

- Bundle identifier: `com.blink.blink`
- Display name: `Blink`
- Copyright: Blink

## Architecture

- App type: menu-bar app using `LSUIElement=true`
- Frameworks: SwiftUI, AppKit, AVFoundation, ScreenCaptureKit
- Pattern: `@MainActor` state orchestration with observable SwiftUI views
- Voice input: push-to-talk via a global CGEvent tap and pluggable transcription providers
- Voice response: Claude through Anthropic API-key configuration
- Text-to-speech: ElevenLabs through local key configuration
- Screen context: ScreenCaptureKit screenshots when the user invokes help
- Agent Mode: bundled Codex runtime and Blink resource pack in `AppResources/Blink`

## Key Files

- `Blink/BlinkApp.swift`: app entry point and delegate hookup.
- `Blink/CompanionManager.swift`: central app state machine for voice, screen capture, Claude, TTS, overlay, settings, and Agent Mode.
- `Blink/MenuBarPanelManager.swift`: menu-bar item and floating panel lifecycle.
- `Blink/CompanionPanelView.swift`: main Blink panel and settings subscreen.
- `Blink/OverlayWindow.swift`: cursor overlay, agent dock icons, captions, and response cards.
- `Blink/CodexHUDWindowManager.swift`: Agent Mode dashboard window.
- `Blink/CodexHomeManager.swift`: prepares the local Codex home using Blink bundled resources.
- `Blink/BlinkCodexConfigTemplate.swift`: renders Codex configuration for Blink Agent Mode.
- `Blink/BlinkNextStageParityModels.swift`: knowledge index, permission guide, response-card, and handoff support models.
- `AppResources/Blink/`: bundled Agent Mode instructions, skills, wiki seed, runtime, and completion sound.

## Configuration

Blink should use local keys and user configuration. Do not add Google login or hosted key sync:

- `ANTHROPIC_API_KEY` for Claude responses
- `ELEVENLABS_API_KEY` for ElevenLabs TTS
- `OPENAI_API_KEY` for Codex/Agent Mode where needed

Do not introduce a hard dependency on a Cloudflare Worker for the final app.

## Development Rules

- Prefer existing design-system tokens and local view patterns.
- Keep UI state updates on the main actor.
- Use async/await for asynchronous work.
- Use AppKit only where SwiftUI cannot provide the needed macOS behavior.
- Keep changes scoped to the requested behavior.
- Preserve user or generated changes in the worktree unless explicitly told to revert them.
- User-facing copy should use the Blink product name.

## Verification

Use lightweight checks that do not disturb macOS permissions:

```sh
swiftc -parse <relevant Swift source files>
```

Do not launch unsigned or throwaway builds for TCC permission testing.
