import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC
import ScreenCaptureKit

/// Native CUA-style computer use embedded in Blink.
///
/// CUA source reference: /Users/blink/Documents/GitHub/cua/libs/cua-driver
/// License: MIT, Copyright (c) 2025 Cua AI, Inc.
///
/// Blink intentionally embeds the narrow, app-owned subset needed for
/// product runtime: app/window discovery, target-window capture, permission
/// readiness, and pid-directed keyboard input. Full MCP/trajectory/daemon
/// features stay out of the app bundle for now.
@MainActor
final class BlinkNativeComputerUseController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var status: BlinkComputerUseStatus
    @Published private(set) var lastWindowCapture: BlinkComputerUseWindowCapture?

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        let initialEnabled = userDefaults.bool(forKey: AppBundleConfiguration.userNativeComputerUseDefaultsKey)
        let initialStatus = BlinkNativeComputerUseController.makeStatus(
            enabled: initialEnabled,
            lastErrorMessage: nil
        )

        self.userDefaults = userDefaults
        self.isEnabled = initialEnabled
        self.status = initialStatus
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: AppBundleConfiguration.userNativeComputerUseDefaultsKey)
        refreshStatus()
    }

    func refreshStatus() {
        status = Self.makeStatus(enabled: isEnabled, lastErrorMessage: nil)
    }

    @discardableResult
    func refreshFocusedTarget() -> BlinkComputerUseWindowInfo? {
        let focusedWindow = BlinkComputerUseWindowEnumerator.frontmostTargetWindow()
        status = Self.makeStatus(
            enabled: isEnabled,
            focusedWindow: focusedWindow,
            lastErrorMessage: focusedWindow == nil ? BlinkComputerUseError.noTargetWindow.localizedDescription : nil
        )
        return focusedWindow
    }

    func runningApps() -> [BlinkComputerUseAppInfo] {
        BlinkComputerUseAppEnumerator.apps()
    }

    func visibleWindows() -> [BlinkComputerUseWindowInfo] {
        BlinkComputerUseWindowEnumerator.visibleWindows()
    }

    func allWindows() -> [BlinkComputerUseWindowInfo] {
        BlinkComputerUseWindowEnumerator.allWindows()
    }

    func captureFocusedWindowAsJPEG() async throws -> BlinkComputerUseWindowCapture {
        guard isEnabled else { throw BlinkComputerUseError.disabled }
        guard let targetWindow = refreshFocusedTarget() else { throw BlinkComputerUseError.noTargetWindow }

        do {
            let capture = try await BlinkComputerUseWindowCaptureUtility.capture(window: targetWindow)
            lastWindowCapture = capture
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: nil)
            return capture
        } catch let error as BlinkComputerUseError {
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: error.localizedDescription)
            throw error
        } catch {
            status = Self.makeStatus(enabled: true, focusedWindow: targetWindow, lastErrorMessage: error.localizedDescription)
            throw error
        }
    }

    func pressKey(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil) throws {
        guard isEnabled else { throw BlinkComputerUseError.disabled }
        BlinkApplicationUsageLogStore.shared.recordFrontmostApplication(source: "native_cua_key_press")
        try BlinkComputerUseKeyboardInput.press(key, modifiers: modifiers, toPid: pid)
    }

    func typeText(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
        guard isEnabled else { throw BlinkComputerUseError.disabled }
        BlinkApplicationUsageLogStore.shared.recordFrontmostApplication(source: "native_cua_text_input")
        try BlinkComputerUseKeyboardInput.typeCharacters(text, delayMilliseconds: delayMilliseconds, toPid: pid)
    }

    private static func makeStatus(
        enabled: Bool,
        focusedWindow: BlinkComputerUseWindowInfo? = nil,
        lastErrorMessage: String? = nil
    ) -> BlinkComputerUseStatus {
        let apps = BlinkComputerUseAppEnumerator.apps()
        let windows = BlinkComputerUseWindowEnumerator.visibleWindows()
        let resolvedFocusedWindow = focusedWindow ?? BlinkComputerUseWindowEnumerator.frontmostTargetWindow(from: windows)

        return BlinkComputerUseStatus(
            enabled: enabled,
            permissions: BlinkComputerUsePermissionProbe.status(),
            runningAppCount: apps.filter(\.running).count,
            visibleWindowCount: windows.count,
            focusedWindow: resolvedFocusedWindow,
            lastErrorMessage: lastErrorMessage
        )
    }
}

@MainActor
final class BlinkBackgroundComputerUseController: ObservableObject {
    @Published private(set) var status: BlinkBackgroundComputerUseStatus

