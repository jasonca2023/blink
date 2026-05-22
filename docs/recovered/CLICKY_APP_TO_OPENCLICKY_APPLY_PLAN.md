# Blink.app → Blink Apply Plan

Scope: map recovered Blink.app Swift/UI contracts into the live Blink repo at `/Users/blink/clawd/github/blink` without copying proprietary implementation.

Repo identity verified from `AGENTS.md` and `README.md`: Blink native macOS app, bundle id `com.blink.blink`, legacy `Blink` folder/scheme preserved.

Current git state at inspection: `main...origin/main [ahead 6]` with existing modified/untracked skill-resource files. This plan is a sidecar only; no source files are intentionally changed by it.

## Existing overlap

Blink already has these recovered Blink-lineage files or equivalents:

- `Blink/CompanionManager.swift`
- `Blink/CompanionPanelView.swift`
- `Blink/MenuBarPanelManager.swift`
- `Blink/OverlayWindow.swift`
- `Blink/CodexHUDWindowManager.swift`
- `Blink/CodexAgentSession.swift`
- `Blink/DesignSystem.swift`
- `Blink/BlinkNextStageParityModels.swift`
- `Blink/BlinkNextStageParityViews.swift`
- `Blink/BlinkSettingsWindowManager.swift`
- `Blink/BlinkComputerUseRuntime.swift`
- `Blink/BlinkExternalControlBridge.swift`
- `AppResources/Blink/BlinkBundledSkills/`

Recovered source markers found existing exactly: 16 / 65. Blink has 74 Swift files total.

## Highest-value code we can apply

### 1. Notch surfaces as Blink compact HUD views

Recovered Blink components:

- `NotchRootView`
- `NotchPanel`
- `NotchHomeTab`
- `NotchAgentsTab`
- `NotchSettingsTab`
- `NotchTextInputSurface`
- `NotchTextResponseSurface`
- `NotchActivitySurface`
- `NotchAgentSurface`

Blink target:

- Possible new clean-room file: `Blink/BlinkCompactHUDView.swift`
- Existing host/wiring candidates: `Blink/CodexHUDWindowManager.swift` and `Blink/MenuBarPanelManager.swift`
- Existing state: `CompanionManager`, `CodexAgentSession`, `DesignSystem`

Apply as Blink-native compact HUD, not a Blink-branded notch clone. Start with three tabs/views:

- Home: permission state, voice shortcut hint, active integrations, update pill, dock/cursor controls.
- Agents: running agent rows, activity timeline, notifications, thread history, artifact preview tiles.
- Settings: pill-card rows, provider/API settings entrypoints, permissions, crons, model/folder shortcuts.

Recovered helper contracts to preserve structurally:

- `NotchHomeTab`: `primaryHomeContent`, `meetBlinkBlock`, `permissionIntroBlock`, `permissionActiveCardBlock`, `voiceShortcutHintRow`, `activeIntegrationsSection`, `updateReadyPill`.
- `NotchAgentsTab`: `loadingState`, `runningRow`, `activityTimelineView`, `notificationRow`, `threadRow`, `artifactsBlock`, `artifactPreviewTile`, `statusChip`.
- `NotchSettingsTab`: `mainSettingsList`, `pillCard`, `planUsageMeter`, `agentPermissionsPage`, `integrationsPage`, `cronsPage`, `settingsRowBody`, `actionRow`, `toggleRow`.
- `NotchTextInputSurface`: `attachButton`, `attachmentChipsRow`, `inputColumn`, `sendButton`.
- `NotchTextResponseSurface`: `textStreamActorSlot`, `chromeControl`, `closeButton`, `dismissPill`, `actionPill`.

### 2. Improve existing ChatWorkspace composer using recovered NotchTextInputSurface

Blink target:

- `Blink/ChatWorkspaceView.swift`

Current state:

- Composer is real but thin: `plus` button is empty, no attachment chips, no text compose actor slot, no draft attachments.

Apply:

- Add real attachment model + file importer/drop support.
- Show attachment chips row.
- Wire plus button to import attachments.
- Pass attachment paths into `CompanionManager.submitAgentPromptFromUI` or add a sibling method if needed.
- Keep existing ChatGPT-style shape; do not introduce Blink branding.

### 3. Agent dashboard parity from NotchAgentsTab

Blink target:

- `Blink/CodexHUDWindowManager.swift`
- `Blink/ChatWorkspaceView.swift`
- `Blink/CodexAgentSession.swift`

Apply:

- Add a reusable `BlinkAgentActivityList`/`BlinkAgentThreadRow` component.
- Add structured sections for running tasks, notifications, and completed threads.
- Render artifact previews from existing `CodexAgentFileDiffItem`/openable file extraction.
- Add status chips and remove-from-history action.

This is one of the strongest direct ports because recovered helpers map cleanly to existing `CodexAgentSession` types.

### 4. Settings parity from NotchSettingsTab / CompanionPanelView

Blink target:

