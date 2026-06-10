//
//  Hallmark · component: settings-window · genre: atmospheric · theme: graphite (blue-anchored neutrals · user accent)
//  states: default · hover · focus · active · disabled · selected
//  pre-emit critique: P4 H5 E4 S4 R5 V4
//

import AppKit
import SwiftUI

/// Settings-local surface tokens. Blue-anchored graphite (anchor follows the
/// cursor accent, hue ~250) — deliberately NOT the violet DS "Dusk" ramp,
/// which reads as the stock AI dark mode. Elevation = lightness: each layer
/// sits ~3% lighter than the one below it.
private enum SettingsTheme {
    /// Window canvas — the deepest layer.
    static let canvas = Color(hex: "#0E1116")
    /// Sidebar and group cards.
    static let raised = Color(hex: "#14171D")
    /// Inputs, tiles, chips, nested wells.
    static let well = Color(hex: "#1A1E25")
    /// Hover state on interactive fills.
    static let hover = Color(hex: "#212630")
    /// Pressed state on interactive fills.
    static let pressed = Color(hex: "#282E3A")
    /// Hairline rules and input borders.
    static let rule = Color(hex: "#313845")
    /// Hovered/strong borders.
    static let ruleStrong = Color(hex: "#424B5C")
}

@MainActor
final class BlinkSettingsWindowManager {
    private var window: NSWindow?
    private let windowSize = NSSize(width: 1120, height: 760)
    private let minimumWindowSize = NSSize(width: 1040, height: 660)

    func show(companionManager: CompanionManager) {
        if window == nil {
            createWindow(companionManager: companionManager)
        } else if let hostingView = window?.contentView as? NSHostingView<BlinkSettingsView> {
            hostingView.rootView = BlinkSettingsView(companionManager: companionManager)
        }

        guard let settingsWindow = window else { return }

        NSApp.activate(ignoringOtherApps: true)
        bringSettingsWindowToFront(settingsWindow, shouldCenter: true)

        DispatchQueue.main.async { [weak self, weak settingsWindow] in
            guard let self, let settingsWindow else { return }
            self.bringSettingsWindowToFront(settingsWindow, shouldCenter: false)
        }
    }

    private func bringSettingsWindowToFront(_ settingsWindow: NSWindow, shouldCenter: Bool) {
        // Blink is an LSUIElement app, so `NSApp.activate(...)` alone
        // doesn't always bring our window above other apps' windows.
        // We briefly elevate to `.floating` to force the initial pop-
        // above behavior, then immediately drop back to `.normal` so
        // that as soon as the user clicks into another app, macOS's
        // standard window layering takes over and Chrome / Finder /
        // anything else ends up in front of the settings window.
        settingsWindow.level = .floating
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        ensureSettingsWindowFitsContent(settingsWindow, shouldCenter: shouldCenter)
        if shouldCenter {
            settingsWindow.center()
        }
        settingsWindow.deminiaturize(nil)
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.makeMain()

        // Drop to `.normal` on the next run-loop turn — the window has
        // already been ordered to the front, so demoting doesn't move
        // it; it just lets normal app layering take effect.
        DispatchQueue.main.async { [weak settingsWindow] in
            settingsWindow?.level = .normal
        }
    }

    private func ensureSettingsWindowFitsContent(_ settingsWindow: NSWindow, shouldCenter: Bool) {
        let visibleFrame = settingsWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let currentFrame = settingsWindow.frame
        let targetWidth = max(currentFrame.width, windowSize.width)
        let targetHeight = max(currentFrame.height, windowSize.height)
        let fittedWidth = visibleFrame.map { min(targetWidth, $0.width - 32) } ?? targetWidth
        let fittedHeight = visibleFrame.map { min(targetHeight, $0.height - 32) } ?? targetHeight
        guard fittedWidth > currentFrame.width || fittedHeight > currentFrame.height else { return }

        let targetSize = NSSize(width: fittedWidth, height: fittedHeight)
        if shouldCenter {
            settingsWindow.setContentSize(targetSize)
        } else {
            var targetFrame = currentFrame
            targetFrame.size = targetSize
            if let visibleFrame {
                targetFrame.origin.x = min(max(targetFrame.origin.x, visibleFrame.minX + 16), visibleFrame.maxX - targetSize.width - 16)
                targetFrame.origin.y = min(max(targetFrame.origin.y, visibleFrame.minY + 16), visibleFrame.maxY - targetSize.height - 16)
            }
            settingsWindow.setFrame(targetFrame, display: true, animate: false)
        }
    }

    private func createWindow(companionManager: CompanionManager) {
        let settingsWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = ""
        settingsWindow.titleVisibility = .hidden
        settingsWindow.minSize = minimumWindowSize
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.toolbarStyle = .unified
        // Settings is committed to the DS "Dusk" system like the rest of
        // Blink's chrome, so native controls must render dark regardless
        // of the system appearance.
        settingsWindow.appearance = NSAppearance(named: .darkAqua)
        settingsWindow.backgroundColor = NSColor(SettingsTheme.canvas)
        settingsWindow.level = .normal
        settingsWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        settingsWindow.center()

        let hostingView = NSHostingView(rootView: BlinkSettingsView(companionManager: companionManager))
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        settingsWindow.contentView = hostingView

        window = settingsWindow
    }
}

private enum BlinkSettingsSection: String, CaseIterable, Identifiable {
    case general
    case voice
    case apiKeys
    case permissions
    case tutorMode
    case agentMode
    case googleWorkspace
    case memory
    case app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .voice: return "Voice"
        case .apiKeys: return "API Keys"
        case .permissions: return "Permissions"
        case .tutorMode: return "Tutor Mode"
        case .agentMode: return "Agents"
        case .googleWorkspace: return "Google"
        case .memory: return "Memory"
        case .app: return "App"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: return "gearshape"
        case .voice: return "waveform"
        case .apiKeys: return "key"
        case .permissions: return "hand.raised"
        case .tutorMode: return "graduationcap"
        case .agentMode: return "terminal"
        case .googleWorkspace: return "globe.americas.fill"
        case .memory: return "books.vertical"
        case .app: return "app.badge"
        }
    }
}