    private let fileManager: FileManager
    private let sourceRootURL: URL
    private let installedAppURL: URL
    private let manifestURL: URL

    init(
        sourceRootURL: URL = URL(fileURLWithPath: "/Users/blink/Documents/GitHub/background-computer-use", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.sourceRootURL = sourceRootURL
        self.installedAppURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("BackgroundComputerUse.app", isDirectory: true)
        self.manifestURL = fileManager.temporaryDirectory
            .appendingPathComponent("background-computer-use", isDirectory: true)
            .appendingPathComponent("runtime-manifest.json", isDirectory: false)
        self.status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: false,
            lastErrorMessage: nil
        )
    }

    func refreshStatus() {
        status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: status.isStarting,
            lastErrorMessage: nil
        )
    }

    func startRuntime() {
        guard status.isStarting == false else { return }

        status = Self.makeStatus(
            sourceRootURL: sourceRootURL,
            installedAppURL: installedAppURL,
            manifestURL: manifestURL,
            fileManager: fileManager,
            isStarting: true,
            lastErrorMessage: nil
        )

        let sourceRootURL = sourceRootURL
        let installedAppURL = installedAppURL
        let manifestURL = manifestURL
        let fileManager = fileManager

        Task.detached(priority: .userInitiated) {
            let startScriptURL = sourceRootURL
                .appendingPathComponent("script", isDirectory: true)
                .appendingPathComponent("start.sh", isDirectory: false)
            let logDirectoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("background-computer-use", isDirectory: true)
            let launchLogURL = logDirectoryURL
                .appendingPathComponent("blink-launch.log", isDirectory: false)

            do {
                try fileManager.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)
                fileManager.createFile(atPath: launchLogURL.path, contents: nil)
                let logHandle = try FileHandle(forWritingTo: launchLogURL)
                defer {
                    try? logHandle.close()
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [startScriptURL.path]
                process.currentDirectoryURL = sourceRootURL
                process.standardOutput = logHandle
                process.standardError = logHandle
                try process.run()
                process.waitUntilExit()

                let launchError = process.terminationStatus == 0
                    ? nil
                    : "start.sh exited with status \(process.terminationStatus). See \(launchLogURL.path)"
                await MainActor.run {
                    self.status = Self.makeStatus(
                        sourceRootURL: sourceRootURL,
                        installedAppURL: installedAppURL,
                        manifestURL: manifestURL,
                        fileManager: fileManager,
                        isStarting: false,
                        lastErrorMessage: launchError
                    )
                }
            } catch {
                await MainActor.run {
                    self.status = Self.makeStatus(
                        sourceRootURL: sourceRootURL,
                        installedAppURL: installedAppURL,
                        manifestURL: manifestURL,
                        fileManager: fileManager,
                        isStarting: false,
                        lastErrorMessage: error.localizedDescription
                    )
                }
            }
        }
    }

    func captureFrontmostWindowAsJPEG() async throws -> BlinkBackgroundComputerUseWindowCapture {
        let target = try await resolveTargetWindow(appName: nil)
        let state = try await requestWindowState(windowID: target.windowID, imageMode: "path")

        guard let image = state.screenshot.image else {
            throw BlinkBackgroundComputerUseError.screenshotUnavailable(state.screenshot.captureError ?? "No screenshot image returned.")
        }

        let imageData: Data
        if let imageBase64 = image.imageBase64,
           let decoded = Data(base64Encoded: imageBase64) {
            imageData = decoded
        } else if let imagePath = image.imagePath {
            imageData = try Data(contentsOf: URL(fileURLWithPath: imagePath))
        } else {
            throw BlinkBackgroundComputerUseError.screenshotUnavailable("No screenshot path or base64 image returned.")
        }

        return BlinkBackgroundComputerUseWindowCapture(
            imageData: imageData,
            windowID: state.window.windowID,
            title: state.window.title,
            bundleID: state.window.bundleID,
            pid: state.window.pid,
            baseURL: try runtimeBaseURL().absoluteString,
            stateToken: state.stateToken,
            imagePath: image.imagePath,
            screenshotWidthInPixels: image.pixelWidth,
            screenshotHeightInPixels: image.pixelHeight
        )
    }

    func pressKey(_ key: String, modifiers: [String] = [], targetAppName: String? = nil) async throws -> BlinkBackgroundComputerUseActionResult {
        let target = try await resolveTargetWindow(appName: targetAppName)
        BlinkApplicationUsageLogStore.shared.recordApplication(
            name: targetAppName,
            bundleIdentifier: target.bundleID,
            source: "background_computer_use_key_press"
        )
        let chord = (modifiers + [key]).filter { !$0.isEmpty }.joined(separator: "+")
        let request = BlinkBackgroundComputerUsePressKeyRequest(
            window: target.windowID,
            key: chord,
            cursor: BlinkBackgroundComputerUseCursorRequest(
                id: "blink-main",
                name: "Blink",
                color: "#38BDF8"
            ),
            imageMode: "omit",
            debug: true
        )
        let response: BlinkBackgroundComputerUseActionResponse = try await postJSON(
            path: "/v1/press_key",
            payload: request
        )
        try ensureActionSucceeded(response, route: "press_key")
        return BlinkBackgroundComputerUseActionResult(
            windowID: target.windowID,
            summary: response.summary,
            ok: response.ok
        )
    }

    func typeText(_ text: String, targetAppName: String? = nil) async throws -> BlinkBackgroundComputerUseActionResult {
        let target = try await resolveTargetWindow(appName: targetAppName)
        BlinkApplicationUsageLogStore.shared.recordApplication(
            name: targetAppName,
            bundleIdentifier: target.bundleID,
            source: "background_computer_use_text_input"
        )
        let request = BlinkBackgroundComputerUseTypeTextRequest(
            window: target.windowID,
            text: text,
            focusAssistMode: "focus_and_caret_end",
            cursor: BlinkBackgroundComputerUseCursorRequest(
                id: "blink-main",
                name: "Blink",
                color: "#38BDF8"
            ),
            imageMode: "omit",
            debug: true
        )
        let response: BlinkBackgroundComputerUseActionResponse = try await postJSON(
            path: "/v1/type_text",
            payload: request
        )
        try ensureActionSucceeded(response, route: "type_text")
        return BlinkBackgroundComputerUseActionResult(
            windowID: target.windowID,
            summary: response.summary,
            ok: response.ok
        )
    }

    private func ensureActionSucceeded(_ response: BlinkBackgroundComputerUseActionResponse, route: String) throws {
        guard response.ok else {
            throw BlinkBackgroundComputerUseError.actionFailed(route: route, summary: response.summary)
        }
    }

    private func resolveTargetWindow(appName: String?) async throws -> BlinkBackgroundComputerUseWindow {
        let resolvedAppName: String
        if let appName, !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedAppName = appName
        } else if let nativeTarget = BlinkComputerUseWindowEnumerator.frontmostTargetWindow(),
                  !nativeTarget.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedAppName = nativeTarget.owner
        } else {
            let response: BlinkBackgroundComputerUseListAppsResponse = try await postJSON(
                path: "/v1/list_apps",
                payload: BlinkBackgroundComputerUseEmptyRequest()
            )
            guard let frontmost = response.frontmostApp else {
                throw BlinkBackgroundComputerUseError.noFrontmostApp
            }
            resolvedAppName = frontmost.name
        }

        let windowsResponse: BlinkBackgroundComputerUseListWindowsResponse = try await postJSON(
            path: "/v1/list_windows",
            payload: BlinkBackgroundComputerUseListWindowsRequest(app: resolvedAppName)
        )
        guard let window = windowsResponse.windows.first(where: { $0.isFocused && !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first(where: { $0.isMain && !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first(where: { !$0.isMinimized && $0.isOnScreen })
            ?? windowsResponse.windows.first else {
            throw BlinkBackgroundComputerUseError.noWindow(appName: resolvedAppName)
        }

        return window
    }

    private func requestWindowState(windowID: String, imageMode: String) async throws -> BlinkBackgroundComputerUseWindowStateResponse {
        try await postJSON(
            path: "/v1/get_window_state",
            payload: BlinkBackgroundComputerUseWindowStateRequest(
                window: windowID,
                maxNodes: 6500,
                imageMode: imageMode,
                includeRawScreenshot: false,
                debug: false
            )
        )
    }

    private func runtimeBaseURL() throws -> URL {
        refreshStatus()
        guard let baseURLString = status.baseURL,
              let baseURL = URL(string: baseURLString) else {
            throw BlinkBackgroundComputerUseError.runtimeUnavailable(status.summary)
        }

        return baseURL
    }

    private func postJSON<Request: Encodable, Response: Decodable>(
        path: String,
        payload: Request
    ) async throws -> Response {
        let baseURL = try runtimeBaseURL()
        let relativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: relativePath, relativeTo: baseURL)?.absoluteURL else {
            throw BlinkBackgroundComputerUseError.runtimeUnavailable("Invalid runtime path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw BlinkBackgroundComputerUseError.httpError(statusCode: httpResponse.statusCode, message: message)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            status = Self.makeStatus(
                sourceRootURL: sourceRootURL,
                installedAppURL: installedAppURL,
                manifestURL: manifestURL,
                fileManager: fileManager,
                isStarting: false,
                lastErrorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private static func makeStatus(
        sourceRootURL: URL,
        installedAppURL: URL,
        manifestURL: URL,
        fileManager: FileManager,
        isStarting: Bool,
        lastErrorMessage: String?
    ) -> BlinkBackgroundComputerUseStatus {
        let sourceAvailable = fileManager.fileExists(atPath: sourceRootURL.path)
        let startScriptURL = sourceRootURL
            .appendingPathComponent("script", isDirectory: true)
            .appendingPathComponent("start.sh", isDirectory: false)
        let startScriptAvailable = fileManager.fileExists(atPath: startScriptURL.path)
        let installedAppAvailable = fileManager.fileExists(atPath: installedAppURL.path)
        let manifestExists = fileManager.fileExists(atPath: manifestURL.path)
        let manifest = manifestExists
            ? try? JSONDecoder().decode(
                BlinkBackgroundComputerUseRuntimeManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            : nil

        return BlinkBackgroundComputerUseStatus(
            sourceRootPath: sourceRootURL.path,
            sourceAvailable: sourceAvailable,
            startScriptAvailable: startScriptAvailable,
            installedAppAvailable: installedAppAvailable,
            manifestPath: manifestURL.path,
            manifestExists: manifestExists,
            baseURL: manifest?.baseURL,
            startedAt: manifest?.startedAt,
            accessibilityGranted: manifest?.permissions.accessibility.granted,
            screenRecordingGranted: manifest?.permissions.screenRecording.granted,
            instructionsReady: manifest?.instructions.ready,
            instructionsSummary: manifest?.instructions.summary,
            isStarting: isStarting,
            lastErrorMessage: lastErrorMessage
        )
    }
}

struct BlinkBackgroundComputerUseActionResult: Sendable, Hashable {
    let windowID: String
    let summary: String
    let ok: Bool
}

enum BlinkBackgroundComputerUseError: Error, LocalizedError, Equatable {
    case runtimeUnavailable(String)
    case noFrontmostApp
    case noWindow(appName: String)
    case screenshotUnavailable(String)
    case actionFailed(route: String, summary: String)
    case httpError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let status):
            return "Background Computer Use runtime is unavailable: \(status)"
        case .noFrontmostApp:
            return "Background Computer Use could not resolve the frontmost app."
        case .noWindow(let appName):
            return "Background Computer Use could not resolve a target window for \(appName)."
        case .screenshotUnavailable(let reason):
            return "Background Computer Use screenshot unavailable: \(reason)"
        case .actionFailed(let route, let summary):
            return "Background Computer Use \(route) failed: \(summary)"
        case .httpError(let statusCode, let message):
            return "Background Computer Use HTTP \(statusCode): \(message)"
        }
    }
}

private struct BlinkBackgroundComputerUseRuntimeManifest: Decodable {
    let baseURL: String
    let startedAt: String?
    let permissions: BlinkBackgroundComputerUseRuntimePermissions
    let instructions: BlinkBackgroundComputerUseRuntimeInstructions
}

private struct BlinkBackgroundComputerUseRuntimePermissions: Decodable {
    let accessibility: BlinkBackgroundComputerUsePermission
    let screenRecording: BlinkBackgroundComputerUsePermission
}

private struct BlinkBackgroundComputerUsePermission: Decodable {
    let granted: Bool
}

private struct BlinkBackgroundComputerUseRuntimeInstructions: Decodable {
    let ready: Bool
    let summary: String
}

private struct BlinkBackgroundComputerUseEmptyRequest: Encodable {}

private struct BlinkBackgroundComputerUseListAppsResponse: Decodable {
    let frontmostApp: BlinkBackgroundComputerUseRunningApp?
    let runningApps: [BlinkBackgroundComputerUseRunningApp]
}

private struct BlinkBackgroundComputerUseRunningApp: Decodable {
    let name: String
    let bundleID: String
    let pid: Int32
    let isFrontmost: Bool
    let onscreenWindowCount: Int
}

private struct BlinkBackgroundComputerUseListWindowsRequest: Encodable {
    let app: String
}

private struct BlinkBackgroundComputerUseListWindowsResponse: Decodable {
    let windows: [BlinkBackgroundComputerUseWindow]
}

private struct BlinkBackgroundComputerUseWindow: Decodable, Sendable, Hashable {
    let windowID: String
    let title: String
    let bundleID: String
    let pid: Int32
    let isFocused: Bool
    let isMain: Bool
    let isMinimized: Bool
    let isOnScreen: Bool
}

private struct BlinkBackgroundComputerUseWindowStateRequest: Encodable {
    let window: String
    let maxNodes: Int
    let imageMode: String
    let includeRawScreenshot: Bool
    let debug: Bool
}

private struct BlinkBackgroundComputerUseWindowStateResponse: Decodable {
    let stateToken: String
    let window: BlinkBackgroundComputerUseResolvedWindow
    let screenshot: BlinkBackgroundComputerUseScreenshot
}

private struct BlinkBackgroundComputerUseResolvedWindow: Decodable, Sendable, Hashable {
    let windowID: String
    let title: String
    let bundleID: String
    let pid: Int32
}

private struct BlinkBackgroundComputerUseScreenshot: Decodable {
    let status: String
    let image: BlinkBackgroundComputerUseScreenshotImage?
    let captureError: String?
}

private struct BlinkBackgroundComputerUseScreenshotImage: Decodable {
    let imagePath: String?
    let imageBase64: String?
    let pixelWidth: Int
    let pixelHeight: Int
}

private struct BlinkBackgroundComputerUseCursorRequest: Encodable {
    let id: String
    let name: String
    let color: String
}

private struct BlinkBackgroundComputerUsePressKeyRequest: Encodable {
    let window: String
    let key: String
    let cursor: BlinkBackgroundComputerUseCursorRequest
    let imageMode: String
    let debug: Bool
}

private struct BlinkBackgroundComputerUseTypeTextRequest: Encodable {
    let window: String
    let text: String
    let focusAssistMode: String
    let cursor: BlinkBackgroundComputerUseCursorRequest
    let imageMode: String
    let debug: Bool

    enum CodingKeys: String, CodingKey {
        case window
        case text
        case focusAssistMode
        case cursor
        case imageMode
        case debug
    }
}

private struct BlinkBackgroundComputerUseActionResponse: Decodable {
    let ok: Bool
    let summary: String
}

@MainActor
enum BlinkComputerUsePermissionProbe {
    static func status() -> BlinkComputerUsePermissionStatus {
        BlinkComputerUsePermissionStatus(
            accessibilityGranted: AXIsProcessTrusted(),
            screenRecordingGranted: WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(),
            skyLightKeyboardPathAvailable: BlinkSkyLightEventPost.isAvailable,
            fullDiskAccessLikelyGranted: BlinkMacPrivacyPermissionProbe.hasLikelyFullDiskAccess()
        )
    }
}

enum BlinkMacPrivacyPermissionProbe {
    static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    static func hasLikelyFullDiskAccess(fileManager: FileManager = .default) -> Bool {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Messages/chat.db"),
            home.appendingPathComponent("Library/Safari/History.db"),
            home.appendingPathComponent("Library/Mail", isDirectory: true)
        ]

        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if canReadProtectedItem(candidate, fileManager: fileManager) {
                return true
            }
        }

        return false
    }

    private static func canReadProtectedItem(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            return (try? fileManager.contentsOfDirectory(atPath: url.path)) != nil
        }

        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        try? handle.close()
        return true
    }
}