- `Blink/BlinkSettingsWindowManager.swift`
- `Blink/BlinkAgentsSettingsSection.swift`
- `Blink/BlinkAutomationsSettingsSection.swift`
- `Blink/CodexAgentModePanelSection.swift`

Apply:

- Convert repeated settings UI into reusable `settingsRowBody`, `actionRow`, `toggleRow`, `pillCard`, `planUsageMeter`-style helpers using `DS` tokens.
- Add missing compact subsections: Agent folder, Crons, Integration search/filter, Permissions status card, Build info footer.
- Preserve Blink local-key privacy model. Do not add Supabase login, hosted Google auth, Cloudflare worker dependency, telemetry, or paywall.

### 5. Permission inspector / permission coach

Recovered Blink files:

- `AgentPermissionsInspector.swift`
- `AgentPermissionsPage.swift`
- `PermissionFlowCoordinator.swift`
- `PermissionGuideAssistant.swift`

Blink existing:

- `BlinkNextStageParityModels.swift` has `PermissionGuideAssistant`, `PermissionSnapshot`, `PermissionStatus`.
- `BlinkNextStageParityViews.swift` has `BlinkPermissionGuideSection`.
- `BlinkSettingsWindowManager.swift` has Permissions section.

Apply:

- Create `BlinkAgentPermissionsPage.swift` or fold into settings.
- Add stale-cache and timeout states.
- Add per-permission rows for Accessibility, Screen Recording, Microphone, Speech Recognition.
- Add status badges and direct System Settings buttons.

### 6. Detached cursor / handoff overlays

Recovered Blink components:

- `CursorTextInputOverlay.swift`
- `HandoffIndicatorWindow.swift`
- `HandoffRegionSelectOverlay.swift`
- `HandoffVoiceStopWindow.swift`
- `TextInjectionDelivery.swift`

Blink existing:

- `OverlayWindow.swift`
- `BlinkExternalControlBridge.swift`
- `BlinkNextStageParityModels.swift`
- `BlinkNextStageParityViews.swift`

Apply:

- Add text-follow-up mini surface near cursor.
- Add region selection overlay for handoff screenshots.
- Add voice stop pill / handoff indicator chip.
- Use existing overlay manager and external bridge; keep no cursor warping.

### 7. Companion actor / activity micro-animations

Recovered Blink components:

- `CompanionActorRenderer`
- `CompanionActorState`
- `CompanionActorSurface`
- `NotchActivitySurface`
- `VoiceWaveformBars`
- `InlineVoiceRecordingWaveformView`

Blink existing:

- `BlinkBuddyPet.swift`
- `BlinkPetSpriteView.swift`
- `OverlayWindow.swift`
- `DesignSystem.swift`

Apply:

- Map listening/thinking/speaking/working states to existing pet/cursor overlay.
- Add compact waveform/equalizer bars to panel/HUD.
- Avoid copying assets; use original Blink pet/artwork or SF-symbol/vector animation.

## Skip / do not apply

- Supabase auth/key sync (`SupabaseAuthManager`) — conflicts with Blink local-key model.
- Billing/paywall (`BillingClient`, paywall HUD/cards) — not appropriate for privacy-first Blink unless explicitly requested later.
- PostHog/Sentry telemetry defaults — privacy posture says omit by default.
- Hosted Cloudflare worker dependency — README/AGENTS explicitly says do not hard-depend on it.
- Blink branding/copy/assets — re-express as Blink.
- Exact proprietary SwiftUI bodies — clean-room only.

## Recommended implementation bursts

### Burst 1: Composer + attachment chips

Files:

- `Blink/ChatWorkspaceView.swift`
- maybe `Blink/CodexAgentSession.swift`

Why first: smallest visible improvement; directly maps recovered `NotchTextInputSurface` helpers into existing real UI.

Verification:

```sh
swiftc -parse Blink/ChatWorkspaceView.swift
```

### Burst 2: Agent activity/thread row components

Files:

- `Blink/CodexHUDWindowManager.swift`
- optional new `Blink/BlinkAgentActivityViews.swift`

Why second: high parity value from `NotchAgentsTab` and existing session model.

Verification:

```sh
swiftc -parse Blink/BlinkAgentActivityViews.swift Blink/CodexHUDWindowManager.swift
```

### Burst 3: Permissions page polish

Files:

- `Blink/BlinkNextStageParityViews.swift`
- `Blink/BlinkSettingsWindowManager.swift`
- optional new `Blink/BlinkAgentPermissionsPage.swift`

Why third: high user trust value and low product-risk.

### Burst 4: Compact HUD / notch-inspired mini-window

Files:

- new `Blink/BlinkCompactHUDView.swift`
- `Blink/CodexHUDWindowManager.swift`
- `Blink/MenuBarPanelManager.swift`

Why fourth: bigger UX change; should come after reusable pieces exist.

## Verification constraints

Do not run terminal `xcodebuild`. Use lightweight source checks only, per repo instructions.

```sh
swiftc -parse <changed Swift files>
```

Do not launch unsigned builds for TCC/permission approval.
