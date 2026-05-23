# Contributing to Blink

Thanks for hacking on Blink. This file captures the conventions that have built up around the project — most of them exist because of a real past incident, so please read before opening a PR.

## Ground rules

1. **Do not run `xcodebuild` from the terminal.** It re-signs the bundle and trashes the TCC permissions you (or the previous tester) granted Blink for Accessibility, Screen Recording, and Microphone — which is the most tedious thing to recover. Build and run from Xcode.
2. **No emoji in source, UI strings, or commit messages** unless a maintainer explicitly asks for them. The product voice is plain.
3. **Verify model identifiers before swapping them.** Don't assume a model name from memory — confirm it's still served by the provider you're targeting (HuggingFace router, Anthropic, OpenAI) before merging. A stale model id silently breaks the agent loop without raising an error.
4. **Stay surgical.** Don't refactor, reformat, or "clean up" code adjacent to your change. Don't fix Swift 6 concurrency warnings or `onChange` deprecation warnings as drive-by edits — they get reviewed as their own change.
5. **Local-only stays local-only.** Don't add hosted-proxy dependencies, telemetry endpoints, Google login, or hard dependencies on a Cloudflare Worker. Keys live in `~/.config/blink/secrets.env`.
6. **Preserve the worktree.** Don't `git restore` or `git checkout --` files you didn't author unless the user explicitly tells you to discard them.

## Setup

See [README.md](README.md) for first-time setup. Once you have the project building:

- Grant Microphone, Accessibility, and Screen Recording on first run.
- Pick a transcription provider in **Settings → Voice**. Apple Speech needs no API key and is the safest default.
- The HF token lives in `~/.config/blink/secrets.env` (chmod 600). Never commit it.

## Branch & commit conventions

- Work on a topic branch. `main` is the integration branch.
- Stage files explicitly. Do **not** use `git add .` or `git add -A` — `~/.config/blink/secrets.env` and pbxproj signing changes (see below) can sneak in.
- Commit messages are sentence-case, present tense, focused on **why**:
  - `Agent: AX-driven UI control + smarter text-bar dispatch`
  - `Transcription: bump Voxtral fallback window for HF cold starts`
- Keep PRs scoped to a single concern. The text-mode bar fix and the agent's new tool went in together because they share a system prompt update — the Voxtral fallback bump would have been a separate commit.

### The `DEVELOPMENT_TEAM` pbxproj diff

Opening `Blink.xcodeproj` in Xcode rewrites `DEVELOPMENT_TEAM` in `project.pbxproj` to your personal Apple Developer team ID. **Do not commit that change.** It overwrites the maintainer's team id and forces the next person to fix it locally. Either:

- Revert the pbxproj diff with `git checkout -- Blink.xcodeproj/project.pbxproj` before staging, or
- Stage explicit files only (`git add Blink/SomeFile.swift`) and never `git add` the pbxproj when its only diff is the team id.

If you genuinely changed targets, build phases, or added files (Xcode 15+ synchronized groups discover new files automatically — most adds don't actually touch pbxproj), commit only the relevant hunks.

## Code conventions

- **SwiftUI first**, AppKit only where SwiftUI can't reach the macOS behavior (panels, cursor rects, NSEvent monitors, AX APIs).
- **`@MainActor` state orchestration.** UI state lives on the main actor; async work uses `async`/`await` and hops back to MainActor before mutating published state.
- **Design system tokens.** Use existing `BlinkAccentTheme`, color tokens, and view modifiers in `DesignSystem.swift`. Don't invent new colors inline.
- **No new files unless needed.** Existing files are large but well-organized. Prefer adding a section (with a `// MARK:` header) to a related file rather than spawning a new one for a small helper.
- **Comments.** Default to writing none. Add one only when *why* is non-obvious (a workaround, a hidden constraint, a subtle invariant). Don't describe what well-named code already says.
- **No dead code or scaffolding.** Don't ship `// TODO: future` blocks, feature-flag stubs, or backwards-compatibility shims for paths nobody is going to take. Delete what you're replacing.
- **Boundary validation only.** Trust internal callers and framework guarantees. Validate at the edge — user text, network responses, file imports.

## Working with the Accessibility-driven agent

The agent (`Blink/BlinkAgentLoop.swift`) drives other apps' UI through `AXUIElement` traversal. Two rules when adding tools:

1. **CFType casts need `CFGetTypeID` guards** before force-cast (`(value as! AXUIElement)`). A `as?` downcast to a CoreFoundation type is a SwiftUI/Swift compile error or always-succeeds warning, and bridged arrays of CF types need `Unmanaged.fromOpaque` rather than `as? [AXUIElement]`. See `BlinkAgentAccessibilityClicker` for the working pattern.
2. **Never invent click coordinates.** Tools that take pixel positions must source them from `inspect_ui`, a real screenshot, or AX `kAXPositionAttribute`. Prompting the model to guess pixels gets you clicks on empty space.

## Transcription providers

- All providers implement `BuddyTranscriptionProvider` and return a `BuddyStreamingTranscriptionSession`.
- For non-streaming providers (OpenAI Whisper, Voxtral), set `finalTranscriptFallbackDelaySeconds` longer than the worst-case round trip. HF cold starts for Voxtral can take 20-40 s — anything shorter risks `BuddyDictationManager`'s fallback cancelling the upload mid-flight and silently dropping the user's prompt.
- Don't add a hardcoded API key default. All keys come from `AppBundleConfiguration` (`~/.config/blink/secrets.env`).

## Verification

Use lightweight checks that don't disturb macOS permissions:

```sh
swiftc -parse <files you changed>
```

For UI-affecting changes, build in Xcode and exercise the feature manually:

- Push-to-talk: hold ctrl+option, speak, release. Check that the transcript reaches the agent.
- Text bar: double-tap ctrl, type, hit return. Check that the agent runs the prompt.
- Agentic clicking: ask Blink to "click <some labelled control>" in another app. Watch the transcript — it should call `click_button` first, fall back to `inspect_ui` on miss, then click.

Don't launch unsigned or throwaway builds for TCC permission testing.

## Reporting issues

File issues on GitHub with:

- macOS version
- Provider configuration (which transcription/agent backend you're using)
- Reproduction steps
- Relevant Console.app log lines (filter on `Blink`)

If the issue involves the agent doing the wrong thing, include the full transcript line where it picked the wrong tool — `BlinkAgentLoop` logs every tool call.