enum BlinkComputerUseAppEnumerator {
    static func apps() -> [BlinkComputerUseAppInfo] {
        var byBundleId: [String: BlinkComputerUseAppInfo] = [:]
        var entries: [BlinkComputerUseAppInfo] = []

        func record(_ info: BlinkComputerUseAppInfo) {
            if let bundleId = info.bundleId, !bundleId.isEmpty {
                if byBundleId[bundleId] != nil { return }
                byBundleId[bundleId] = info
            }
            entries.append(info)
        }

        var seenPids = Set<Int32>()
        if let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            for window in windows {
                guard let rawPid = window[kCGWindowOwnerPID as String] as? Int,
                      let pid = Int32(exactly: rawPid),
                      !seenPids.contains(pid),
                      let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    continue
                }
                seenPids.insert(pid)
                record(runningInfo(app))
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard !seenPids.contains(pid) else { continue }
            seenPids.insert(pid)
            record(runningInfo(app))
        }

        for installed in installedApps() {
            if let bundleId = installed.bundleId, byBundleId[bundleId] != nil {
                continue
            }
            record(installed)
        }

        return entries
    }

    private static func runningInfo(_ app: NSRunningApplication) -> BlinkComputerUseAppInfo {
        BlinkComputerUseAppInfo(
            pid: app.processIdentifier,
            bundleId: app.bundleIdentifier,
            name: app.localizedName ?? "",
            running: true,
            active: app.isActive
        )
    }

    private static func installedApps() -> [BlinkComputerUseAppInfo] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "\(home)/Applications",
            "\(home)/Applications/Chrome Apps.localized",
            "/System/Applications",
            "/System/Applications/Utilities"
        ]

        return roots.flatMap { root -> [BlinkComputerUseAppInfo] in
            guard let children = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
            return children.compactMap { child in
                guard child.hasSuffix(".app") else { return nil }
                return infoFromBundle(at: "\(root)/\(child)")
            }
        }
    }

    private static func infoFromBundle(at path: String) -> BlinkComputerUseAppInfo? {
        guard let bundle = Bundle(path: path), let bundleId = bundle.bundleIdentifier else { return nil }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent

        return BlinkComputerUseAppInfo(
            pid: 0,
            bundleId: bundleId,
            name: name,
            running: false,
            active: false
        )
    }
}

