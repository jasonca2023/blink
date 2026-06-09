//
//  BlinkApp.swift
//  Blink
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import Carbon
import ServiceManagement
import SwiftUI
import Sparkle

@main
struct BlinkApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private static let sparkleFeedOverrideDefaultsKey = "BlinkSparkleFeedURLOverride"
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: if another Blink is already running, hand it
        // focus and quit before we install the event tap, menu bar item, or
        // login-item registration — two instances would fight over all three.
        if activateExistingInstanceAndQuitIfDuplicate() {
            return
        }

        print("Blink: Starting...")
        print("Blink: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        // Brief launch flourish — a click-through splash that animates Blink's
        // mark in and tears itself down. Non-blocking; the rest of setup runs
        // underneath it.
        BlinkStartupAnimationController.playOnLaunch()

        // Default in-app computer use ON so voice commands like "open
        // github.com" can drive the focused window without the user
        // having to flip a toggle in Settings on first launch. Also
        // default the TTS provider to the built-in system voice so
        // responses are audible without an ElevenLabs / Cartesia /
        // Deepgram key configured.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 0,
            AppBundleConfiguration.userNativeComputerUseDefaultsKey: true,
            AppBundleConfiguration.userTTSProviderDefaultsKey: BlinkTTSProvider.openAITTS.rawValue
        ])

        BlinkAnalytics.configure()
        BlinkAnalytics.trackAppOpened()
        BlinkDesktopNotificationCenter.shared.configure()

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        companionManager.publishWidgetSnapshot()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        // Blink development builds should also open visibly on launch even
        // if older UserDefaults say onboarding was already completed; otherwise
        // the LSUIElement app can appear to do nothing except add a menu bar icon.
        if BlinkRuntimeMode.isDevelopmentBuild
            || !companionManager.hasCompletedOnboarding
            || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        startSparkleUpdater()

        Task.detached(priority: .utility) {
            await BlinkSemanticIndex.shared.prepareIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { companionManager.handleWidgetDeepLink($0) }
    }

    /// Enforces a single running copy of Blink. Matches other instances by
    /// bundle identifier, so a build launched from Xcode/DerivedData and a copy
    /// in /Applications still count as one. When a duplicate is found, this
    /// process activates the existing instance and exits immediately, before any
    /// global setup runs. Returns true when this process is the duplicate.
    private func activateExistingInstanceAndQuitIfDuplicate() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.blink.blink"
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current && !$0.isTerminated }
        guard let existing = others.first else { return false }

        print("Blink: Another instance is already running — activating it and quitting.")
        existing.activate()
        exit(0)
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("Blink: Registered as login item")
            } catch {
                print("Blink: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.sparkleUpdaterController = updaterController

        if Self.sparkleFeedOverrideURLString() != nil {
            DispatchQueue.main.async {
                updaterController.updater.checkForUpdatesInBackground()
            }
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let override = Self.sparkleFeedOverrideURLString() else { return nil }
        print("Blink: Using Sparkle feed override: \(override)")
        return override
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.menuBarPanelManager?.showPanelOnLaunch()
        }
    }

    private static func sparkleFeedOverrideURLString() -> String? {
        let override = UserDefaults.standard.string(forKey: sparkleFeedOverrideDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty else { return nil }
        guard let url = URL(string: override),
              ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            print("Blink: Ignoring invalid Sparkle feed override: \(override)")
            return nil
        }

        if url.scheme?.lowercased() == "http" {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                print("Blink: Ignoring non-local HTTP Sparkle feed override: \(override)")
                return nil
            }
        }

        return override
    }
}