struct BlinkSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var session: CodexAgentSession
    @ObservedObject private var nativeComputerUseController: BlinkNativeComputerUseController
    @ObservedObject private var backgroundComputerUseController: BlinkBackgroundComputerUseController
    @ObservedObject private var petLibrary = BlinkBuddyPetLibrary.shared
    @AppStorage(BlinkAccentTheme.userDefaultsKey) private var selectedAccentThemeID = BlinkAccentTheme.blue.rawValue
    @AppStorage(BlinkCursorAvatarStyle.userDefaultsKey) private var avatarStyleRawValue = BlinkCursorAvatarStyle.default.storageValue
    @AppStorage(AppBundleConfiguration.userAnthropicAPIKeyDefaultsKey) private var userAnthropicAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsAPIKeyDefaultsKey) private var userElevenLabsAPIKey = ""
    @AppStorage(AppBundleConfiguration.userElevenLabsVoiceIDDefaultsKey) private var userElevenLabsVoiceID = ""
    @AppStorage(AppBundleConfiguration.userCartesiaAPIKeyDefaultsKey) private var userCartesiaAPIKey = ""
    @AppStorage(AppBundleConfiguration.userCartesiaVoiceIDDefaultsKey) private var userCartesiaVoiceID = ""
    @AppStorage(AppBundleConfiguration.userOpenAIRealtimeVoiceIDDefaultsKey) private var userOpenAIRealtimeVoiceID = "marin"
    @AppStorage(AppBundleConfiguration.userMicrosoftEdgeVoiceIDDefaultsKey) private var userMicrosoftEdgeVoiceID = "en-US-EmmaMultilingualNeural"
    @AppStorage(AppBundleConfiguration.userDeepgramTTSVoiceDefaultsKey) private var userDeepgramTTSVoice = "aura-2-thalia-en"
    @AppStorage(AppBundleConfiguration.userDeepgramVoiceAgentThinkModelDefaultsKey) private var userDeepgramVoiceAgentThinkModel = "gpt-4o-mini"
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionsEnabledDefaultsKey) private var voiceResponseCaptionsEnabled = false
    @AppStorage(AppBundleConfiguration.userVoiceResponseCaptionFontDefaultsKey) private var voiceResponseCaptionFontRawValue = BlinkResponseCaptionFont.fallback.rawValue
    @AppStorage(AppBundleConfiguration.userCodexAgentAPIKeyDefaultsKey) private var userCodexAgentAPIKey = ""
    @AppStorage(AppBundleConfiguration.userHuggingFaceAPIKeyDefaultsKey) private var userHuggingFaceAPIKey = ""
    @AppStorage(BlinkAgentBackendKind.userDefaultsKey) private var agentBackendRaw = BlinkAgentBackendKind.openAI.rawValue
    @AppStorage(AppBundleConfiguration.userAssemblyAIAPIKeyDefaultsKey) private var userAssemblyAIAPIKey = ""
    @AppStorage(AppBundleConfiguration.userDeepgramAPIKeyDefaultsKey) private var userDeepgramAPIKey = ""
    @AppStorage(AppBundleConfiguration.userWidgetsEnabledDefaultsKey) private var widgetsEnabled = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeAgentTaskNamesDefaultsKey) private var widgetsIncludeAgentTaskNames = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeMemorySnippetsDefaultsKey) private var widgetsIncludeMemorySnippets = false
    @AppStorage(AppBundleConfiguration.userWidgetsIncludeFocusedAppContextDefaultsKey) private var widgetsIncludeFocusedAppContext = false
    @State private var selectedSection: BlinkSettingsSection = .general
    @State private var gogCLIStatus = BlinkGogCLIStatus.unknown
    @State private var isRefreshingGogCLIStatus = false
    @State private var semanticIndexReady = false
    @State private var semanticIndexCount = 0
    @State private var semanticIndexModel = ""
    @State private var chromaStatus: ChromaMemoryStatus?
    @State private var chromaMemories: [ChromaMemoryRecord] = []
    @State private var chromaMemoriesLoaded = false
    @State private var chromaBusy = false
    @State private var hoveredMemoryID: String?
    @State private var clickTesterX: String = ""
    @State private var clickTesterY: String = ""
    @State private var clickTesterStatus: String = "Ready. Coordinates are global screen pixels (origin top-left)."
    @State private var liveAgentPrompt: String = ""
    @ObservedObject private var liveAgentController = BlinkAgentLoopController.shared
    private static let openAIRealtimeVoiceIDs = [
        "marin", "cedar", "alloy", "ash", "ballad",
        "coral", "echo", "sage", "shimmer", "verse"
    ]

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        self.session = companionManager.codexAgentSession
        self.nativeComputerUseController = companionManager.nativeComputerUseController
        self.backgroundComputerUseController = companionManager.backgroundComputerUseController
    }

    private var settingsAccentTheme: BlinkAccentTheme {
        BlinkAccentTheme(rawValue: selectedAccentThemeID) ?? .blue
    }

    private var settingsAccent: Color {
        settingsAccentTheme.cursorColor
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Rectangle()
                .fill(SettingsTheme.rule)
                .frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    sectionHeader
                    selectedPanel
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.canvas)
        }
        .frame(minWidth: 1040, minHeight: 660)
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .googleWorkspace, !gogCLIStatus.isInstalled, !isRefreshingGogCLIStatus {
                refreshGogCLIStatus()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Triangle()
                    .fill(settingsAccent)
                    .frame(width: 13, height: 13)
                    .rotationEffect(.degrees(-22))
                Text("Blink")
                    .font(DS.Typography.heading(16))
                    .tracking(-0.3)
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 18)

            ForEach(BlinkSettingsSection.allCases) { section in
                SettingsSidebarRow(
                    title: section.title,
                    systemImageName: section.systemImageName,
                    accent: settingsAccent,
                    isSelected: selectedSection == section,
                    action: { selectedSection = section }
                )
                .padding(.horizontal, 10)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text(BlinkAgentBackendKind.current() == .huggingFace ? "Backend · HF" : "Backend · OpenAI")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(width: 200)
        .background(SettingsTheme.raised)
    }

    private var sectionHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedSection.title)
                    .font(DS.Typography.heading(26))
                    .tracking(-0.6)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(sectionSubtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle()
                .fill(SettingsTheme.rule)
                .frame(height: 1)
        }
    }

    private var sectionSubtitle: String {
        switch selectedSection {
        case .general:
            return "Core behavior, cursor appearance, and everyday companion controls."
        case .voice:
            return "Speech input, spoken response model, playback voice, and captions."
        case .apiKeys:
            return "Provider credentials for voice, transcription, pointing, and Agent Mode."
        case .permissions:
            return "macOS access needed for voice, screen context, pointing, and app control."
        case .tutorMode:
            return "Tutor behavior, pause guidance, and the future skill-powered tutoring surface."
        case .agentMode:
            return "Background agents, pointing, computer use, Codex configuration, model, working directory, and chat access."
        case .googleWorkspace:
            return "Local Google Workspace connection through gogcli. No hosted Google login or key sync."
        case .memory:
            return "Persistent memory, learned workflow skills, and local knowledge tools."
        case .app:
            return "Onboarding, support, and app-level actions."
        }
    }

    @ViewBuilder
    private var selectedPanel: some View {
        switch selectedSection {
        case .general:
            generalPanel
        case .voice:
            voicePanel
        case .apiKeys:
            apiKeysPanel
        case .permissions:
            permissionsPanel
        case .tutorMode:
            tutorModePanel
        case .agentMode:
            agentModePanel
        case .googleWorkspace:
            googleWorkspacePanel
        case .memory:
            memoryPanel
        case .app:
            appPanel
        }
    }

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            settingsGroup("Companion") {
                toggleRow(
                    title: "Show Blink cursor",
                    subtitle: "Keeps the cursor companion visible and ready for push-to-talk.",
                    systemImageName: "cursorarrow",
                    isOn: Binding(
                        get: { companionManager.isBlinkCursorEnabled },
                        set: { companionManager.setBlinkCursorEnabled($0) }
                    )
                )

                settingsRowDivider

                toggleRow(
                    title: "Advanced mode",
                    subtitle: "Shows Agent Mode chat controls, inline agent input, model controls, and memory tools.",
                    systemImageName: "slider.horizontal.3",
                    isOn: Binding(
                        get: { companionManager.isAdvancedModeEnabled },
                        set: { companionManager.setAdvancedModeEnabled($0) }
                    )
                )
            }

            settingsGroup("Cursor appearance") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pick Blink's cursor shape and accent color. Pets ignore the color tint, but the accent drives glows, buttons, and task badges.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        cursorAvatarButton(.triangleFilled, label: "Triangle")
                        cursorAvatarButton(.triangleOutline, label: "Outline")
                        ForEach(petLibrary.pets) { pet in
                            cursorPetButton(pet)
                        }
                        if petLibrary.pets.isEmpty {
                            emptyPetLibraryTile
                        }
                    }

                    HStack(spacing: 10) {
                        ForEach([BlinkAccentTheme.blue, .rose, .amber, .mint, .white]) { accentTheme in
                            cursorColorButton(accentTheme)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var tutorModePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Tutor Mode") {
                toggleRow(
                    title: "Tutor mode",
                    subtitle: "Watches for short pauses and offers small next-step guidance.",
                    systemImageName: "graduationcap",
                    isOn: Binding(
                        get: { companionManager.isTutorModeEnabled },
                        set: { companionManager.setTutorModeEnabled($0) }
                    )
                )
            }

            settingsGroup("Tutor skills") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skill-powered tutoring")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("This section is ready for the tutor skills controls that will be wired in next.")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var voicePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            voiceRouteOverview

            settingsGroup("Response voice model") {
                groupDescription("Pick Realtime when one model should listen and speak live, or use a normal model when Blink should think first and hand the reply to a playback engine.")

                modelOptionGrid(
                    options: BlinkModelCatalog.responseVoiceModels,
                    selectedModelID: companionManager.selectedModel,
                    columns: 3,
                    select: { companionManager.setSelectedModel($0) }
                )

                if BlinkModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .openAI,
                   BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    Picker("Realtime voice", selection: Binding(
                        get: {
                            userOpenAIRealtimeVoiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "marin"
                                : userOpenAIRealtimeVoiceID
                        },
                        set: {
                            userOpenAIRealtimeVoiceID = $0
                            companionManager.setOpenAIRealtimeVoiceID($0)
                        }
                    )) {
                        ForEach(Self.openAIRealtimeVoiceIDs, id: \.self) { voiceID in
                            Text(voiceID.capitalized).tag(voiceID)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if BlinkModelCatalog.voiceResponseModel(withID: companionManager.selectedModel).provider == .deepgram {
                    groupDescription("Deepgram Voice Agent uses one WebSocket for listening, thinking, and speaking; it reuses the Deepgram key under API Keys.")
                    textFieldRow(
                        title: "Deepgram voice",
                        subtitle: "Aura model identifier for the speak stage.",
                        systemImageName: "person.wave.2",
                        placeholder: "aura-2-thalia-en",
                        text: Binding(
                            get: { userDeepgramTTSVoice },
                            set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                        )
                    )
                    textFieldRow(
                        title: "Deepgram think model",
                        subtitle: "LLM model Deepgram should use inside the Voice Agent.",
                        systemImageName: "brain.head.profile",
                        placeholder: "gpt-4o-mini",
                        text: Binding(
                            get: { userDeepgramVoiceAgentThinkModel },
                            set: { userDeepgramVoiceAgentThinkModel = $0; companionManager.setDeepgramVoiceAgentThinkModel($0) }
                        )
                    )
                }
            }

            settingsGroup("Listening / transcription") {
                if BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                    valueRow(
                        title: "Current input path",
                        subtitle: "GPT Realtime is selected, so Blink streams microphone audio directly to Realtime instead of using Whisper or another speech-to-text provider.",
                        systemImageName: "waveform.badge.mic"
                    )
                }

                valueRow(
                    title: "Current provider",
                    subtitle: BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Bypassed while GPT Realtime is the response voice model"
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "waveform"
                )

                if let transcriptionError = companionManager.buddyDictationManager.lastErrorMessage,
                   !transcriptionError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    warningRow(
                        title: "Transcription error",
                        subtitle: transcriptionError
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BuddyTranscriptionProviderID.allCases) { provider in
                        optionButton(
                            title: provider.label,
                            subtitle: provider.subtitle,
                            isSelected: companionManager.buddyDictationManager.transcriptionProviderID == provider.rawValue,
                            action: { companionManager.setVoiceTranscriptionProvider(provider.rawValue) }
                        )
                    }
                }
                .padding(14)
            }

            settingsGroup("Response captions") {
                toggleRow(
                    title: "Caption every spoken response",
                    subtitle: "Shows Blink's spoken reply beside the cursor while voice playback runs.",
                    systemImageName: "captions.bubble",
                    isOn: $voiceResponseCaptionsEnabled
                )

                LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                    ForEach(BlinkResponseCaptionFont.allCases) { captionFont in
                        optionButton(
                            title: captionFont.label,
                            subtitle: captionFont.subtitle,
                            isSelected: voiceResponseCaptionFontRawValue == captionFont.rawValue,
                            action: { voiceResponseCaptionFontRawValue = captionFont.rawValue }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 11)

                actionRow(title: "Test caption playback", systemImageName: "play.circle") {
                    companionManager.testVoiceResponseCaptionPlayback()
                }
            }

            settingsGroup("Speculative pre-fire") {
                toggleRow(
                    title: "Pre-fire on stable speech",
                    subtitle: "Starts the AI response while you're still talking when a partial is stable, no screen reference, and looks like a question. Saves up to 1s of TTFT but costs ~1.5–2× input tokens per turn for cancelled fires. Off by default.",
                    systemImageName: "bolt.horizontal",
                    isOn: Binding(
                        get: { companionManager.speculativePreFireEnabled },
                        set: { companionManager.setSpeculativePreFireEnabled($0) }
                    )
                )
            }

            settingsGroup("Playback") {
                VStack(alignment: .leading, spacing: 16) {
                    groupDescription(BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "GPT Realtime is selected as the response voice model, so it owns playback for voice replies."
                        : "Choose the separate TTS provider used when a normal text model generates Blink's reply.")

                    if !BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Playback engine")
                                .font(DS.Typography.label(11))
                                .foregroundColor(DS.Colors.textTertiary)

                            Picker("", selection: Binding(
                                get: { companionManager.selectedTTSProvider },
                                set: { companionManager.setTTSProvider($0) }
                            )) {
                                ForEach(BlinkTTSProvider.allCases.filter { $0 != .openAIRealtime }) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    Group {
                        switch companionManager.selectedTTSProvider {
                        case .openAITTS:
                            Text("OpenAI's /v1/audio/speech endpoint. Voice: nova by default. Uses OPENAI_API_KEY.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .system:
                            Text("Uses the built-in macOS voice (Siri / Samantha). No API key required.")
                                .font(.system(size: 11))
                                .foregroundColor(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        case .openAIRealtime:
                            EmptyView()
                        case .elevenLabs:
                            textFieldRow(
                                title: "ElevenLabs voice ID",
                                subtitle: "Optional custom voice override.",
                                systemImageName: "person.wave.2",
                                placeholder: "Voice ID",
                                text: Binding(
                                    get: { userElevenLabsVoiceID },
                                    set: { userElevenLabsVoiceID = $0; companionManager.setElevenLabsVoiceID($0) }
                                )
                            )
                        case .cartesia:
                            textFieldRow(
                                title: "Cartesia voice ID",
                                subtitle: "Optional custom voice override.",
                                systemImageName: "person.wave.2",
                                placeholder: "Voice ID",
                                text: Binding(
                                    get: { userCartesiaVoiceID },
                                    set: { userCartesiaVoiceID = $0; companionManager.setCartesiaVoiceID($0) }
                                )
                            )
                        case .deepgram:
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Deepgram TTS reuses the Deepgram API key set under API Keys.")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                textFieldRow(
                                    title: "Deepgram TTS voice",
                                    subtitle: "Aura model identifier — e.g. aura-2-thalia-en, aura-2-orion-en, aura-2-luna-en.",
                                    systemImageName: "person.wave.2",
                                    placeholder: "aura-2-thalia-en",
                                    text: Binding(
                                        get: { userDeepgramTTSVoice },
                                        set: { userDeepgramTTSVoice = $0; companionManager.setDeepgramTTSVoice($0) }
                                    )
                                )
                            }
                        case .microsoftEdge:
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Microsoft Edge voices are the free online Read Aloud voices and do not need an API key.")
                                    .font(.system(size: 11))
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Voices")
                                        .font(DS.Typography.label(11))
                                        .foregroundColor(DS.Colors.textTertiary)

                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                                        ForEach(MicrosoftEdgeVoiceOption.recommended) { voice in
                                            optionButton(
                                                title: voice.label,
                                                subtitle: voice.subtitle,
                                                isSelected: AppBundleConfiguration.microsoftEdgeVoiceID() == voice.id,
                                                action: {
                                                    userMicrosoftEdgeVoiceID = voice.id
                                                    companionManager.setMicrosoftEdgeVoiceID(voice.id)
                                                }
                                            )
                                        }
                                    }
                                }

                                textFieldRow(
                                    title: "Microsoft Edge voice ID",
                                    subtitle: "Optional override for any Edge voice, e.g. en-US-AriaNeural.",
                                    systemImageName: "person.wave.2",
                                    placeholder: "en-US-EmmaMultilingualNeural",
                                    text: Binding(
                                        get: { userMicrosoftEdgeVoiceID },
                                        set: { userMicrosoftEdgeVoiceID = $0; companionManager.setMicrosoftEdgeVoiceID($0) }
                                    )
                                )
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    private var voiceRouteOverview: some View {
        settingsGroup("Voice route") {
            LazyVGrid(columns: settingsOptionColumns(3), spacing: 8) {
                voiceRouteStep(
                    title: "Listen",
                    value: BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Realtime audio"
                        : companionManager.buddyDictationManager.transcriptionProviderDisplayName,
                    systemImageName: "mic"
                )
                voiceRouteStep(
                    title: "Think",
                    value: selectedResponseVoiceModelLabel,
                    systemImageName: "brain.head.profile"
                )
                voiceRouteStep(
                    title: "Speak",
                    value: BlinkModelCatalog.isSpeechModelID(companionManager.selectedModel)
                        ? "Realtime voice"
                        : companionManager.selectedTTSProvider.displayName,
                    systemImageName: "speaker.wave.2"
                )
            }
            .padding(14)
        }
    }

    private var selectedResponseVoiceModelLabel: String {
        BlinkModelCatalog.responseVoiceModels.first { $0.id == companionManager.selectedModel }?.label
            ?? companionManager.selectedModel
    }

    private var pointingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Screen pointing model") {
                modelOptionGrid(
                    options: BlinkModelCatalog.computerUseModels,
                    selectedModelID: companionManager.selectedComputerUseModel,
                    select: { companionManager.setSelectedComputerUseModel($0) }
                )
            }
        }
    }

    private var apiKeysPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("OpenAI and Claude") {
                secureFieldRow(
                    title: "Codex/OpenAI API key",
                    subtitle: "Used for Agent Mode overrides and GPT Realtime voice when a key is needed.",
                    systemImageName: "key",
                    placeholder: "OpenAI key",
                    text: Binding(
                        get: { userCodexAgentAPIKey },
                        set: { userCodexAgentAPIKey = $0; companionManager.setCodexAgentAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Anthropic API key",
                    subtitle: "Optional key for Claude voice and pointing providers.",
                    systemImageName: "key",
                    placeholder: "Anthropic key",
                    text: Binding(
                        get: { userAnthropicAPIKey },
                        set: { userAnthropicAPIKey = $0; companionManager.setAnthropicAPIKey($0) }
                    )
                )
            }

            settingsGroup("Open source backend") {
                secureFieldRow(
                    title: "HuggingFace API token",
                    subtitle: "Powers the open-source Codex backend (Qwen2.5-Coder) and the semantic knowledge index.",
                    systemImageName: "key.horizontal",
                    placeholder: "hf_…",
                    text: Binding(
                        get: { userHuggingFaceAPIKey },
                        set: { newValue in
                            userHuggingFaceAPIKey = newValue
                            Task.detached(priority: .utility) {
                                await BlinkSemanticIndex.shared.rebuild()
                            }
                        }
                    )
                )
            }

            settingsGroup("Listening providers") {
                secureFieldRow(
                    title: "AssemblyAI listening key",
                    subtitle: "Used by the AssemblyAI streaming transcription provider.",
                    systemImageName: "key",
                    placeholder: "AssemblyAI key",
                    text: Binding(
                        get: { userAssemblyAIAPIKey },
                        set: { userAssemblyAIAPIKey = $0; companionManager.setAssemblyAIAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Deepgram listening key",
                    subtitle: "Used by Deepgram streaming transcription, Aura TTS, and Deepgram Voice Agent.",
                    systemImageName: "key",
                    placeholder: "Deepgram key",
                    text: Binding(
                        get: { userDeepgramAPIKey },
                        set: { userDeepgramAPIKey = $0; companionManager.setDeepgramAPIKey($0) }
                    )
                )
            }

            settingsGroup("Playback providers") {
                secureFieldRow(
                    title: "ElevenLabs API key",
                    subtitle: "Used for spoken Blink replies when ElevenLabs is selected.",
                    systemImageName: "key",
                    placeholder: "ElevenLabs key",
                    text: Binding(
                        get: { userElevenLabsAPIKey },
                        set: { userElevenLabsAPIKey = $0; companionManager.setElevenLabsAPIKey($0) }
                    )
                )

                secureFieldRow(
                    title: "Cartesia API key",
                    subtitle: "Used for spoken Blink replies when Cartesia is selected.",
                    systemImageName: "key",
                    placeholder: "Cartesia key",
                    text: Binding(
                        get: { userCartesiaAPIKey },
                        set: { userCartesiaAPIKey = $0; companionManager.setCartesiaAPIKey($0) }
                    )
                )
            }
        }
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Core permissions") {
                permissionRow(
                    title: "Accessibility",
                    isGranted: companionManager.hasAccessibilityPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
                permissionRow(
                    title: "Screen Recording",
                    isGranted: companionManager.hasScreenRecordingPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Screen Content",
                    isGranted: companionManager.hasScreenContentPermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                )
                permissionRow(
                    title: "Microphone",
                    isGranted: companionManager.hasMicrophonePermission,
                    settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                )
                permissionRow(
                    title: "Full Disk Access",
                    isGranted: companionManager.hasFullDiskAccessPermission,
                    settingsURL: BlinkMacPrivacyPermissionProbe.fullDiskAccessSettingsURL
                )
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshAllPermissions()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                actionRow(title: "Open Microphone settings", systemImageName: "mic") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                }
                actionRow(title: "Open Full Disk Access settings", systemImageName: "externaldrive.badge.checkmark") {
                    companionManager.openFullDiskAccessSettings()
                }
            }
        }
    }

    private var computerUsePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Computer use backend") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(BlinkComputerUseBackendID.allCases) { backend in
                        optionButton(
                            title: backend.label,
                            subtitle: backend.subtitle,
                            isSelected: companionManager.selectedComputerUseBackendID == backend.rawValue,
                            action: { companionManager.setSelectedComputerUseBackend(backend.rawValue) }
                        )
                    }
                }
                .padding(14)
            }

            settingsGroup("Native CUA Swift") {
                toggleRow(
                    title: "Enable in-app computer use",
                    subtitle: "Uses Blink's own signed app permissions for focused-window context and targeted keyboard actions.",
                    systemImageName: "macwindow.and.cursorarrow",
                    isOn: Binding(
                        get: { nativeComputerUseController.isEnabled },
                        set: { companionManager.setNativeComputerUseEnabled($0) }
                    )
                )

                valueRow(
                    title: "Runtime status",
                    subtitle: nativeComputerUseController.status.summary,
                    systemImageName: nativeComputerUseController.status.isReadyForComputerUse ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "Focused target",
                    subtitle: nativeComputerUseController.status.focusedTargetSummary,
                    systemImageName: "scope"
                )
            }

            if companionManager.isAdvancedModeEnabled {
                settingsGroup("Experimental Background Computer Use") {
                    valueRow(
                        title: "Experimental runtime",
                        subtitle: "Dev-only external runtime. Native CUA is the supported Blink path.",
                        systemImageName: "exclamationmark.triangle"
                    )
                    valueRow(
                        title: "Runtime status",
                        subtitle: backgroundComputerUseController.status.summary,
                        systemImageName: backgroundComputerUseController.status.isRuntimeReady ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    valueRow(
                        title: "Manifest",
                        subtitle: backgroundComputerUseController.status.manifestPath,
                        systemImageName: "doc.text.magnifyingglass"
                    )
                    actionRow(title: "Start Experimental Background Computer Use", systemImageName: "play.circle") {
                        companionManager.startBackgroundComputerUseRuntime()
                    }
                    actionRow(title: "Refresh experimental status", systemImageName: "arrow.clockwise") {
                        companionManager.refreshBackgroundComputerUseStatus()
                    }
                }
            }

            settingsGroup("Actions") {
                actionRow(title: "Refresh focused target", systemImageName: "arrow.clockwise") {
                    companionManager.refreshNativeComputerUseFocusedTarget()
                }
                actionRow(title: "Refresh permission status", systemImageName: "checklist") {
                    companionManager.refreshNativeComputerUseStatus()
                }
                actionRow(title: "Open Accessibility settings", systemImageName: "hand.raised") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                actionRow(title: "Open Screen Recording settings", systemImageName: "rectangle.on.rectangle") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }

            settingsGroup("Automation access") {
                valueRow(
                    title: "Automation",
                    subtitle: "macOS grants Automation per target app when Blink first sends an Apple Event.",
                    systemImageName: "terminal"
                )
            }
        }
    }

    private var agentModePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Agent backend") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pick the model that powers Agent Mode tasks. OpenAI is the default (Codex via gpt-5/o-series). HuggingFace routes through the open-source Qwen2.5-Coder using your HF token.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        optionButton(
                            title: "OpenAI",
                            subtitle: "Codex via api.openai.com (default).",
                            isSelected: agentBackendRaw == BlinkAgentBackendKind.openAI.rawValue,
                            action: { setAgentBackend(.openAI) }
                        )
                        optionButton(
                            title: "HuggingFace · Qwen2.5-Coder",
                            subtitle: "Open-source, routed via router.huggingface.co.",
                            isSelected: agentBackendRaw == BlinkAgentBackendKind.huggingFace.rawValue,
                            action: { setAgentBackend(.huggingFace) }
                        )
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }

            settingsGroup("Agent Mode") {
                modelOptionGrid(
                    options: BlinkModelCatalog.codexActionsModels,
                    selectedModelID: session.model,
                    select: { session.setModel($0) }
                )

                textFieldRow(
                    title: "Working directory",
                    subtitle: "Default folder used by new agent turns.",
                    systemImageName: "folder",
                    placeholder: FileManager.default.homeDirectoryForCurrentUser.path,
                    text: Binding(
                        get: { session.workingDirectoryPath },
                        set: { newValue in
                            session.workingDirectoryPath = newValue
                            UserDefaults.standard.set(newValue, forKey: "blinkCodexWorkingDirectory")
                        }
                    ),
                    openPath: { session.workingDirectoryPath }
                )
            }

            pointingPanel

            computerUsePanel

            liveAgentControlGroup

            nativeClickTesterGroup

            settingsGroup("Agent dock position") {
                AgentParkingPositionPicker(
                    selection: Binding(
                        get: { companionManager.agentParkingPosition },
                        set: { companionManager.setAgentParkingPosition($0) }
                    ),
                    calibrationChanged: { position, offset in
                        companionManager.setAgentParkingCalibrationOffset(offset, for: position)
                    }
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }

            if companionManager.isAdvancedModeEnabled {
                settingsGroup("Agent tools") {
                    actionRow(title: "Open Agent chat", systemImageName: "message") {
                        companionManager.showCodexHUD()
                    }
                    actionRow(title: "Warm up Agent Mode", systemImageName: "bolt") {
                        companionManager.warmUpCodexAgentMode()
                    }
                }

                #if DEBUG
                settingsGroup("Developer tools") {
                    actionRow(title: "Test cursor flight", systemImageName: "arrow.up.right") {
                        companionManager.debugTestCursorFlight()
                    }
                    actionRow(title: "Show response card", systemImageName: "text.bubble") {
                        companionManager.debugShowResponseCard()
                    }
                    actionRow(title: "Capture screen context", systemImageName: "camera") {
                        companionManager.debugCaptureAgentScreenContext()
                    }
                    actionRow(title: "Reset transient UI", systemImageName: "xmark.circle", role: .destructive) {
                        companionManager.debugResetTransientUI()
                    }
                }
                #endif
            }
        }
    }

    private var googleWorkspacePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Google Workspace") {
                googleConnectionHeader

                valueRow(
                    title: "gogcli",
                    subtitle: gogCLIStatus.isInstalled
                        ? "\(gogCLIStatus.version ?? "Installed") — \(gogCLIStatus.executablePath ?? "gog")"
                        : "Not installed. Install with Homebrew: brew install gogcli",
                    systemImageName: gogCLIStatus.isInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )

                valueRow(
                    title: "OAuth credentials",
                    subtitle: gogCLIStatus.credentialsExist
                        ? "Desktop OAuth client is stored locally in gogcli."
                        : "Add a Google Cloud Desktop OAuth client JSON with gog auth credentials.",
                    systemImageName: gogCLIStatus.credentialsExist ? "checkmark.seal" : "key"
                )

                valueRow(
                    title: "Account",
                    subtitle: gogCLIStatus.accountEmail ?? "No default Google account authorized yet.",
                    systemImageName: gogCLIStatus.isReadyForUserAccount ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark"
                )

                valueRow(
                    title: "Storage",
                    subtitle: gogCLIStatus.configPath ?? "gogcli manages its own local config and keyring.",
                    systemImageName: "externaldrive.badge.person.crop",
                    openPath: gogCLIStatus.configPath
                )
            }

            settingsGroup("Action") {
                actionRow(title: isRefreshingGogCLIStatus ? "Refreshing…" : "Refresh", systemImageName: "arrow.clockwise") {
                    refreshGogCLIStatus()
                }
                if !gogCLIStatus.isInstalled || !gogCLIStatus.credentialsExist {
                    actionRow(title: "Copy setup commands", systemImageName: "doc.on.doc") {
                        copyGoogleWorkspaceSetupCommands()
                    }
                }
            }

            settingsGroup("Privacy") {
                valueRow(
                    title: "Local connector",
                    subtitle: "Agents use gogcli on this Mac. Blink does not host Google login or sync Google keys.",
                    systemImageName: "lock.shield"
                )
            }
        }
    }

    private var googleConnectionHeader: some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle()
                    .fill(SettingsTheme.well)
                Text("G")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(gogCLIStatus.readinessTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(gogCLIStatus.readinessDetail)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            conversationMemoryGroup

            settingsGroup("Semantic knowledge index") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Blink embeds its bundled app-help corpus (Onshape, Blender, Photoshop, Illustrator, Figma) with all-MiniLM-L6-v2 via HuggingFace, then retrieves the top matches when you ask a how-to question. Falls back to lexical retrieval if the index isn't ready.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        semanticIndexStatusChip
                        Spacer()
                        Button {
                            Task.detached(priority: .utility) {
                                await BlinkSemanticIndex.shared.rebuild()
                                await MainActor.run { refreshSemanticIndexStatus() }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Rebuild index")
                            }
                        }
                        .buttonStyle(SettingsPillButtonStyle(emphasis: .filled))
                    }
                }
                .padding(14)
                .onAppear {
                    refreshSemanticIndexStatus()
                }
            }

            settingsGroup("Persistent memory") {
                valueRow(
                    title: "Memory file",
                    subtitle: companionManager.codexHomeManager.persistentMemoryFile.path,
                    systemImageName: "doc.text",
                    openPath: companionManager.codexHomeManager.persistentMemoryFile.path
                )
                valueRow(
                    title: "Learned skills",
                    subtitle: companionManager.codexHomeManager.learnedSkillsDirectory.path,
                    systemImageName: "wand.and.stars",
                    openPath: companionManager.codexHomeManager.learnedSkillsDirectory.path
                )
                valueRow(
                    title: "Knowledge index",
                    subtitle: "\(companionManager.bundledKnowledgeIndex.articles.count) articles, \(companionManager.bundledKnowledgeIndex.skills.count) skills",
                    systemImageName: "books.vertical"
                )
            }

            settingsGroup("Memory tools") {
                actionRow(title: "Open memory browser", systemImageName: "books.vertical") {
                    companionManager.showMemoryWindow()
                }
                actionRow(title: "Open memory file", systemImageName: "doc.text") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryFile)
                }
                actionRow(title: "Open memory archive folder", systemImageName: "archivebox") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.persistentMemoryArchivesDirectory)
                }
                actionRow(title: "Open learned skills folder", systemImageName: "folder") {
                    NSWorkspace.shared.open(companionManager.codexHomeManager.learnedSkillsDirectory)
                }
            }
        }
    }

    private var conversationMemoryGroup: some View {
        settingsGroup("Conversation memory") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Blink remembers what you tell it across sessions in a local store on your Mac, scoped to the app you're in — no setup or server needed. Recall is automatic; you can review or delete what's saved here, or just say \"forget what I said about …\". Embedding past exchanges needs an OpenAI or Hugging Face key.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    conversationMemoryStatusChip
                    Spacer()
                    Button {
                        Task { await loadChromaStatus(); await loadChromaMemories() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Refresh")
                        }
                    }
                    .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
                    .disabled(chromaBusy)
                }

                if let status = chromaStatus, status.providerMismatch {
                    conversationMemoryMismatchWarning(status)
                }

                if let status = chromaStatus, status.reachable {
                    conversationMemoryList(count: status.count)
                }
            }
            .padding(14)
            .onAppear {
                Task { await loadChromaStatus() }
            }
        }
    }

    private var conversationMemoryStatusChip: some View {
        let reachable = chromaStatus?.reachable ?? false
        let count = chromaStatus?.count ?? 0
        let model = chromaStatus?.currentModel
        let dotColor = reachable ? DS.Colors.success : DS.Colors.warning
        return HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(reachable ? "\(count) stored exchange\(count == 1 ? "" : "s")" : "Memory unavailable")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(reachable ? (model ?? "add an OpenAI or Hugging Face key to enable recall") : "add an OpenAI or Hugging Face key to enable recall")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(SettingsTheme.well)
        )
    }

    private func conversationMemoryMismatchWarning(_ status: ChromaMemoryStatus) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.warningText)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Embedding model changed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("This store was built with \(status.storedModel ?? "another model"), but Blink now embeds with \(status.currentModel ?? "a different model"). Saved memories can't be read until the store is reset.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(role: .destructive) {
                    Task { await resetChromaMemory() }
                } label: {
                    Text("Reset memory")
                }
                .buttonStyle(SettingsPillButtonStyle(emphasis: .destructive))
                .disabled(chromaBusy)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.30), lineWidth: 1)
        )
    }

    private func conversationMemoryList(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stored memories")
                    .font(DS.Typography.label(11))
                    .foregroundColor(DS.Colors.textTertiary)
                if chromaMemoriesLoaded, !chromaMemories.isEmpty {
                    Text("\(chromaMemories.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SettingsTheme.hover))
                }
                Spacer()
                if !chromaMemoriesLoaded {
                    Button("Show") {
                        Task { await loadChromaMemories() }
                    }
                    .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
                    .disabled(chromaBusy || count == 0)
                } else if !chromaMemories.isEmpty {
                    Button(role: .destructive) {
                        Task { await forgetAllChroma() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Forget all")
                        }
                    }
                    .buttonStyle(SettingsPillButtonStyle(emphasis: .destructive))
                    .disabled(chromaBusy)
                }
            }

            if chromaMemoriesLoaded {
                if chromaMemories.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "tray")
                            .font(.system(size: 20, weight: .light))
                            .foregroundColor(DS.Colors.textTertiary)
                        Text("Nothing stored yet")
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 7) {
                            ForEach(chromaMemories) { record in
                                conversationMemoryRow(record)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
    }

    private func conversationMemoryRow(_ record: ChromaMemoryRecord) -> some View {
        let accent = settingsAccent
        let hovered = hoveredMemoryID == record.id
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(accent.opacity(hovered ? 0.9 : 0.45))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    if let app = record.appName, !app.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 9, weight: .semibold))
                            Text(app)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(SettingsTheme.hover))
                    }
                    if let time = record.timestamp.flatMap(Self.relativeMemoryTimestamp) {
                        Text(time)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await deleteChroma(record) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(hovered ? DS.Colors.destructiveText : DS.Colors.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(hovered ? SettingsTheme.pressed : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(chromaBusy)
                    .help("Delete this memory")
                }

                conversationMemoryMessageLine(
                    icon: "person.fill",
                    iconColor: accent,
                    text: record.transcript.isEmpty ? "(no transcript)" : record.transcript,
                    textColor: DS.Colors.textPrimary
                )
                if !record.response.isEmpty {
                    conversationMemoryMessageLine(
                        icon: "sparkles",
                        iconColor: DS.Colors.textTertiary,
                        text: record.response,
                        textColor: DS.Colors.textSecondary
                    )
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(hovered ? SettingsTheme.hover : SettingsTheme.well)
        )
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveredMemoryID = record.id
            } else if hoveredMemoryID == record.id {
                hoveredMemoryID = nil
            }
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: hovered)
    }

    private func conversationMemoryMessageLine(icon: String, iconColor: Color, text: String, textColor: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(iconColor)
                .frame(width: 13, height: 13)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(textColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func relativeMemoryTimestamp(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @MainActor private func loadChromaStatus() async {
        chromaStatus = await companionManager.chromaMemoryStatus()
    }

    @MainActor private func loadChromaMemories() async {
        chromaBusy = true
        chromaMemories = await companionManager.chromaAllMemories()
        chromaMemoriesLoaded = true
        chromaBusy = false
    }

    @MainActor private func deleteChroma(_ record: ChromaMemoryRecord) async {
        chromaBusy = true
        await companionManager.chromaDeleteMemory(id: record.id)
        chromaMemories.removeAll { $0.id == record.id }
        chromaBusy = false
        await loadChromaStatus()
    }

    @MainActor private func forgetAllChroma() async {
        chromaBusy = true
        await companionManager.chromaClearAllMemories()
        chromaMemories = []
        chromaBusy = false
        await loadChromaStatus()
    }

    @MainActor private func resetChromaMemory() async {
        chromaBusy = true
        await companionManager.chromaClearAllMemories()
        chromaMemories = []
        chromaMemoriesLoaded = false
        chromaBusy = false
        await loadChromaStatus()
    }

    private var appPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroup("Support") {
                actionRow(title: "Report issues and star on GitHub", systemImageName: "star.bubble") {
                    openFeedbackInbox()
                }
            }

            settingsGroup("Logs") {
                valueRow(
                    title: "Message log",
                    subtitle: BlinkMessageLogStore.shared.currentLogFile.path,
                    systemImageName: "doc.text.magnifyingglass",
                    openPath: BlinkMessageLogStore.shared.currentLogFile.path
                )
                actionRow(title: "Open log viewer", systemImageName: "list.bullet.rectangle") {
                    companionManager.showLogViewerWindow()
                }
                actionRow(title: "Open raw message log", systemImageName: "doc.text") {
                    openMessageLog()
                }
                actionRow(title: "Open logs folder", systemImageName: "folder") {
                    openLogsFolder()
                }
            }

            settingsGroup("Widgets") {
                toggleRow(
                    title: "Enable desktop widgets",
                    subtitle: "Publishes a compact Blink snapshot for WidgetKit.",
                    systemImageName: "rectangle.grid.1x2",
                    isOn: Binding(
                        get: { widgetsEnabled },
                        set: { newValue in
                            widgetsEnabled = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show agent task names",
                    subtitle: "Allows widgets to display task titles and short captions.",
                    systemImageName: "text.alignleft",
                    isOn: Binding(
                        get: { widgetsIncludeAgentTaskNames },
                        set: { newValue in
                            widgetsIncludeAgentTaskNames = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show memory snippets",
                    subtitle: "Allows widgets to show a compact recent memory summary.",
                    systemImageName: "brain.head.profile",
                    isOn: Binding(
                        get: { widgetsIncludeMemorySnippets },
                        set: { newValue in
                            widgetsIncludeMemorySnippets = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                toggleRow(
                    title: "Show focused-app context",
                    subtitle: "Reserved for future focus widgets. Keep off unless you want desktop context shown.",
                    systemImageName: "macwindow",
                    isOn: Binding(
                        get: { widgetsIncludeFocusedAppContext },
                        set: { newValue in
                            widgetsIncludeFocusedAppContext = newValue
                            companionManager.publishWidgetSnapshot()
                        }
                    )
                )
                actionRow(title: "Open widget snapshot", systemImageName: "doc.text.magnifyingglass") {
                    companionManager.publishWidgetSnapshot()
                    NSWorkspace.shared.open(BlinkWidgetStateStore.snapshotURL)
                }
            }

            settingsGroup("Onboarding") {
                actionRow(title: "Show Blink cursor now", systemImageName: "cursorarrow.rays") {
                    companionManager.triggerOnboarding()
                }
                actionRow(title: "Replay onboarding cleanup", systemImageName: "play.circle") {
                    companionManager.replayOnboarding()
                }
            }

            settingsGroup("App") {
                actionRow(title: "Quit Blink", systemImageName: "power", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func refreshGogCLIStatus() {
        guard !isRefreshingGogCLIStatus else { return }
        isRefreshingGogCLIStatus = true
        Task {
            let status = await BlinkGogCLIStatusResolver.refresh()
            gogCLIStatus = status
            isRefreshingGogCLIStatus = false
        }
    }

    private func copyGoogleWorkspaceSetupCommands() {
        let commands = """
        # Install gogcli if needed
        brew install gogcli

        # Store a Google Cloud Desktop OAuth client JSON locally in gogcli
        gog auth credentials ~/Downloads/client_secret_....json

        # Authorize least-privilege scopes for common agent reads
        gog auth add you@example.com --services gmail,drive --gmail-scope readonly --drive-scope readonly
        gog auth add you@example.com --services calendar,tasks --readonly

        # Optional Workspace alias
        gog auth alias set work you@example.com
        gog auth status --json
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    private func openURL(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openSettingsPath(_ rawPath: String) {
        let path = normalizedSettingsPath(rawPath)
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            NSWorkspace.shared.open(url)
            return
        }

        openSettingsFileInTextEditor(url)
    }

    private func normalizedSettingsPath(_ rawPath: String) -> String {
        let path = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "file://", with: "")

        return (path as NSString).expandingTildeInPath
    }

    private func openSettingsFileInTextEditor(_ url: URL) {
        let textEditURL = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        guard FileManager.default.fileExists(atPath: textEditURL.path) else {
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: textEditURL, configuration: configuration) { _, error in
            if error != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private var semanticIndexStatusChip: some View {
        let dotColor: Color = semanticIndexReady ? DS.Colors.success : DS.Colors.warning
        return HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(semanticIndexReady ? "Ready · \(semanticIndexCount) entries" : "Not ready · using lexical fallback")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(semanticIndexModel.isEmpty ? "all-MiniLM-L6-v2" : semanticIndexModel)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(SettingsTheme.well)
        )
    }

    private func refreshSemanticIndexStatus() {
        Task.detached(priority: .utility) {
            let status = await BlinkSemanticIndex.shared.status()
            await MainActor.run {
                semanticIndexReady = status.ready
                semanticIndexCount = status.count
                semanticIndexModel = status.model
            }
        }
    }

    private func setAgentBackend(_ backend: BlinkAgentBackendKind) {
        agentBackendRaw = backend.rawValue
        UserDefaults.standard.set(backend.rawValue, forKey: BlinkAgentBackendKind.userDefaultsKey)
        try? companionManager.codexHomeManager.regenerateConfig()
    }

    private var liveAgentControlGroup: some View {
        let accent = settingsAccent

        return settingsGroup("Live agent control") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type what you want Blink to do — open apps, click buttons, fill in text. Claude drives the cursor and keyboard through Blink's signed Accessibility permission. Press Esc anywhere to pause; click Stop to abort.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    SettingsTextField(
                        placeholder: "e.g. open Safari and search for the weather in Tokyo",
                        text: $liveAgentPrompt,
                        axis: .vertical,
                        lineLimit: 1...4
                    )
                    .disabled(liveAgentController.isRunning)
                    .onSubmit { runLiveAgent() }

                    if liveAgentController.isRunning {
                        Button(liveAgentController.isPaused ? "Resume" : "Pause") {
                            liveAgentController.togglePause()
                        }
                        .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))

                        Button("Stop") { liveAgentController.stop() }
                            .buttonStyle(SettingsPillButtonStyle(emphasis: .destructive))
                    } else {
                        Button("Run") { runLiveAgent() }
                            .buttonStyle(SettingsPillButtonStyle(emphasis: .filled))
                            .disabled(liveAgentPrompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let pending = liveAgentController.pendingAction {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(DS.Colors.warningText)
                            Text("Confirm: \(pending.summary)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        Text(pending.reason)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textSecondary)
                        HStack(spacing: 8) {
                            Button("Approve") { liveAgentController.approvePending() }
                                .buttonStyle(SettingsPillButtonStyle(emphasis: .filled))
                            Button("Deny") { liveAgentController.rejectPending() }
                                .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
                        }
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.warning.opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .strokeBorder(DS.Colors.warning.opacity(0.30), lineWidth: 1)
                    )
                }

                if liveAgentController.transcript.isEmpty {
                    Text("Transcript will appear here once the agent starts.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(liveAgentController.transcript) { entry in
                                liveAgentTranscriptRow(entry, accent: accent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(SettingsTheme.well)
                    )

                    HStack {
                        Spacer()
                        Button("Clear transcript") { liveAgentController.clearTranscript() }
                            .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
                    }
                }
            }
            .padding(14)
        }
    }

    private func runLiveAgent() {
        let trimmed = liveAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        liveAgentController.start(prompt: trimmed)
        liveAgentPrompt = ""
    }

    @ViewBuilder
    private func liveAgentTranscriptRow(_ entry: BlinkAgentLoopController.TranscriptEntry, accent: Color) -> some View {
        switch entry.kind {
        case .userPrompt:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "person.fill")
                    .foregroundColor(accent)
                    .font(.system(size: 11))
                Text(entry.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
            }
        case .assistantText:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(DS.Colors.info)
                    .font(.system(size: 11))
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .toolCall(let name, let argumentsJSON):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.adjustable.fill")
                        .foregroundColor(DS.Colors.textTertiary)
                        .font(.system(size: 10))
                    Text(name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(DS.Colors.codeText)
                }
                Text(argumentsJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(4)
            }
        case .toolResult(_, let status, let detail):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: status == "ok" ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundColor(status == "ok" ? DS.Colors.success : DS.Colors.destructiveText)
                    .font(.system(size: 10))
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
            }
        case .info:
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .italic()
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Colors.destructiveText)
                    .font(.system(size: 10))
                Text(entry.text)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private var nativeClickTesterGroup: some View {
        settingsGroup("Native click tester") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Direct mouse posting through Blink's signed Accessibility entitlement. Coordinates are top-left origin. Use this to verify clicks land where you expect before letting the agent drive them.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Coordinates")
                        .font(DS.Typography.label(11))
                        .foregroundColor(DS.Colors.textTertiary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                        spacing: 10
                    ) {
                        clickTesterCoordinateField(label: "X", text: $clickTesterX)
                        clickTesterCoordinateField(label: "Y", text: $clickTesterY)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(" ")
                                .font(.system(size: 10, weight: .semibold))
                            Button {
                                let location = NSEvent.mouseLocation
                                let height = NSScreen.screens.first?.frame.height ?? location.y
                                clickTesterX = String(Int(location.x))
                                clickTesterY = String(Int(height - location.y))
                            } label: {
                                Label("Use cursor", systemImage: "scope")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                        .fill(SettingsTheme.well)
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Actions")
                        .font(DS.Typography.label(11))
                        .foregroundColor(DS.Colors.textTertiary)

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                        spacing: 10
                    ) {
                        clickTesterAction("Move", systemImageName: "arrow.up.right") {
                            guard let point = parsedClickPoint() else {
                                throw BlinkComputerUseError.eventCreationFailed("Move needs valid x,y coordinates.")
                            }
                            try BlinkComputerUseMouseInput.move(to: point, smoothly: true)
                        }
                        clickTesterAction("Click", systemImageName: "cursorarrow.click") {
                            try BlinkComputerUseMouseInput.click(at: parsedClickPoint())
                        }
                        clickTesterAction("Double-click", systemImageName: "cursorarrow.click.2") {
                            try BlinkComputerUseMouseInput.click(at: parsedClickPoint(), clickCount: 2)
                        }
                        clickTesterAction("Right-click", systemImageName: "cursorarrow.and.square.on.square") {
                            try BlinkComputerUseMouseInput.click(at: parsedClickPoint(), button: .right)
                        }
                        clickTesterAction("Scroll up", systemImageName: "arrow.up") {
                            try BlinkComputerUseMouseInput.scroll(deltaX: 0, deltaY: 120)
                        }
                        clickTesterAction("Scroll down", systemImageName: "arrow.down") {
                            try BlinkComputerUseMouseInput.scroll(deltaX: 0, deltaY: -120)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: clickTesterStatus.hasPrefix("✗") ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(clickTesterStatus.hasPrefix("✗") ? DS.Colors.warningText : DS.Colors.textTertiary)
                    Text(clickTesterStatus)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(SettingsTheme.well)
                )
            }
            .padding(18)
        }
    }

    private func clickTesterCoordinateField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            SettingsTextField(placeholder: "0", text: text)
                .frame(maxWidth: .infinity)
        }
    }

    private func clickTesterAction(
        _ title: String,
        systemImageName: String,
        action: @escaping () throws -> Void
    ) -> some View {
        Button {
            do {
                try action()
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                clickTesterStatus = "✓ \(title) at \(stamp)"
            } catch {
                clickTesterStatus = "✗ \(title) failed: \(error.localizedDescription)"
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
    }

    private func parsedClickPoint() -> CGPoint? {
        guard let x = Double(clickTesterX.trimmingCharacters(in: .whitespaces)),
              let y = Double(clickTesterY.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(DS.Typography.heading(13))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.leading, 2)
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(SettingsTheme.raised)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .stroke(SettingsTheme.rule, lineWidth: 1)
            )
        }
    }

    private var settingsRowDivider: some View {
        Rectangle()
            .fill(SettingsTheme.rule)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    private func groupDescription(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsOptionColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func voiceRouteStep(title: String, value: String, systemImageName: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImageName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(settingsAccent)
                    .frame(width: 16)
                Text(title)
                    .font(DS.Typography.label(11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(SettingsTheme.well)
        )
    }

    private func toggleRow(title: String, subtitle: String, systemImageName: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(settingsAccent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func valueRow(title: String, subtitle: String, systemImageName: String, openPath: String? = nil) -> some View {
        HStack(spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer()
            if let openPath, !openPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settingsPathOpenButton(openPath)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func warningRow(title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(DS.Colors.warningText)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func textFieldRow(
        title: String,
        subtitle: String,
        systemImageName: String,
        placeholder: String,
        text: Binding<String>,
        openPath: (() -> String)? = nil
    ) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            HStack(spacing: 8) {
                SettingsTextField(placeholder: placeholder, text: text)
                if let openPath {
                    settingsPathOpenButton(openPath())
                }
            }
        }
    }

    private func secureFieldRow(title: String, subtitle: String, systemImageName: String, placeholder: String, text: Binding<String>) -> some View {
        editableFieldRow(title: title, subtitle: subtitle, systemImageName: systemImageName) {
            SettingsTextField(placeholder: placeholder, text: text, isSecure: true)
        }
    }

    private func editableFieldRow<Field: View>(
        title: String,
        subtitle: String,
        systemImageName: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            rowIcon(systemImageName)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                field()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func actionRow(title: String, systemImageName: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        SettingsActionRow(title: title, systemImageName: systemImageName, role: role, action: action)
    }

    private func settingsPathOpenButton(_ rawPath: String) -> some View {
        SettingsIconButton(systemImageName: settingsPathOpenIconName(for: rawPath)) {
            openSettingsPath(rawPath)
        }
        .help(settingsPathOpenHelpText(for: rawPath))
        .accessibilityLabel(settingsPathOpenHelpText(for: rawPath))
    }

    private func settingsPathOpenIconName(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        return "square.and.pencil"
    }

    private func settingsPathOpenHelpText(for rawPath: String) -> String {
        var isDirectory: ObjCBool = false
        let path = normalizedSettingsPath(rawPath)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "Open folder"
        }
        return "Open in TextEdit"
    }

    private func permissionRow(title: String, isGranted: Bool, settingsURL: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isGranted ? DS.Colors.success : DS.Colors.warningText)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(isGranted ? "Granted" : "Needs permission")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
            }
            Spacer()
            Button("Open Settings") {
                NSWorkspace.shared.open(settingsURL)
            }
            .buttonStyle(SettingsPillButtonStyle(emphasis: .soft))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func modelOptionGrid(
        options: [BlinkModelOption],
        selectedModelID: String,
        columns: Int = 2,
        select: @escaping (String) -> Void
    ) -> some View {
        LazyVGrid(columns: settingsOptionColumns(columns), spacing: 8) {
            ForEach(options) { option in
                optionButton(
                    title: option.label,
                    subtitle: option.provider.displayName,
                    isSelected: selectedModelID == option.id,
                    action: { select(option.id) }
                )
            }
        }
        .padding(14)
    }

    private func optionButton(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        SettingsOptionTile(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            accent: settingsAccent,
            action: action
        )
    }


    private var currentCursorAvatarStyle: BlinkCursorAvatarStyle {
        BlinkCursorAvatarStyle(storageValue: avatarStyleRawValue)
    }

    private func cursorColorButton(_ accentTheme: BlinkAccentTheme) -> some View {
        SettingsSelectableTile(
            label: accentTheme.title,
            isSelected: selectedAccentThemeID == accentTheme.rawValue,
            accent: accentTheme.cursorColor,
            action: { selectedAccentThemeID = accentTheme.rawValue }
        ) {
            ZStack {
                Circle()
                    .fill(accentTheme.cursorColor.opacity(0.18))
                Triangle()
                    .fill(accentTheme.cursorColor)
                    .frame(width: 18, height: 18)
                    .rotationEffect(.degrees(-25))
            }
            .frame(width: 44, height: 44)
        }
    }

    private func cursorAvatarButton(_ style: BlinkCursorAvatarStyle, label: String) -> some View {
        let accent = settingsAccent

        return SettingsSelectableTile(
            label: label,
            isSelected: currentCursorAvatarStyle == style,
            accent: accent,
            action: { avatarStyleRawValue = style.storageValue }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(SettingsTheme.hover)
                    .frame(width: 46, height: 46)

                switch style {
                case .triangleFilled:
                    // The glow mirrors how the real cursor renders on
                    // screen, so the preview stays honest.
                    Triangle()
                        .fill(accent)
                        .frame(width: 19, height: 19)
                        .rotationEffect(.degrees(-25))
                        .shadow(color: accent.opacity(0.55), radius: 7)
                case .triangleOutline:
                    Triangle()
                        .stroke(accent, lineWidth: 2.2)
                        .frame(width: 19, height: 19)
                        .rotationEffect(.degrees(-25))
                case .pet:
                    EmptyView()
                }
            }
        }
    }

    private func cursorPetButton(_ pet: BlinkBuddyPet) -> some View {
        let style = BlinkCursorAvatarStyle.pet(id: pet.id)

        return SettingsSelectableTile(
            label: pet.displayName,
            isSelected: currentCursorAvatarStyle == style,
            accent: settingsAccent,
            action: { avatarStyleRawValue = style.storageValue }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                    .fill(SettingsTheme.hover)
                    .frame(width: 46, height: 46)
                BlinkPetThumbnailView(pet: pet)
                    .frame(width: 34, height: 36)
            }
        }
        .help(pet.petDescription)
    }

    private var emptyPetLibraryTile: some View {
        VStack(spacing: 7) {
            Image(systemName: "pawprint")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No pets")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(SettingsTheme.well.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(SettingsTheme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private func rowIcon(_ systemImageName: String) -> some View {
        Image(systemName: systemImageName)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)
    }

    private func openFeedbackInbox() {
        guard let url = URL(string: "https://github.com/jasonca2023/blink/issues") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openMessageLog() {
        BlinkMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_message_log"
        )
        NSWorkspace.shared.open(BlinkMessageLogStore.shared.currentLogFile)
    }

    private func openLogsFolder() {
        BlinkMessageLogStore.shared.append(
            lane: "app",
            direction: "internal",
            event: "settings.open_logs_folder"
        )
        NSWorkspace.shared.open(BlinkMessageLogStore.shared.logDirectory)
    }
}

// MARK: - AgentParkingPositionPicker

/// A screen-shaped preview with eight tappable anchor points. Tapping
/// any dot selects that parking position and updates the binding.
struct AgentParkingPositionPicker: View {
    @Binding var selection: AgentParkingPosition
    var calibrationChanged: (AgentParkingPosition, CGSize) -> Void = { _, _ in }
    @State private var activeDragPosition: AgentParkingPosition?
    @State private var dragPreviewOffsets: [AgentParkingPosition: CGSize] = [:]

    private let dotSize: CGFloat = 18
    private let hitTargetSize: CGFloat = 36
    private let outlineColor = SettingsTheme.ruleStrong
    private let selectedColor = DS.Colors.overlayCursorBlue
    private let coordinateSpaceName = "AgentParkingPositionPreview"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where agents park")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Text("Pick where the agent dock parks, or drag a dot to fine-tune the corner.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)

            GeometryReader { proxy in
                let frame = previewRect(in: proxy.size)
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(outlineColor, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)

                    Rectangle()
                        .fill(outlineColor.opacity(0.25))
                        .frame(width: frame.width, height: 6)
                        .position(x: frame.midX, y: frame.minY + 3)

                    ForEach(AgentParkingPosition.allCases) { position in
                        let dotPosition = absolutePoint(for: position, in: frame)
                        Button {
                            selection = position
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.primary.opacity(0.001))
                                    .frame(width: hitTargetSize, height: hitTargetSize)

                                Circle()
                                    .fill(position == selection ? selectedColor : Color.clear)
                                    .overlay(
                                        Circle().stroke(
                                            position == selection ? selectedColor : outlineColor,
                                            lineWidth: position == selection ? 0 : 1.5
                                        )
                                    )
                                    .frame(width: dotSize, height: dotSize)

                                if position == selection || position == activeDragPosition {
                                    ParkingCornerDragIndicator(
                                        tint: position == activeDragPosition ? selectedColor : outlineColor.opacity(0.82),
                                        isActive: position == activeDragPosition
                                    )
                                }
                            }
                            .frame(width: hitTargetSize, height: hitTargetSize)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .position(x: dotPosition.x, y: dotPosition.y)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .named(coordinateSpaceName))
                                .onChanged { value in
                                    let clampedLocation = CGPoint(
                                        x: min(max(value.location.x, frame.minX), frame.maxX),
                                        y: min(max(value.location.y, frame.minY), frame.maxY)
                                    )
                                    let basePoint = baseAbsolutePoint(for: position, in: frame)
                                    let previewOffset = CGSize(
                                        width: clampedLocation.x - basePoint.x,
                                        height: clampedLocation.y - basePoint.y
                                    )
                                    selection = position
                                    activeDragPosition = position
                                    dragPreviewOffsets[position] = previewOffset
                                    calibrationChanged(
                                        position,
                                        screenOffset(from: previewOffset, previewFrame: frame)
                                    )
                                }
                                .onEnded { _ in
                                    activeDragPosition = nil
                                }
                        )
                    }
                }
                .coordinateSpace(name: coordinateSpaceName)
            }
            .frame(height: 176)
            .padding(.vertical, 6)

            Text(activeDragPosition == selection ? "\(selection.label) — drag to correct placement" : selection.label)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var mainScreenAspectRatio: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return 16.0 / 10.0
        }
        return frame.width / frame.height
    }

    private func previewRect(in size: CGSize) -> CGRect {
        let availableHeight = size.height
        let availableWidth = size.width
        let aspectRatio = mainScreenAspectRatio
        let widthFromHeight = availableHeight * aspectRatio
        let heightFromWidth = availableWidth / aspectRatio
        let width: CGFloat
        let height: CGFloat
        if widthFromHeight <= availableWidth {
            width = widthFromHeight
            height = availableHeight
        } else {
            width = availableWidth
            height = heightFromWidth
        }
        let originX = (availableWidth - width) / 2
        let originY = (availableHeight - height) / 2
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func absolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let basePoint = baseAbsolutePoint(for: position, in: frame)
        let previewOffset = dragPreviewOffsets[position]
            ?? previewOffset(from: AgentParkingPosition.calibrationOffset(for: position), previewFrame: frame)
        return CGPoint(
            x: min(max(basePoint.x + previewOffset.width, frame.minX), frame.maxX),
            y: min(max(basePoint.y + previewOffset.height, frame.minY), frame.maxY)
        )
    }

    private func baseAbsolutePoint(for position: AgentParkingPosition, in frame: CGRect) -> CGPoint {
        let anchor = position.normalizedAnchor
        return CGPoint(
            x: frame.minX + anchor.x * frame.width,
            y: frame.minY + anchor.y * frame.height
        )
    }

    private func previewOffset(from screenOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: screenOffset.width * frame.width / max(mainScreenSize.width, 1),
            height: -screenOffset.height * frame.height / max(mainScreenSize.height, 1)
        )
    }

    private func screenOffset(from previewOffset: CGSize, previewFrame frame: CGRect) -> CGSize {
        CGSize(
            width: previewOffset.width / max(frame.width, 1) * mainScreenSize.width,
            height: -previewOffset.height / max(frame.height, 1) * mainScreenSize.height
        )
    }

    private var mainScreenSize: CGSize {
        guard let frame = NSScreen.main?.frame, frame.width > 0, frame.height > 0 else {
            return CGSize(width: 1600, height: 1000)
        }
        return frame.size
    }
}

private struct ParkingCornerDragIndicator: View {
    let tint: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                ParkingCornerBracket()
                    .stroke(tint, style: StrokeStyle(lineWidth: isActive ? 2.2 : 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(Double(index) * 90))
                    .offset(x: index == 0 || index == 3 ? -13 : 13, y: index < 2 ? -13 : 13)
            }
        }
        .frame(width: 44, height: 44)
        .opacity(isActive ? 1 : 0.72)
    }
}

private struct ParkingCornerBracket: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

// MARK: - Settings components

private struct SettingsSidebarRow: View {
    let title: String
    let systemImageName: String
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImageName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 20)
                    .foregroundColor(isSelected ? accent : DS.Colors.textTertiary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? SettingsTheme.hover : (isHovered ? SettingsTheme.well : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .pointerCursor()
    }
}

private struct SettingsActionRow: View {
    let title: String
    let systemImageName: String
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovered = false

    private var isDestructive: Bool { role == .destructive }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImageName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isDestructive ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isDestructive ? DS.Colors.destructiveText : DS.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(isHovered ? SettingsTheme.well : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .pointerCursor()
    }
}

private struct SettingsOptionTile: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.12) : (isHovered ? SettingsTheme.hover : SettingsTheme.well))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .pointerCursor()
    }
}

private struct SettingsSelectableTile<Preview: View>: View {
    let label: String
    let isSelected: Bool
    let accent: Color
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.10) : (isHovered ? SettingsTheme.hover : SettingsTheme.well))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .pointerCursor()
    }
}

private struct SettingsIconButton: View {
    let systemImageName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(isHovered ? SettingsTheme.hover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
        .pointerCursor()
    }
}

private struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int>? = nil

    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        field
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.disabledText)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(SettingsTheme.well)
            )
            .overlay(
                // The focus ring appears instantly — never animated.
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(
                        isFocused ? BlinkAccentTheme.current.cursorColor : SettingsTheme.rule,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else if let lineLimit {
            TextField(placeholder, text: $text, axis: axis)
                .lineLimit(lineLimit)
        } else {
            TextField(placeholder, text: $text, axis: axis)
        }
    }
}

private struct SettingsPillButtonStyle: ButtonStyle {
    enum Emphasis {
        case filled
        case soft
        case destructive
    }

    var emphasis: Emphasis = .soft

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(labelColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(fillColor(isPressed: configuration.isPressed)))
            .overlay(Capsule().stroke(strokeColor, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .onHover { isHovered = isEnabled && $0 }
            .pointerCursor(isEnabled: isEnabled)
    }

    private var labelColor: Color {
        switch emphasis {
        case .filled:
            // The white accent theme needs dark text on its near-white fill.
            return BlinkAccentTheme.current == .white ? SettingsTheme.canvas : DS.Colors.textOnAccent
        case .soft:
            return DS.Colors.textPrimary
        case .destructive:
            return DS.Colors.destructiveText
        }
    }

    private func fillColor(isPressed: Bool) -> Color {
        switch emphasis {
        case .filled:
            let theme = BlinkAccentTheme.current
            if isPressed { return theme.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed) }
            return isHovered ? theme.accentHover : theme.accent
        case .soft:
            if isPressed { return SettingsTheme.pressed }
            return isHovered ? SettingsTheme.hover : SettingsTheme.well
        case .destructive:
            if isPressed { return DS.Colors.destructive.opacity(0.40) }
            return DS.Colors.destructive.opacity(isHovered ? 0.30 : 0.12)
        }
    }

    private var strokeColor: Color {
        switch emphasis {
        case .filled:
            return Color.clear
        case .soft:
            return isHovered ? SettingsTheme.ruleStrong : SettingsTheme.rule
        case .destructive:
            return DS.Colors.destructive.opacity(isHovered ? 0.45 : 0.25)
        }
    }
}