enum BlinkComputerUseWindowEnumerator {
    static func visibleWindows() -> [BlinkComputerUseWindowInfo] {
        enumerate(options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    static func allWindows() -> [BlinkComputerUseWindowInfo] {
        enumerate(options: [.excludeDesktopElements])
    }

    static func frontmostTargetWindow(from windows: [BlinkComputerUseWindowInfo]? = nil) -> BlinkComputerUseWindowInfo? {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates = (windows ?? visibleWindows())
            .filter { $0.isOnScreen && $0.layer == 0 && $0.bounds.width > 100 && $0.bounds.height > 80 }
            .filter { window in
                guard let app = NSRunningApplication(processIdentifier: window.pid) else { return true }
                return app.bundleIdentifier != ownBundleIdentifier
            }

        if let frontmostBundleIdentifier, frontmostBundleIdentifier != ownBundleIdentifier {
            let focusedCandidates = candidates.filter { window in
                NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier == frontmostBundleIdentifier
            }
            if let focused = focusedCandidates.max(by: { $0.zIndex < $1.zIndex }) {
                return focused
            }
        }

        return candidates.max(by: { $0.zIndex < $1.zIndex })
    }

    private static func enumerate(options: CGWindowListOption) -> [BlinkComputerUseWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let total = rawWindows.count
        return rawWindows.enumerated().compactMap { index, entry in
            parse(entry, zIndex: total - index)
        }
    }

    private static func parse(_ entry: [String: Any], zIndex: Int) -> BlinkComputerUseWindowInfo? {
        guard let id = entry[kCGWindowNumber as String] as? Int,
              let pidValue = entry[kCGWindowOwnerPID as String] as? Int,
              let pid = Int32(exactly: pidValue),
              let boundsDictionary = entry[kCGWindowBounds as String] as? [String: Double] else {
            return nil
        }

        let bounds = BlinkComputerUseWindowBounds(
            x: boundsDictionary["X"] ?? 0,
            y: boundsDictionary["Y"] ?? 0,
            width: boundsDictionary["Width"] ?? 0,
            height: boundsDictionary["Height"] ?? 0
        )

        return BlinkComputerUseWindowInfo(
            id: id,
            pid: pid,
            owner: entry[kCGWindowOwnerName as String] as? String ?? "",
            name: entry[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            zIndex: zIndex,
            isOnScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
            layer: entry[kCGWindowLayer as String] as? Int ?? 0
        )
    }
}

enum BlinkComputerUseWindowCaptureUtility {
    @MainActor
    static func capture(window targetWindow: BlinkComputerUseWindowInfo) async throws -> BlinkComputerUseWindowCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screenCaptureWindow = content.windows.first(where: { Int($0.windowID) == targetWindow.id }) else {
            throw BlinkComputerUseError.windowCaptureUnavailable
        }

        let configuration = SCStreamConfiguration()
        let maxDimension = 1280
        let windowWidth = max(1, Int(screenCaptureWindow.frame.width))
        let windowHeight = max(1, Int(screenCaptureWindow.frame.height))
        let aspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)

        if windowWidth >= windowHeight {
            configuration.width = maxDimension
            configuration.height = max(1, Int(CGFloat(maxDimension) / aspectRatio))
        } else {
            configuration.height = maxDimension
            configuration.width = max(1, Int(CGFloat(maxDimension) * aspectRatio))
        }

        let filter = SCContentFilter(desktopIndependentWindow: screenCaptureWindow)
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let imageData = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw BlinkComputerUseError.imageEncodingFailed
        }

        return BlinkComputerUseWindowCapture(
            imageData: imageData,
            window: targetWindow,
            screenshotWidthInPixels: configuration.width,
            screenshotHeightInPixels: configuration.height
        )
    }
}

enum BlinkComputerUseKeyboardInput {
    static func press(_ key: String, modifiers: [String] = [], toPid pid: pid_t? = nil) throws {
        guard let code = virtualKeyCode(for: key) else {
            throw BlinkComputerUseError.unknownKey(key)
        }
        let flags = modifierMask(for: modifiers)
        try sendKey(code: code, down: true, flags: flags, toPid: pid)
        try sendKey(code: code, down: false, flags: flags, toPid: pid)
    }

    static func typeCharacters(_ text: String, delayMilliseconds: Int = 30, toPid pid: pid_t? = nil) throws {
        let clampedDelay = max(0, min(200, delayMilliseconds))
        for character in text {
            try sendUnicodeCharacter(character, toPid: pid)
            if clampedDelay > 0 {
                usleep(UInt32(clampedDelay) * 1_000)
            }
        }
    }

    private static func sendKey(code: Int, down: Bool, flags: CGEventFlags, toPid pid: pid_t?) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else {
            throw BlinkComputerUseError.eventCreationFailed("code=\(code) down=\(down)")
        }
        event.flags = flags
        post(event, toPid: pid)
    }

    private static func sendUnicodeCharacter(_ character: Character, toPid pid: pid_t?) throws {
        let utf16 = Array(String(character).utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else {
                throw BlinkComputerUseError.eventCreationFailed("unicode character \"\(character)\" down=\(keyDown)")
            }
            utf16.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                }
            }
            post(event, toPid: pid)
        }
    }

    private static func post(_ event: CGEvent, toPid pid: pid_t?) {
        if let pid {
            if !BlinkSkyLightEventPost.postToPid(pid, event: event) {
                event.postToPid(pid)
            }
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func modifierMask(for modifiers: [String]) -> CGEventFlags {
        var mask: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd", "command": mask.insert(.maskCommand)
            case "shift": mask.insert(.maskShift)
            case "option", "alt": mask.insert(.maskAlternate)
            case "ctrl", "control": mask.insert(.maskControl)
            case "fn": mask.insert(.maskSecondaryFn)
            default: break
            }
        }
        return mask
    }

    private static func virtualKeyCode(for name: String) -> Int? {
        let lowercasedName = name.lowercased()
        if let named = namedKeys[lowercasedName] { return named }
        guard lowercasedName.count == 1, let first = lowercasedName.first else { return nil }
        if let letter = letterKeys[first] { return letter }
        if let digit = digitKeys[first] { return digit }
        return nil
    }

    private static let namedKeys: [String: Int] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "backspace": 0x33,
        "forwarddelete": 0x75, "del": 0x75,
        "escape": 0x35, "esc": 0x35,
        "left": 0x7B, "leftarrow": 0x7B,
        "right": 0x7C, "rightarrow": 0x7C,
        "down": 0x7D, "downarrow": 0x7D,
        "up": 0x7E, "uparrow": 0x7E,
        "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pagedown": 0x79,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F
    ]

    private static let letterKeys: [Character: Int] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06
    ]

    private static let digitKeys: [Character: Int] = [
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15,
        "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19
    ]
}

/// Mouse primitives: move, click (left/right/middle, configurable click
/// count), and scroll. Posted at the HID event tap so the OS treats
/// them the same as physical input. Requires Accessibility permission.
enum BlinkComputerUseMouseInput {
    enum Button {
        case left, right, middle

        fileprivate var cg: CGMouseButton {
            switch self {
            case .left:   return .left
            case .right:  return .right
            case .middle: return .center
            }
        }

        fileprivate func eventTypes() -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
            switch self {
            case .left:
                return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
            case .right:
                return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
            case .middle:
                return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
            }
        }
    }

    /// Moves the cursor to `point`. When `smoothly` is true, the move is
    /// broken into ~20 steps over `durationMilliseconds` so the user can
    /// see where the cursor went (and Cocoa Auto Layout doesn't get
    /// surprised by a teleport).
    static func move(
        to point: CGPoint,
        smoothly: Bool = true,
        durationMilliseconds: Int = 240
    ) throws {
        if smoothly {
            let startLocation = NSEvent.mouseLocation
            let startPoint = CGPoint(
                x: startLocation.x,
                y: (NSScreen.screens.first?.frame.height ?? startLocation.y) - startLocation.y
            )
            let steps = max(2, min(60, durationMilliseconds / 12))
            let perStepDelayMicros = UInt32(max(1, durationMilliseconds * 1_000 / steps))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let eased = t * t * (3 - 2 * t)
                let intermediate = CGPoint(
                    x: startPoint.x + (point.x - startPoint.x) * eased,
                    y: startPoint.y + (point.y - startPoint.y) * eased
                )
                try postMouseMove(to: intermediate)
                usleep(perStepDelayMicros)
            }
        } else {
            try postMouseMove(to: point)
        }
    }

    /// Click at the given point. Omit `at` to click at the current cursor
    /// position. `clickCount = 2` performs a double-click.
    static func click(
        at point: CGPoint? = nil,
        button: Button = .left,
        clickCount: Int = 1
    ) throws {
        let targetPoint = try resolvedPoint(point)
        let types = button.eventTypes()
        let count = max(1, min(3, clickCount))

        for i in 0..<count {
            guard let down = CGEvent(
                mouseEventSource: nil,
                mouseType: types.down,
                mouseCursorPosition: targetPoint,
                mouseButton: button.cg
            ) else {
                throw BlinkComputerUseError.eventCreationFailed("mouse down at \(targetPoint)")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            down.post(tap: .cghidEventTap)

            guard let up = CGEvent(
                mouseEventSource: nil,
                mouseType: types.up,
                mouseCursorPosition: targetPoint,
                mouseButton: button.cg
            ) else {
                throw BlinkComputerUseError.eventCreationFailed("mouse up at \(targetPoint)")
            }
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i + 1))
            up.post(tap: .cghidEventTap)

            if i < count - 1 {
                usleep(80_000) // ~80ms between clicks in a multi-click sequence
            }
        }
    }

    /// Scroll wheel. Positive `deltaY` scrolls up (page moves down).
    static func scroll(deltaX: Int, deltaY: Int) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(deltaY),
            wheel2: Int32(deltaX),
            wheel3: 0
        ) else {
            throw BlinkComputerUseError.eventCreationFailed("scroll dx=\(deltaX) dy=\(deltaY)")
        }
        event.post(tap: .cghidEventTap)
    }

    private static func postMouseMove(to point: CGPoint) throws {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            throw BlinkComputerUseError.eventCreationFailed("mouse move to \(point)")
        }
        event.post(tap: .cghidEventTap)
    }

    private static func resolvedPoint(_ point: CGPoint?) throws -> CGPoint {
        if let point { return point }
        let location = NSEvent.mouseLocation
        let height = NSScreen.screens.first?.frame.height ?? location.y
        return CGPoint(x: location.x, y: height - location.y)
    }
}

enum BlinkSkyLightEventPost {
    private typealias PostToPidFn = @convention(c) (pid_t, CGEvent) -> Void
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void
    private typealias FactoryMsgSendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32) -> AnyObject?

    private struct Resolved {
        let postToPid: PostToPidFn
        let setAuthMessage: SetAuthMessageFn
        let msgSendFactory: FactoryMsgSendFn
        let messageClass: AnyClass
        let factorySelector: Selector
    }

    private static let resolved: Resolved? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        func resolve<T>(_ name: String, as _: T.Type) -> T? {
            guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        guard let postToPid = resolve("SLEventPostToPid", as: PostToPidFn.self),
              let setAuthMessage = resolve("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self),
              let msgSendFactory = resolve("objc_msgSend", as: FactoryMsgSendFn.self),
              let messageClass = NSClassFromString("SLSEventAuthenticationMessage") else {
            return nil
        }

        return Resolved(
            postToPid: postToPid,
            setAuthMessage: setAuthMessage,
            msgSendFactory: msgSendFactory,
            messageClass: messageClass,
            factorySelector: NSSelectorFromString("messageWithEventRecord:pid:version:")
        )
    }()

    static var isAvailable: Bool { resolved != nil }

    @discardableResult
    static func postToPid(_ pid: pid_t, event: CGEvent) -> Bool {
        guard let resolved else { return false }

        if let record = extractEventRecord(from: event),
           let message = resolved.msgSendFactory(
            resolved.messageClass as AnyObject,
            resolved.factorySelector,
            record,
            pid,
            0
           ) {
            resolved.setAuthMessage(event, message)
        }

        resolved.postToPid(pid, event)
        return true
    }

    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset).assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let record = slot.pointee { return record }
        }
        return nil
    }
}
