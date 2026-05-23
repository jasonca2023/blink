//
//  BlinkAgentLoop.swift
//  Blink
//
//  Direct tool-use agent loop. User types or speaks a request, Claude
//  decides what to click, type, scroll, or open. Tools execute through
//  the same CGEvent primitives used by the click tester. Esc pauses
//  the loop; destructive actions surface a confirmation banner.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
final class BlinkAgentLoopController: ObservableObject {
    static let shared = BlinkAgentLoopController()

    struct TranscriptEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case userPrompt
            case assistantText
            case toolCall(name: String, argumentsJSON: String)
            case toolResult(name: String, status: String, detail: String)
            case info
            case error
        }
        let id = UUID()
        let kind: Kind
        let text: String
        let timestamp: Date = Date()
    }

    struct PendingAction: Equatable {
        let toolName: String
        let summary: String
        let reason: String
    }

    @Published private(set) var transcript: [TranscriptEntry] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var pendingAction: PendingAction?

    private let maxIterations = 16
    private let maxEmptyTurnNudges = 2
    private var currentTask: Task<Void, Never>?
    private var escMonitorGlobal: Any?
    private var escMonitorLocal: Any?
    private var confirmContinuation: CheckedContinuation<Bool, Never>?

    init() {
        installEscMonitor()
    }

    deinit {
        if let token = escMonitorGlobal { NSEvent.removeMonitor(token) }
        if let token = escMonitorLocal { NSEvent.removeMonitor(token) }
    }

    // MARK: - Public control

    func start(prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isRunning else { return }

        // Deterministic fast path: for unambiguous verbs (open X, search Y,
        // new tab, type Z, press cmd+...) run the canned plan directly so
        // the user never depends on the model remembering to call tools.
        if let plan = BlinkAgentIntentRouter.plan(for: trimmed), !plan.isEmpty {
            append(.init(kind: .userPrompt, text: trimmed))
            // Surface the resolved plan so the user can see if a misheard
            // word was corrected (e.g. "gethub" → "https://github.com").
            let summary = plan.map { step -> String in
                if step.name == "web_search", let q = step.input["query"] as? String {
                    return "web_search → \(q)"
                }
                if step.name == "open_app", let n = step.input["name"] as? String {
                    return "open_app → \(n)"
                }
                return step.name
            }.joined(separator: "; ")
            append(.init(kind: .info, text: "Plan: \(summary)"))
            isRunning = true
            currentTask = Task { [weak self] in
                await self?.runDeterministicPlan(plan)
                await MainActor.run {
                    self?.isRunning = false
                    self?.isPaused = false
                }
            }
            return
        }

        let backend = BlinkAgentBackendKind.current()
        let hfKey = AppBundleConfiguration.huggingFaceAPIKey()
        let anthropicKey = AppBundleConfiguration.anthropicAPIKey()
        let useHuggingFace = (backend == .huggingFace) || (anthropicKey?.isEmpty ?? true)

        if useHuggingFace {
            guard let key = hfKey, !key.isEmpty else {
                append(.init(kind: .error, text: "HuggingFace token missing. Add it under API Keys › Open source backend."))
                return
            }
            isPaused = false
            pendingAction = nil
            append(.init(kind: .userPrompt, text: trimmed))
            append(.init(kind: .info, text: "Using HuggingFace backend (\(BlinkAgentHuggingFaceConfig.model))."))
            isRunning = true

            currentTask = Task { [weak self] in
                await self?.runHFLoop(initialPrompt: trimmed, apiKey: key)
                await MainActor.run {
                    self?.isRunning = false
                    self?.isPaused = false
                }
            }
            return
        }

        guard let apiKey = anthropicKey, !apiKey.isEmpty else {
            append(.init(kind: .error, text: "Anthropic key missing. Add it under API Keys or switch Agent backend to HuggingFace."))
            return
        }

        isPaused = false
        pendingAction = nil
        append(.init(kind: .userPrompt, text: trimmed))
        append(.init(kind: .info, text: "Using Anthropic backend."))
        isRunning = true

        currentTask = Task { [weak self] in
            await self?.runLoop(initialPrompt: trimmed, apiKey: apiKey)
            await MainActor.run {
                self?.isRunning = false
                self?.isPaused = false
            }
        }
    }

    private func runDeterministicPlan(_ plan: [BlinkAgentToolStep]) async {
        for step in plan {
            await waitWhilePaused()
            if Task.isCancelled { return }

            let pretty = (try? JSONSerialization.data(withJSONObject: step.input, options: [.prettyPrinted, .sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            await MainActor.run {
                self.append(.init(kind: .toolCall(name: step.name, argumentsJSON: pretty), text: step.name))
            }

            let (status, detail) = await BlinkAgentToolExecutor.execute(name: step.name, input: step.input)
            await MainActor.run {
                self.append(.init(kind: .toolResult(name: step.name, status: status, detail: detail), text: step.name))
            }
            if status != "ok" {
                await MainActor.run {
                    self.append(.init(kind: .error, text: "Step \(step.name) failed — aborting plan."))
                }
                return
            }
        }
        await MainActor.run {
            self.append(.init(kind: .info, text: "Plan complete."))
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        if let cont = confirmContinuation {
            confirmContinuation = nil
            cont.resume(returning: false)
        }
        pendingAction = nil
        isRunning = false
        isPaused = false
        append(.init(kind: .info, text: "Stopped by user."))
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
        append(.init(kind: .info, text: isPaused ? "Paused. Click Resume to continue." : "Resumed."))
    }

    func approvePending() {
        guard let cont = confirmContinuation else { return }
        confirmContinuation = nil
        pendingAction = nil
        cont.resume(returning: true)
    }

    func rejectPending() {
        guard let cont = confirmContinuation else { return }
        confirmContinuation = nil
        pendingAction = nil
        cont.resume(returning: false)
    }

    func clearTranscript() {
        transcript.removeAll()
    }

    // MARK: - Loop

    private func runLoop(initialPrompt: String, apiKey: String) async {
        let api = ClaudeAPI(apiKey: apiKey, model: "claude-sonnet-4-6", maxOutputTokens: 4096)
        var messages: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": initialPrompt]]]
        ]
        var nudgesLeft = maxEmptyTurnNudges
        var anyToolExecuted = false

        for iteration in 0..<maxIterations {
            await waitWhilePaused()
            if Task.isCancelled { return }

            let response: ClaudeAPI.ToolTurnResult
            do {
                response = try await api.runToolTurn(
                    systemPrompt: Self.systemPrompt,
                    messages: messages,
                    tools: BlinkAgentToolCatalog.anthropicSchema
                )
            } catch {
                await MainActor.run {
                    self.append(.init(kind: .error, text: "Claude error: \(error.localizedDescription)"))
                }
                return
            }

            for block in response.contentBlocks {
                if let text = block["text"] as? String, !text.isEmpty {
                    await MainActor.run {
                        self.append(.init(kind: .assistantText, text: text))
                    }
                }
            }

            let toolUses = response.contentBlocks.filter { ($0["type"] as? String) == "tool_use" }
            if toolUses.isEmpty {
                if !anyToolExecuted && nudgesLeft > 0 {
                    nudgesLeft -= 1
                    messages.append(["role": "assistant", "content": response.contentBlocks])
                    messages.append(["role": "user", "content": [["type": "text", "text": Self.mustUseToolsNudge]]])
                    await MainActor.run {
                        self.append(.init(kind: .info, text: "Model didn't call any tool — nudging it to actually execute."))
                    }
                    continue
                }
                if !anyToolExecuted {
                    await MainActor.run {
                        self.append(.init(kind: .error, text: "Nothing was actually executed. The model refused to call any tool — its claim of completion is not real. Try rephrasing as a direct command (e.g. \"open Safari and search for X\")."))
                    }
                }
                return
            }
            anyToolExecuted = true

            messages.append(["role": "assistant", "content": response.contentBlocks])

            var toolResults: [[String: Any]] = []
            for use in toolUses {
                await waitWhilePaused()
                if Task.isCancelled { return }

                guard let name = use["name"] as? String,
                      let id = use["id"] as? String else { continue }
                let input = (use["input"] as? [String: Any]) ?? [:]

                await MainActor.run {
                    let pretty = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    self.append(.init(kind: .toolCall(name: name, argumentsJSON: pretty), text: name))
                }

                if let destructive = BlinkAgentToolCatalog.destructiveReason(for: name, input: input) {
                    let approved = await requestApproval(for: name, input: input, reason: destructive)
                    if !approved {
                        toolResults.append(Self.toolResultBlock(id: id, text: "User denied this action.", isError: true))
                        await MainActor.run {
                            self.append(.init(kind: .toolResult(name: name, status: "denied", detail: "User denied"), text: name))
                        }
                        continue
                    }
                }

                let (status, detail) = await BlinkAgentToolExecutor.execute(name: name, input: input)
                toolResults.append(Self.toolResultBlock(id: id, text: detail, isError: status != "ok"))
                await MainActor.run {
                    self.append(.init(kind: .toolResult(name: name, status: status, detail: detail), text: name))
                }
            }

            messages.append(["role": "user", "content": toolResults])
            _ = iteration
        }

        await MainActor.run {
            self.append(.init(kind: .info, text: "Stopped after \(self.maxIterations) iterations to avoid runaway loops."))
        }
    }

    private func waitWhilePaused() async {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - HuggingFace loop (OpenAI-compatible chat completions via HF router)

    private func runHFLoop(initialPrompt: String, apiKey: String) async {
        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": initialPrompt]
        ]
        let tools = BlinkAgentToolCatalog.openAIFunctionSchema
        var nudgesLeft = maxEmptyTurnNudges
        var anyToolExecuted = false

        for iteration in 0..<maxIterations {
            await waitWhilePaused()
            if Task.isCancelled { return }

            let response: BlinkHFChatTurnResult
            do {
                response = try await BlinkHFChatAPI.runToolTurn(
                    apiKey: apiKey,
                    model: BlinkAgentHuggingFaceConfig.model,
                    messages: messages,
                    tools: tools
                )
            } catch {
                self.append(.init(kind: .error, text: "HuggingFace error: \(error.localizedDescription)"))
                return
            }

            if let assistantText = response.assistantText, !assistantText.isEmpty {
                self.append(.init(kind: .assistantText, text: assistantText))
            }

            if let synthesized = response.synthesizedToolCalls, !synthesized.isEmpty {
                self.append(.init(kind: .info, text: "Model emitted tool calls in text — parsing \(synthesized.count) and executing."))
            }

            if response.toolCalls.isEmpty {
                if !anyToolExecuted && nudgesLeft > 0 {
                    nudgesLeft -= 1
                    messages.append([
                        "role": "assistant",
                        "content": response.assistantText ?? ""
                    ])
                    messages.append([
                        "role": "user",
                        "content": Self.mustUseToolsNudge
                    ])
                    self.append(.init(kind: .info, text: "Model didn't call any tool — nudging it to actually execute."))
                    continue
                }
                if !anyToolExecuted {
                    self.append(.init(kind: .error, text: "Nothing was actually executed. The model refused to call any tool — its claim of completion is not real. Try rephrasing as a direct command (e.g. \"open Safari and search for X\")."))
                }
                return
            }
            anyToolExecuted = true

            var assistantMessage: [String: Any] = [
                "role": "assistant",
                "content": response.assistantText ?? ""
            ]
            assistantMessage["tool_calls"] = response.toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.rawArgumentsJSON
                    ]
                ]
            }
            messages.append(assistantMessage)

            for call in response.toolCalls {
                await waitWhilePaused()
                if Task.isCancelled { return }

                let input = call.parsedArguments
                let pretty = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? call.rawArgumentsJSON
                self.append(.init(kind: .toolCall(name: call.name, argumentsJSON: pretty), text: call.name))

                if let destructive = BlinkAgentToolCatalog.destructiveReason(for: call.name, input: input) {
                    let approved = await requestApproval(for: call.name, input: input, reason: destructive)
                    if !approved {
                        messages.append([
                            "role": "tool",
                            "tool_call_id": call.id,
                            "content": "User denied this action."
                        ])
                        self.append(.init(kind: .toolResult(name: call.name, status: "denied", detail: "User denied"), text: call.name))
                        continue
                    }
                }

                let (status, detail) = await BlinkAgentToolExecutor.execute(name: call.name, input: input)
                messages.append([
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": "\(status): \(detail)"
                ])
                self.append(.init(kind: .toolResult(name: call.name, status: status, detail: detail), text: call.name))
            }
            _ = iteration
        }

        self.append(.init(kind: .info, text: "Stopped after \(self.maxIterations) iterations to avoid runaway loops."))
    }

    private func requestApproval(for name: String, input: [String: Any], reason: String) async -> Bool {
        await MainActor.run {
            self.pendingAction = PendingAction(
                toolName: name,
                summary: Self.summarize(name: name, input: input),
                reason: reason
            )
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.confirmContinuation = cont
        }
    }

    private func append(_ entry: TranscriptEntry) {
        transcript.append(entry)
        if transcript.count > 200 {
            transcript.removeFirst(transcript.count - 200)
        }
    }

    // MARK: - Esc kill switch

    private func installEscMonitor() {
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    guard self.isRunning else { return }
                    self.togglePause()
                }
            }
        }
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                Task { @MainActor in
                    guard self.isRunning else { return }
                    self.togglePause()
                }
            }
            return event
        }
    }

    // MARK: - Helpers

    private static func toolResultBlock(id: String, text: String, isError: Bool) -> [String: Any] {
        var block: [String: Any] = [
            "type": "tool_result",
            "tool_use_id": id,
            "content": text
        ]
        if isError { block["is_error"] = true }
        return block
    }

    private static func summarize(name: String, input: [String: Any]) -> String {
        switch name {
        case "click_at", "double_click_at", "right_click_at", "move_cursor":
            let x = input["x"] ?? "?"
            let y = input["y"] ?? "?"
            return "\(name) at (\(x), \(y))"
        case "click_button":
            let label = (input["label"] as? String) ?? "?"
            let app = (input["app"] as? String).map { " in \($0)" } ?? ""
            return "click_button: \"\(label)\"\(app)"
        case "inspect_ui":
            let query = (input["query"] as? String).map { " filter=\"\($0)\"" } ?? ""
            let app = (input["app"] as? String).map { " in \($0)" } ?? ""
            return "inspect_ui\(query)\(app)"
        case "type_text":
            let text = (input["text"] as? String) ?? ""
            return "type_text: \(text.prefix(80))"
        case "key_press":
            let key = (input["key"] as? String) ?? "?"
            let mods = (input["modifiers"] as? [String]) ?? []
            return mods.isEmpty ? "key_press: \(key)" : "key_press: \(mods.joined(separator: "+"))+\(key)"
        case "open_app":
            return "open_app: \((input["name"] as? String) ?? (input["bundle_id"] as? String) ?? "?")"
        case "scroll":
            return "scroll dx=\(input["dx"] ?? 0) dy=\(input["dy"] ?? 0)"
        default:
            return name
        }
    }

    private static let systemPrompt: String = """
You are Blink's agent. You control the user's Mac through the provided tools. You CANNOT do anything without calling a tool. Saying "I opened Safari" without calling open_app is a lie — every action requires a real tool call.

Hard rules:
- Never claim to have done something you did not perform via a tool call in this conversation.
- Do not output a final summary until at least one tool has actually executed and returned a result.
- If the user asks you to do something, your first response MUST contain one or more tool calls. Plain text without tool calls is only allowed after the task is fully completed via tools.

Workflow for clicking UI controls:
1. ALWAYS try click_button(label, app?) first — it finds the control by its real accessibility label, no pixels needed.
2. If click_button reports "no control matching", call inspect_ui(query?, app?) to list every clickable control on screen with its label and coordinates. Then call click_button again with the exact label you saw, or click_at with the listed coordinates.
3. NEVER call click_at with coordinates you invented. Coordinates must come from inspect_ui or from a real screenshot the user supplied. Guessed pixels = clicks on empty space.
4. Open apps with open_app when the user names one. open_app already waits for the app to be ready, so no extra wait_ms is needed unless typing into a freshly-opened sheet.
5. Type with type_text, press special keys with key_press.
6. Only after all needed tool calls complete should you write a one-line confirmation.

Preferred composites (use these instead of building keystroke chains by hand):
- web_search(query, browser?) — opens the browser at the URL or Google search. Use for ANY weather/news/lookup/"google it" request.
- new_tab() — cmd+t in the frontmost browser.
- click_button(label, app?) — clicks a UI control by its accessibility label. ALWAYS prefer this over click_at when the user names a control ("click Stop Sharing", "press Send", "hit OK", "start sharing screen"). Try multiple label phrasings if the first miss ("Share", "Share Screen", "Start Share").
- inspect_ui(query?, app?) — lists clickable controls (button, menu item, link, etc.) with their labels and center coordinates. Call this BEFORE clicking when you don't know what's on screen.

Concrete examples:
- "open Safari and check the weather in Tokyo":
    web_search(query="weather tokyo", browser="Safari") → done.
- "search for cute dogs":
    web_search(query="cute dogs") → done.
- "go to github.com":
    web_search(query="https://github.com") → done.
- "open Notes and write a todo":
    open_app(name="Notes") → wait_ms(ms=900) → key_press(key="n", modifiers=["cmd"]) → type_text(text="...") → done.

Safety:
- Refuse to send messages, delete data, quit apps, or modify files unless the user clearly asked.
- If a tool returns an error, explain and try one alternative or stop.
"""

    private static let mustUseToolsNudge: String = "You did not call any tool, so nothing has happened on the user's Mac yet. Do NOT claim completion. Re-read the user request and call the tool(s) needed to actually perform it now. Your reply must include tool_calls."
}

// MARK: - Tool catalog

enum BlinkAgentToolCatalog {
    static var anthropicSchema: [[String: Any]] {
        [
            [
                "name": "screenshot",
                "description": "Capture the focused window as a JPEG so you can see what's on screen. Returns a short description; the image is recorded for logging.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "move_cursor",
                "description": "Move the cursor to (x, y). Coordinates are top-left origin in screen pixels.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "click_at",
                "description": "Left-click at (x, y). Coordinates are top-left origin in screen pixels.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "double_click_at",
                "description": "Double left-click at (x, y).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "right_click_at",
                "description": "Right-click at (x, y).",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"]
                    ],
                    "required": ["x", "y"]
                ]
            ],
            [
                "name": "inspect_ui",
                "description": "Returns a list of every clickable UI control (button, menu item, checkbox, radio, link, pop-up, tab) currently on screen for the target app, with role, label, and center coordinates. Call this when you don't know what's on screen, when click_button missed, or before deciding which click_at coordinates to use. Optionally filter labels with 'query' (case-insensitive substring). Results are capped at 60 elements.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional substring filter on the visible label (case-insensitive)."],
                        "app": ["type": "string", "description": "Optional app display name or bundle id. Defaults to the frontmost non-Blink app."]
                    ]
                ]
            ],
            [
                "name": "click_button",
                "description": "Click a button (or any labelled UI control) by its accessibility label. Use this INSTEAD OF click_at whenever the user names a control — e.g. 'click Stop Sharing' in Zoom, 'click Send' in Messages, 'click OK' in a dialog. Searches the focused window's accessibility tree (and optionally a named app) for a matching role (button, menu item, checkbox, radio, link, pop-up, tab). Invokes the AX press action directly when supported, otherwise clicks the element's center. Match is case-insensitive and accepts substrings.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "label": ["type": "string", "description": "The visible label/title/description of the control, e.g. 'Stop Sharing', 'Send', 'OK'."],
                        "app": ["type": "string", "description": "Optional app display name or bundle id to search inside (e.g. 'zoom.us'). Defaults to the frontmost non-Blink app."],
                        "role": ["type": "string", "description": "Optional AX role hint: 'button', 'menu_item', 'checkbox', 'radio', 'link', 'popup', 'tab'. Leave blank to accept any clickable role."]
                    ],
                    "required": ["label"]
                ]
            ],
            [
                "name": "scroll",
                "description": "Scroll the wheel. dy>0 scrolls up (content moves down). Magnitudes around 120 are one notch.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "dx": ["type": "integer", "default": 0],
                        "dy": ["type": "integer", "default": 0]
                    ]
                ]
            ],
            [
                "name": "type_text",
                "description": "Type unicode text into the focused app. Use for arbitrary text input.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "key_press",
                "description": "Press a key, optionally with modifiers. Key examples: return, tab, escape, delete, left, right, up, down, space, a-z, 0-9, f1-f12. Modifiers: cmd, shift, option, ctrl.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "key": ["type": "string"],
                        "modifiers": [
                            "type": "array",
                            "items": ["type": "string"]
                        ]
                    ],
                    "required": ["key"]
                ]
            ],
            [
                "name": "open_app",
                "description": "Launch or activate a macOS application by display name or bundle id. Blocks until the app is frontmost, finished launching, and has a visible window (up to 10s) — so no extra wait_ms is needed before the next action.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Display name like 'Safari' or 'Notes'."],
                        "bundle_id": ["type": "string", "description": "Bundle id like 'com.apple.Safari'."]
                    ]
                ]
            ],
            [
                "name": "wait_for_app",
                "description": "Poll until the named app is frontmost, finished launching, and has a visible window. Use when you switched apps via clicks/keystrokes and need to wait for the new app before continuing.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "bundle_id": ["type": "string"],
                        "timeout_ms": ["type": "integer", "description": "Max wait, default 8000, capped at 15000."]
                    ]
                ]
            ],
            [
                "name": "list_running_apps",
                "description": "Return the bundle ids and display names of currently running applications.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "focused_window",
                "description": "Return the frontmost non-Blink window's owner, title, and bounds.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "wait_ms",
                "description": "Sleep for the given number of milliseconds, max 3000. Useful after launching an app.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "ms": ["type": "integer"]
                    ],
                    "required": ["ms"]
                ]
            ],
            [
                "name": "web_search",
                "description": "Open a URL or search query in a browser. URLs are opened directly via NSWorkspace (no keystroke typing, no autocomplete races). Plain text becomes a Google search URL. Use for ANY web lookup, weather check, news, or 'google it' style request. Pass the optional 'browser' to target a specific one; otherwise the user's default browser is used.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "The search query OR a full URL (https://...)."],
                        "browser": ["type": "string", "description": "Optional: 'Safari', 'Google Chrome', 'Arc', 'Firefox'. Defaults to Safari."]
                    ],
                    "required": ["query"]
                ]
            ],
            [
                "name": "new_tab",
                "description": "Open a new tab in the frontmost browser (cmd+t). Use this when the user says 'new tab'.",
                "input_schema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    /// OpenAI-compatible function-tool schema. Used by the HF router
    /// chat-completions endpoint and any OpenAI-compatible backend.
    static var openAIFunctionSchema: [[String: Any]] {
        anthropicSchema.map { tool -> [String: Any] in
            let name = (tool["name"] as? String) ?? ""
            let description = (tool["description"] as? String) ?? ""
            let parameters = (tool["input_schema"] as? [String: Any])
                ?? ["type": "object", "properties": [:]]
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": description,
                    "parameters": parameters
                ]
            ]
        }
    }

    /// Returns a non-nil reason when the action should require user
    /// confirmation before running.
    static func destructiveReason(for name: String, input: [String: Any]) -> String? {
        switch name {
        case "key_press":
            let key = ((input["key"] as? String) ?? "").lowercased()
            let mods = ((input["modifiers"] as? [String]) ?? []).map { $0.lowercased() }
            let hasCmd = mods.contains("cmd") || mods.contains("command")
            if hasCmd && ["q", "w", "delete", "backspace"].contains(key) {
                return "Command+\(key) can close or quit the focused app."
            }
            if hasCmd && key == "z" && mods.contains("shift") {
                return "Cmd+Shift+Z can redo destructive edits."
            }
            return nil
        case "type_text":
            let text = ((input["text"] as? String) ?? "").lowercased()
            let triggers = ["rm -rf", "sudo rm", "drop table", "delete account", "format disk"]
            if triggers.contains(where: { text.contains($0) }) {
                return "The text contains a destructive command."
            }
            return nil
        case "open_app":
            let name = ((input["name"] as? String) ?? "").lowercased()
            let bundle = ((input["bundle_id"] as? String) ?? "").lowercased()
            if name.contains("terminal") || bundle == "com.apple.terminal" {
                return "Opening Terminal can run arbitrary commands."
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Tool executor

enum BlinkAgentToolExecutor {
    /// Returns (status, detail). status is "ok" on success or an error label otherwise.
    static func execute(name: String, input: [String: Any]) async -> (status: String, detail: String) {
        switch name {
        case "screenshot":
            return await screenshot()
        case "move_cursor":
            return mouseAction(name: name, input: input) { point in
                try BlinkComputerUseMouseInput.move(to: point, smoothly: true)
                return "Cursor moved to (\(Int(point.x)), \(Int(point.y)))."
            }
        case "click_at":
            return mouseAction(name: name, input: input) { point in
                try BlinkComputerUseMouseInput.move(to: point, smoothly: true)
                try BlinkComputerUseMouseInput.click(at: point)
                return "Clicked at (\(Int(point.x)), \(Int(point.y)))."
            }
        case "double_click_at":
            return mouseAction(name: name, input: input) { point in
                try BlinkComputerUseMouseInput.move(to: point, smoothly: true)
                try BlinkComputerUseMouseInput.click(at: point, clickCount: 2)
                return "Double-clicked at (\(Int(point.x)), \(Int(point.y)))."
            }
        case "right_click_at":
            return mouseAction(name: name, input: input) { point in
                try BlinkComputerUseMouseInput.move(to: point, smoothly: true)
                try BlinkComputerUseMouseInput.click(at: point, button: .right)
                return "Right-clicked at (\(Int(point.x)), \(Int(point.y)))."
            }
        case "click_button":
            return await clickButton(input: input)
        case "inspect_ui":
            return await inspectUI(input: input)
        case "scroll":
            let dx = (input["dx"] as? Int) ?? Int((input["dx"] as? Double) ?? 0)
            let dy = (input["dy"] as? Int) ?? Int((input["dy"] as? Double) ?? 0)
            do {
                try BlinkComputerUseMouseInput.scroll(deltaX: dx, deltaY: dy)
                return ("ok", "Scrolled dx=\(dx) dy=\(dy).")
            } catch {
                return ("error", error.localizedDescription)
            }
        case "type_text":
            guard let text = input["text"] as? String, !text.isEmpty else {
                return ("error", "Missing 'text'.")
            }
            do {
                try BlinkComputerUseKeyboardInput.typeCharacters(text, delayMilliseconds: 12)
                return ("ok", "Typed \(text.count) characters.")
            } catch {
                return ("error", error.localizedDescription)
            }
        case "key_press":
            guard let key = input["key"] as? String, !key.isEmpty else {
                return ("error", "Missing 'key'.")
            }
            let modifiers = (input["modifiers"] as? [String]) ?? []
            do {
                try BlinkComputerUseKeyboardInput.press(key, modifiers: modifiers)
                let modSummary = modifiers.isEmpty ? key : modifiers.joined(separator: "+") + "+" + key
                return ("ok", "Pressed \(modSummary).")
            } catch {
                return ("error", error.localizedDescription)
            }
        case "open_app":
            return await openApp(input: input)
        case "wait_for_app":
            return await waitForApp(input: input)
        case "list_running_apps":
            let apps = await MainActor.run { BlinkComputerUseAppEnumerator.apps() }
            let lines = apps.prefix(80).map { "\($0.name) — \($0.bundleId ?? "?")" }
            return ("ok", lines.joined(separator: "\n"))
        case "focused_window":
            let window = await MainActor.run { BlinkComputerUseWindowEnumerator.frontmostTargetWindow() }
            if let window {
                let bounds = "x=\(Int(window.bounds.x)) y=\(Int(window.bounds.y)) w=\(Int(window.bounds.width)) h=\(Int(window.bounds.height))"
                return ("ok", "owner=\(window.owner) title=\(window.name) \(bounds)")
            } else {
                return ("error", "No non-Blink window is focused.")
            }
        case "wait_ms":
            let ms = min(3000, max(0, (input["ms"] as? Int) ?? Int((input["ms"] as? Double) ?? 0)))
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return ("ok", "Waited \(ms) ms.")
        case "web_search":
            return await webSearch(input: input)
        case "new_tab":
            do {
                try BlinkComputerUseKeyboardInput.press("t", modifiers: ["cmd"])
                return ("ok", "Opened a new tab (cmd+t).")
            } catch {
                return ("error", error.localizedDescription)
            }
        default:
            return ("error", "Unknown tool: \(name)")
        }
    }

    private static func webSearch(input: [String: Any]) async -> (status: String, detail: String) {
        guard let queryRawIn = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !queryRawIn.isEmpty else {
            return ("error", "web_search requires 'query'.")
        }
        // Last-mile correction: rewrite misheard URLs/aliases ("gethub.com"
        // → github.com, "gethub" → github.com) before constructing the URL.
        let resolved = BlinkAgentIntentRouter.canonicalizeQueryIfPossible(queryRawIn)
        let browserHint = (input["browser"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the URL deterministically. URL queries open the page;
        // free-text queries become a Google search URL. We then hand the
        // URL to the browser via NSWorkspace — no typing into the address
        // bar, so Safari's autocomplete/history can't intercept and route
        // us to a stale "gethub.com" suggestion.
        let target = makeTargetURL(from: resolved)
        let urlString = target.absoluteString

        let opened = await MainActor.run { () -> (status: String, detail: String) in
            let workspace = NSWorkspace.shared
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            if let hint = browserHint, !hint.isEmpty {
                let appBundleName = hint.hasSuffix(".app") ? hint : hint + ".app"
                let home = FileManager.default.homeDirectoryForCurrentUser
                let candidates = [
                    "/Applications/\(appBundleName)",
                    "/System/Applications/\(appBundleName)",
                    home.appendingPathComponent("Applications/\(appBundleName)").path
                ]
                if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    workspace.open([target], withApplicationAt: URL(fileURLWithPath: path), configuration: config) { _, _ in }
                    return ("ok", "Opened \(urlString) in \(hint).")
                }
                // Browser hint didn't resolve — fall through to default.
            }
            // Use the user's default browser (or whatever the system maps
            // http URLs to). Safari is the macOS fallback if none set.
            workspace.open(target)
            return ("ok", "Opened \(urlString) in default browser.")
        }
        return opened
    }

    /// Convert a router-resolved query into the URL to open. URL-shaped
    /// inputs pass through (scheme added if missing); free text becomes a
    /// Google search URL. Anything we can't parse falls back to a search.
    private static func makeTargetURL(from query: String) -> URL {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://"),
           let url = URL(string: trimmed) {
            return url
        }
        // Looks like a bare domain (e.g. "github.com" or "github.com/foo").
        if trimmed.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}(?:/.*)?$"#,
                         options: .regularExpression) != nil,
           let url = URL(string: "https://\(trimmed)") {
            return url
        }
        // Free text — search Google.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://www.google.com/search?q=\(encoded)") ?? URL(string: "https://www.google.com")!
    }

    private static func mouseAction(
        name: String,
        input: [String: Any],
        _ body: (CGPoint) throws -> String
    ) -> (status: String, detail: String) {
        guard let x = (input["x"] as? Double) ?? (input["x"] as? Int).map(Double.init),
              let y = (input["y"] as? Double) ?? (input["y"] as? Int).map(Double.init) else {
            return ("error", "\(name) requires numeric x and y.")
        }
        do {
            let summary = try body(CGPoint(x: x, y: y))
            return ("ok", summary)
        } catch {
            return ("error", error.localizedDescription)
        }
    }

    /// Result of launching an app — includes the PID so callers can route
    /// keystrokes directly to the process and bypass the frontmost-app focus
    /// race.
    struct LaunchResult {
        let status: String
        let detail: String
        let pid: pid_t?
    }

    /// Launch (or activate) the app, then block until it's actually
    /// frontmost, finished launching, and has at least one window.
    static func launchAndAwaitReady(input: [String: Any]) async -> LaunchResult {
        let launch = await MainActor.run { () -> (status: String, detail: String, identifier: String?) in
            let workspace = NSWorkspace.shared
            if let bundleID = (input["bundle_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty {
                if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                    workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                    return ("ok", "Launched \(bundleID).", bundleID)
                }
                return ("error", "No installed app with bundle id \(bundleID).", nil)
            }
            guard let name = (input["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return ("error", "open_app requires 'name' or 'bundle_id'.", nil)
            }
            let appBundleName = name.hasSuffix(".app") ? name : name + ".app"
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidates = [
                "/Applications/\(appBundleName)",
                "/System/Applications/\(appBundleName)",
                "/System/Applications/Utilities/\(appBundleName)",
                home.appendingPathComponent("Applications/\(appBundleName)").path
            ]
            for path in candidates where FileManager.default.fileExists(atPath: path) {
                workspace.openApplication(
                    at: URL(fileURLWithPath: path),
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
                return ("ok", "Launched \(name).", name)
            }
            if let running = workspace.runningApplications.first(where: {
                ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
            }) {
                running.activate(options: [.activateAllWindows])
                return ("ok", "Activated \(name).", name)
            }
            return ("error", "Could not find an app named \(name).", nil)
        }

        guard launch.status == "ok", let identifier = launch.identifier else {
            return LaunchResult(status: launch.status, detail: launch.detail, pid: nil)
        }

        let ready = await waitUntilAppReady(identifier: identifier, timeoutMs: 12_000)
        // After readiness signals, give the app a beat to actually finish
        // wiring up its first responder. Safari in particular reports the
        // window as visible ~300 ms before the omnibox can accept focus.
        try? await Task.sleep(nanoseconds: 700_000_000)

        if ready.isReady {
            return LaunchResult(
                status: "ok",
                detail: "\(launch.detail) Ready after \(ready.elapsedMs) ms (frontmost with window).",
                pid: ready.pid
            )
        } else {
            return LaunchResult(
                status: "ok",
                detail: "\(launch.detail) Launch dispatched but readiness check timed out after \(ready.elapsedMs) ms — \(ready.reason). Proceeding anyway.",
                pid: ready.pid
            )
        }
    }

    private static func openApp(input: [String: Any]) async -> (status: String, detail: String) {
        let result = await launchAndAwaitReady(input: input)
        return (result.status, result.detail)
    }

    /// Standalone tool the agent can call to wait for any app to be ready
    /// without re-launching it.
    private static func waitForApp(input: [String: Any]) async -> (status: String, detail: String) {
        guard let identifier = ((input["name"] as? String) ?? (input["bundle_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            return ("error", "wait_for_app requires 'name' or 'bundle_id'.")
        }
        let timeoutMs = min(15_000, max(500, (input["timeout_ms"] as? Int) ?? Int((input["timeout_ms"] as? Double) ?? 8_000)))
        let result = await waitUntilAppReady(identifier: identifier, timeoutMs: timeoutMs)
        if result.isReady {
            return ("ok", "\(identifier) ready after \(result.elapsedMs) ms.")
        } else {
            return ("error", "\(identifier) not ready after \(result.elapsedMs) ms — \(result.reason).")
        }
    }

    private struct AppReadinessResult {
        let isReady: Bool
        let elapsedMs: Int
        let reason: String
        let pid: pid_t?
    }

    /// Polls every 100 ms (up to `timeoutMs`) until the named/bundle-id'd app:
    ///   1. Has an NSRunningApplication entry
    ///   2. Reports isFinishedLaunching == true
    ///   3. Is the frontmost app
    ///   4. Has at least one on-screen window owned by it
    /// `identifier` can be a localized name or a bundle id.
    private static func waitUntilAppReady(identifier: String, timeoutMs: Int) async -> AppReadinessResult {
        let start = Date()
        let deadline = start.addingTimeInterval(Double(timeoutMs) / 1000.0)
        let lowerIdent = identifier.lowercased()

        var lastReason = "did not become ready"

        while Date() < deadline {
            let snapshot = await MainActor.run { () -> (running: NSRunningApplication?, isFrontmost: Bool, hasWindow: Bool, reason: String) in
                let workspace = NSWorkspace.shared
                let running = workspace.runningApplications.first { app in
                    if let bid = app.bundleIdentifier?.lowercased(), bid == lowerIdent { return true }
                    if let name = app.localizedName, name.caseInsensitiveCompare(identifier) == .orderedSame { return true }
                    return false
                }
                guard let app = running else {
                    return (nil, false, false, "app not yet in NSRunningApplications")
                }
                if !app.isFinishedLaunching {
                    return (app, false, false, "isFinishedLaunching is false")
                }
                let isFrontmost = workspace.frontmostApplication?.processIdentifier == app.processIdentifier
                if !isFrontmost {
                    return (app, false, false, "not frontmost")
                }
                let windows = BlinkComputerUseWindowEnumerator.visibleWindows()
                let hasWindow = windows.contains { $0.pid == app.processIdentifier }
                if !hasWindow {
                    return (app, true, false, "no visible window owned by this app yet")
                }
                return (app, true, true, "ready")
            }

            if let app = snapshot.running, snapshot.isFrontmost && snapshot.hasWindow {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return AppReadinessResult(isReady: true, elapsedMs: elapsed, reason: "ready", pid: app.processIdentifier)
            }
            lastReason = snapshot.reason
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let elapsed = Int(Date().timeIntervalSince(start) * 1000)
        let pid = await MainActor.run {
            NSWorkspace.shared.runningApplications.first {
                if let bid = $0.bundleIdentifier?.lowercased(), bid == lowerIdent { return true }
                if let name = $0.localizedName, name.caseInsensitiveCompare(identifier) == .orderedSame { return true }
                return false
            }?.processIdentifier
        }
        return AppReadinessResult(isReady: false, elapsedMs: elapsed, reason: lastReason, pid: pid)
    }

    private static func inspectUI(input: [String: Any]) async -> (status: String, detail: String) {
        let appHint = (input["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let resolved = await MainActor.run { () -> (pid: pid_t?, appName: String) in
            BlinkAgentAccessibilityClicker.resolveTargetPID(appHint: appHint)
        }
        guard let pid = resolved.pid else {
            return ("error", "No target app found\(appHint.map { " for '\($0)'" } ?? "") and no non-Blink frontmost app.")
        }

        let elements = await MainActor.run { () -> [BlinkAgentAccessibilityClicker.InspectedElement] in
            BlinkAgentAccessibilityClicker.inspect(pid: pid, query: query, limit: 60)
        }

        if elements.isEmpty {
            let suffix = query.map { " matching '\($0)'" } ?? ""
            return ("ok", "No clickable controls\(suffix) in \(resolved.appName). The app may not expose Accessibility info, or you may need to call screenshot to see the layout.")
        }

        var lines: [String] = ["\(elements.count) clickable control(s) in \(resolved.appName):"]
        for element in elements {
            lines.append("- \(element.role) \"\(element.label)\" @ (\(Int(element.center.x)), \(Int(element.center.y)))")
        }
        return ("ok", lines.joined(separator: "\n"))
    }

    private static func clickButton(input: [String: Any]) async -> (status: String, detail: String) {
        guard let labelRaw = (input["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !labelRaw.isEmpty else {
            return ("error", "click_button requires 'label'.")
        }
        let appHint = (input["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let roleHint = (input["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let resolved = await MainActor.run { () -> (pid: pid_t?, appName: String) in
            BlinkAgentAccessibilityClicker.resolveTargetPID(appHint: appHint)
        }
        guard let pid = resolved.pid else {
            return ("error", "No target app found\(appHint.map { " for '\($0)'" } ?? "") and no non-Blink frontmost app.")
        }

        let outcome = await MainActor.run { () -> BlinkAgentAccessibilityClicker.Outcome in
            BlinkAgentAccessibilityClicker.click(label: labelRaw, pid: pid, roleHint: roleHint)
        }

        switch outcome {
        case .pressed(let role, let title):
            return ("ok", "Pressed \(role) '\(title)' in \(resolved.appName).")
        case .clicked(let role, let title, let point):
            return ("ok", "Clicked \(role) '\(title)' in \(resolved.appName) at (\(Int(point.x)), \(Int(point.y))).")
        case .notFound:
            return ("error", "No control matching '\(labelRaw)' in \(resolved.appName). Try click_at after a screenshot, or refine the label.")
        case .axDenied:
            return ("error", "Accessibility permission denied. Grant Blink permission in System Settings → Privacy & Security → Accessibility.")
        case .failed(let reason):
            return ("error", "click_button failed: \(reason)")
        }
    }

    @MainActor
    private static func screenshot() async -> (status: String, detail: String) {
        guard let window = BlinkComputerUseWindowEnumerator.frontmostTargetWindow() else {
            return ("error", "No focused window to capture.")
        }
        do {
            let capture = try await BlinkComputerUseWindowCaptureUtility.capture(window: window)
            let kb = capture.imageData.count / 1024
            return ("ok", "Captured \(window.owner) — \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels), \(kb) KB. Window bounds top-left at (\(Int(window.bounds.x)), \(Int(window.bounds.y))) size \(Int(window.bounds.width))x\(Int(window.bounds.height)).")
        } catch {
            return ("error", error.localizedDescription)
        }
    }
}

// MARK: - HuggingFace backend

enum BlinkAgentHuggingFaceConfig {
    /// Llama 3.3 70B Instruct is the agent reasoning model: it reliably
    /// emits OpenAI-format tool calls through the HF router. Voxtral is
    /// kept for SPEECH TRANSCRIPTION only (see VoxtralHFTranscriptionProvider)
    /// — using it as a chat-completions text agent on the HF router returns
    /// empty/no-tool responses because the model is audio-first and isn't
    /// served reliably for tool-aware chat completions across providers.
    /// Override with `BLINK_AGENT_HF_MODEL` env var to experiment.
    static var model: String {
        ProcessInfo.processInfo.environment["BLINK_AGENT_HF_MODEL"]
            ?? "meta-llama/Llama-3.3-70B-Instruct"
    }

    static var baseURL: URL {
        URL(string: "https://router.huggingface.co/v1/chat/completions")!
    }
}

struct BlinkHFToolCall {
    let id: String
    let name: String
    let rawArgumentsJSON: String
    var parsedArguments: [String: Any] {
        guard let data = rawArgumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
}

struct BlinkHFChatTurnResult {
    let assistantText: String?
    let toolCalls: [BlinkHFToolCall]
    /// Non-nil when tool calls were salvaged from the assistant text
    /// (the model emitted JSON or `<tool_call>` markers instead of using the
    /// structured tool_calls field). Used purely for transcript hinting.
    let synthesizedToolCalls: [BlinkHFToolCall]?
}

enum BlinkHFChatAPI {
    static func runToolTurn(
        apiKey: String,
        model: String,
        messages: [[String: Any]],
        tools: [[String: Any]]
    ) async throws -> BlinkHFChatTurnResult {
        var request = URLRequest(url: BlinkAgentHuggingFaceConfig.baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.2,
            "max_tokens": 2048,
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "BlinkHF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "(empty)"
            throw NSError(
                domain: "BlinkHF",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HF chat error (\(http.statusCode)): \(text.prefix(400))"]
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw NSError(domain: "BlinkHF", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unparseable HF response"])
        }

        let assistantText = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var toolCalls: [BlinkHFToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for call in rawCalls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let arguments: String
                if let s = function["arguments"] as? String {
                    arguments = s
                } else if let obj = function["arguments"] as? [String: Any],
                          let data = try? JSONSerialization.data(withJSONObject: obj),
                          let s = String(data: data, encoding: .utf8) {
                    arguments = s
                } else {
                    arguments = "{}"
                }
                toolCalls.append(BlinkHFToolCall(id: id, name: name, rawArgumentsJSON: arguments))
            }
        }

        // Salvage: open source chat models served via the HF router often
        // ignore the OpenAI tool_calls protocol and instead inline the call
        // as JSON or wrap it in `<tool_call>...</tool_call>`. Extract those
        // so the agent actually executes them.
        var synthesized: [BlinkHFToolCall]? = nil
        if toolCalls.isEmpty, let text = assistantText, !text.isEmpty {
            let recovered = BlinkHFChatAPI.extractInlineToolCalls(from: text)
            if !recovered.isEmpty {
                toolCalls = recovered
                synthesized = recovered
            }
        }

        return BlinkHFChatTurnResult(
            assistantText: (assistantText?.isEmpty == false) ? assistantText : nil,
            toolCalls: toolCalls,
            synthesizedToolCalls: synthesized
        )
    }

    /// Pulls tool calls out of an assistant text payload. Handles:
    ///   * `<tool_call>{"name":"open_app","arguments":{...}}</tool_call>`
    ///   * a bare JSON object with `name` + `arguments`
    ///   * fenced ```json blocks containing the same shape
    static func extractInlineToolCalls(from text: String) -> [BlinkHFToolCall] {
        var candidates: [String] = []
        let tagPattern = #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#
        if let re = try? NSRegularExpression(pattern: tagPattern, options: []) {
            let ns = text as NSString
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2 else { return }
                candidates.append(ns.substring(with: m.range(at: 1)))
            }
        }
        let fencePattern = #"```(?:json)?\s*(\{[\s\S]*?\})\s*```"#
        if let re = try? NSRegularExpression(pattern: fencePattern, options: []) {
            let ns = text as NSString
            re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2 else { return }
                candidates.append(ns.substring(with: m.range(at: 1)))
            }
        }
        // Bare top-level JSON object with `name`+`arguments`. Cheap heuristic:
        // grab the first balanced `{ ... }` that contains `"name"`.
        if let bare = firstBalancedJSONObject(in: text), bare.contains("\"name\"") {
            candidates.append(bare)
        }

        var out: [BlinkHFToolCall] = []
        for (i, raw) in candidates.enumerated() {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = (obj["name"] as? String) ?? (obj["tool"] as? String),
                  !name.isEmpty else { continue }
            let argsObj = obj["arguments"] ?? obj["parameters"] ?? obj["input"] ?? [:]
            let argsJSON: String
            if let s = argsObj as? String {
                argsJSON = s
            } else if let dict = argsObj as? [String: Any],
                      let d = try? JSONSerialization.data(withJSONObject: dict),
                      let s = String(data: d, encoding: .utf8) {
                argsJSON = s
            } else {
                argsJSON = "{}"
            }
            out.append(BlinkHFToolCall(
                id: "synth-\(i)-\(UUID().uuidString.prefix(8))",
                name: name,
                rawArgumentsJSON: argsJSON
            ))
        }
        return out
    }

    private static func firstBalancedJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if escape { escape = false } else if c == "\\" && inString { escape = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: i)
                        return String(text[start..<end])
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }
}

// MARK: - Deterministic intent router
//
// Recognizes a handful of unambiguous verbs so the agent never has to depend
// on the LLM remembering to call tools. Returns a concrete tool plan when the
// prompt is clear enough to skip the model; otherwise nil and the LLM loop
// runs as usual.

struct BlinkAgentToolStep {
    let name: String
    let input: [String: Any]
}

enum BlinkAgentIntentRouter {
    static func plan(for rawPrompt: String) -> [BlinkAgentToolStep]? {
        let lower = rawPrompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        // 0) URL-shaped prompts. We still match these early, BUT before
        //    accepting the URL verbatim we sanity-check the domain stem
        //    against the alias dict — that way a misheard "gethub.com"
        //    redirects to github.com instead of landing on the wrong site.
        if let m = firstMatch(
            pattern: #"^(?:(?:please\s+)?(?:go\s+to|open|visit|load|navigate\s+to)\s+(?:the\s+)?)?(https?://\S+|(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}(?:/\S*)?)(?:\s+in\s+([a-z][a-z0-9 ]{1,30}))?$"#,
            in: lower
        ) {
            let rawUrl = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
            let resolved = canonicalizeMaybeMisheardURL(rawUrl)
            let browserHint = m.count > 2 ? m[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var args: [String: Any] = ["query": resolved]
            if !browserHint.isEmpty, isBrowserName(browserHint) {
                args["browser"] = canonicalBrowserName(browserHint)
            }
            return [BlinkAgentToolStep(name: "web_search", input: args)]
        }

        // 0.5) Known website name with fuzzy matching. Catches:
        //      - "open github"        → github.com (exact)
        //      - "open gethub"        → github.com (exact, hardcoded variant)
        //      - "open githab"        → github.com (fuzzy, edit distance 1)
        //      - "open the github"    → github.com (filler word stripped)
        //      - "open you tube"      → youtube.com (space collapsed)
        //      Runs BEFORE the open-app rule so we don't try to launch a
        //      "github" app.
        if let m = firstMatch(
            pattern: #"^(?:please\s+)?(?:open|go\s+to|visit|load|navigate\s+to|launch|pull\s+up|bring\s+up|take\s+me\s+to)\s+(?:the\s+|my\s+)?([a-z0-9 .'+-]{2,40}?)(?:\s+(?:website|site|web\s*page|page|homepage))?(?:\s+in\s+([a-z][a-z0-9 ]{1,30}))?$"#,
            in: lower
        ) {
            let candidate = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let canonical = fuzzyAliasLookup(candidate) {
                let browserHint = m.count > 2 ? m[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                var args: [String: Any] = ["query": canonical]
                if !browserHint.isEmpty, isBrowserName(browserHint) {
                    args["browser"] = canonicalBrowserName(browserHint)
                }
                return [BlinkAgentToolStep(name: "web_search", input: args)]
            }
        }
        // Bare site name with no verb: "github", "youtube", "gethub"
        if let canonical = fuzzyAliasLookup(lower) {
            return [BlinkAgentToolStep(name: "web_search", input: ["query": canonical])]
        }

        // 1) "open <app> and (search/look up/google/check) <query>"
        if let m = firstMatch(
            pattern: #"^(?:please\s+)?open\s+([a-z0-9 .+-]{2,40}?)(?:\s+and\s+(?:search(?:\s+for)?|look\s+up|google|check|find)\s+(.+))?$"#,
            in: lower
        ) {
            let app = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let query = m.count > 2 ? m[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if !query.isEmpty, isBrowserName(app) {
                return [
                    BlinkAgentToolStep(name: "web_search", input: ["query": preserveOriginalCase(query, in: rawPrompt), "browser": canonicalBrowserName(app)])
                ]
            }
            if !query.isEmpty {
                // Non-browser app + query — open the app (which polls until
                // ready), then type the query.
                return [
                    BlinkAgentToolStep(name: "open_app", input: ["name": canonicalAppName(app)]),
                    BlinkAgentToolStep(name: "type_text", input: ["text": preserveOriginalCase(query, in: rawPrompt)])
                ]
            }
            return [BlinkAgentToolStep(name: "open_app", input: ["name": canonicalAppName(app)])]
        }

        // 2) ANY prompt with the word "weather" — extract whatever follows
        //    "in"/"for"/"at" as the city, or fall back to the whole prompt.
        //    Catches "weather tokyo", "what's the weather like in tokyo",
        //    "tell me the weather for NYC", "weather in london today", etc.
        if lower.range(of: #"\bweather\b"#, options: .regularExpression) != nil {
            if let m = firstMatch(pattern: #"weather\s+(?:like\s+)?(?:in|for|at)\s+(.+?)(?:\s+today|\s+tomorrow|\s+now)?\??$"#, in: lower) {
                let city = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
                return [BlinkAgentToolStep(name: "web_search", input: ["query": "weather \(city)"])]
            }
            if let m = firstMatch(pattern: #"weather\s+([a-z0-9 .,'-]{2,60})\??$"#, in: lower) {
                let city = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
                return [BlinkAgentToolStep(name: "web_search", input: ["query": "weather \(city)"])]
            }
            // Bare "weather" with no city specified — search the whole prompt.
            return [BlinkAgentToolStep(name: "web_search", input: ["query": rawPrompt])]
        }

        // 3) "search/google/look up <query>" (no app named — use default browser)
        if let m = firstMatch(
            pattern: #"^(?:please\s+)?(?:search(?:\s+for)?|google|look\s+up|find)\s+(.+)$"#,
            in: lower
        ) {
            let query = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
            return [BlinkAgentToolStep(name: "web_search", input: ["query": query])]
        }

        // 4) "go to <url>" / "open <url>"
        if let m = firstMatch(
            pattern: #"^(?:please\s+)?(?:go\s+to|open|visit|load)\s+(https?://\S+|[a-z0-9-]+\.[a-z]{2,}\S*)$"#,
            in: lower
        ) {
            let url = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
            return [BlinkAgentToolStep(name: "web_search", input: ["query": url])]
        }

        // 5) "new tab"
        if lower == "new tab" || lower == "open a new tab" || lower == "open new tab" {
            return [BlinkAgentToolStep(name: "new_tab", input: [:])]
        }

        // 6) "type <text>"
        if let m = firstMatch(pattern: #"^(?:please\s+)?type\s+(.+)$"#, in: lower) {
            let text = preserveOriginalCase(m[1].trimmingCharacters(in: .whitespacesAndNewlines), in: rawPrompt)
            // Strip surrounding quotes if present.
            let cleaned = stripWrappingQuotes(text)
            return [BlinkAgentToolStep(name: "type_text", input: ["text": cleaned])]
        }

        // 7) "press <combo>" e.g. "press cmd+t", "press return"
        if let m = firstMatch(pattern: #"^(?:please\s+)?(?:press|hit|tap)\s+([a-z0-9 +-]+)$"#, in: lower) {
            let combo = m[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard let key = parts.last, !key.isEmpty else { return nil }
            let mods = parts.dropLast().filter { ["cmd", "command", "shift", "option", "alt", "ctrl", "control"].contains($0) }
                .map { (m: String) -> String in
                    switch m {
                    case "command": return "cmd"
                    case "alt": return "option"
                    case "control": return "ctrl"
                    default: return m
                    }
                }
            return [BlinkAgentToolStep(name: "key_press", input: ["key": key, "modifiers": mods])]
        }

        return nil
    }

    // MARK: - Helpers

    private static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return groups
    }

    /// Normalize a possibly-misheard site name: lowercase, collapse spaces,
    /// strip punctuation. So "Git Hub", "gethub", "git-hub" all collapse to
    /// "github" for lookup.
    private static func normalizeSiteAlias(_ raw: String) -> String {
        let lowered = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
    }

    /// Exact alias lookup, then fuzzy (Levenshtein) within an adaptive
    /// threshold (1 for short keys, 2 for longer). Lets "githab", "guthub",
    /// "youtoob" resolve to their canonical sites without needing every
    /// variant pre-listed.
    static func fuzzyAliasLookup(_ candidate: String) -> String? {
        let normalized = normalizeSiteAlias(candidate)
        guard !normalized.isEmpty else { return nil }
        if let exact = websiteAliases[normalized] { return exact }

        // Skip fuzzy for very short tokens — too many false positives.
        guard normalized.count >= 4 else { return nil }

        let threshold = normalized.count <= 6 ? 1 : 2
        var best: (key: String, distance: Int)? = nil
        for key in websiteAliases.keys {
            // Quick reject on length difference.
            if abs(key.count - normalized.count) > threshold { continue }
            let d = levenshtein(normalized, key)
            if d <= threshold, best == nil || d < best!.distance {
                best = (key, d)
            }
        }
        if let match = best { return websiteAliases[match.key] }
        return nil
    }

    /// Last-mile canonicalization — applied inside web_search just before
    /// keystrokes go out. Works for both URL-shaped queries (catches
    /// "gethub.com") and bare site names (catches "gethub").
    static func canonicalizeQueryIfPossible(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return query }
        let lower = trimmed.lowercased()
        // URL-shaped (contains scheme or a dot followed by letters)
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.range(of: #"\.[a-z]{2,}"#, options: .regularExpression) != nil {
            return canonicalizeMaybeMisheardURL(trimmed)
        }
        // Single token? Try alias lookup.
        if !trimmed.contains(" "), let canonical = fuzzyAliasLookup(trimmed) {
            return canonical
        }
        return query
    }

    /// If a user-supplied URL's bare host (e.g. "gethub" from "gethub.com")
    /// fuzzy-matches a known alias, return the alias's canonical URL.
    /// Otherwise return the URL unchanged. Preserves any path/query on the
    /// original URL when substituting.
    static func canonicalizeMaybeMisheardURL(_ rawURL: String) -> String {
        let lower = rawURL.lowercased()
        var rest = lower
        if rest.hasPrefix("https://") { rest = String(rest.dropFirst(8)) }
        else if rest.hasPrefix("http://") { rest = String(rest.dropFirst(7)) }
        if rest.hasPrefix("www.") { rest = String(rest.dropFirst(4)) }

        // Split host vs path.
        let host: String
        let path: String
        if let slash = rest.firstIndex(of: "/") {
            host = String(rest[..<slash])
            path = String(rest[slash...])
        } else {
            host = rest
            path = ""
        }
        // Take the leftmost label only (drop TLDs and subdomains right of it).
        let labels = host.split(separator: ".").map(String.init)
        guard let stem = labels.first, !stem.isEmpty else { return rawURL }
        // If the stem itself matches an alias (exact or fuzzy), redirect.
        if let canonical = fuzzyAliasLookup(stem) {
            // Only replace when the alias key isn't already a perfect match
            // for the stem — avoids no-op rewrites like "github" → "github".
            let normStem = normalizeSiteAlias(stem)
            let canonicalHost = canonical
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "")
                .split(separator: "/").first.map(String.init) ?? canonical
            let canonicalStem = normalizeSiteAlias(canonicalHost.split(separator: ".").first.map(String.init) ?? "")
            if normStem == canonicalStem {
                return rawURL
            }
            return path.isEmpty ? canonical : canonical + path
        }
        return rawURL
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let ac = Array(a)
        let bc = Array(b)
        var prev = Array(0...bc.count)
        var curr = Array(repeating: 0, count: bc.count + 1)
        for i in 1...ac.count {
            curr[0] = i
            for j in 1...bc.count {
                let cost = ac[i-1] == bc[j-1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j-1] + 1,      // insertion
                    prev[j-1] + cost    // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[bc.count]
    }

    /// Map of normalized site names (and common speech-to-text mis-hearings)
    /// to the canonical URL. Keys must already be normalized via
    /// `normalizeSiteAlias` (alphanumeric only, lowercased).
    private static let websiteAliases: [String: String] = [
        // GitHub
        "github": "https://github.com",
        "gethub": "https://github.com",
        "githab": "https://github.com",
        "githib": "https://github.com",
        "githup": "https://github.com",
        "guithub": "https://github.com",
        "githubcom": "https://github.com",

        // YouTube
        "youtube": "https://youtube.com",
        "utube": "https://youtube.com",
        "yt": "https://youtube.com",
        "youtub": "https://youtube.com",
        "youtoob": "https://youtube.com",

        // Google
        "google": "https://google.com",
        "googl": "https://google.com",
        "gugl": "https://google.com",

        // Gmail
        "gmail": "https://mail.google.com",
        "googlemail": "https://mail.google.com",

        // Google Drive / Docs / Calendar / Maps
        "googledrive": "https://drive.google.com",
        "gdrive": "https://drive.google.com",
        "drive": "https://drive.google.com",
        "googledocs": "https://docs.google.com",
        "gdocs": "https://docs.google.com",
        "docs": "https://docs.google.com",
        "googlecalendar": "https://calendar.google.com",
        "gcal": "https://calendar.google.com",
        "calendar": "https://calendar.google.com",
        "googlemaps": "https://maps.google.com",
        "maps": "https://maps.google.com",

        // ChatGPT / OpenAI
        "chatgpt": "https://chatgpt.com",
        "chatgbt": "https://chatgpt.com",
        "chatgtp": "https://chatgpt.com",
        "chatpgt": "https://chatgpt.com",
        "openai": "https://openai.com",

        // Claude / Anthropic
        "claude": "https://claude.ai",
        "claudeai": "https://claude.ai",
        "anthropic": "https://anthropic.com",

        // Twitter / X
        "twitter": "https://x.com",
        "x": "https://x.com",
        "xcom": "https://x.com",

        // Facebook / Meta
        "facebook": "https://facebook.com",
        "fb": "https://facebook.com",
        "metacom": "https://meta.com",

        // Instagram
        "instagram": "https://instagram.com",
        "insta": "https://instagram.com",
        "ig": "https://instagram.com",

        // LinkedIn
        "linkedin": "https://linkedin.com",
        "linktin": "https://linkedin.com",

        // Reddit
        "reddit": "https://reddit.com",
        "redit": "https://reddit.com",

        // Stack Overflow
        "stackoverflow": "https://stackoverflow.com",
        "stackexchange": "https://stackexchange.com",

        // Wikipedia
        "wikipedia": "https://wikipedia.org",
        "wiki": "https://wikipedia.org",

        // Amazon
        "amazon": "https://amazon.com",
        "amazoncom": "https://amazon.com",

        // Netflix / Hulu / Disney+
        "netflix": "https://netflix.com",
        "hulu": "https://hulu.com",
        "disneyplus": "https://disneyplus.com",
        "disney": "https://disneyplus.com",

        // Spotify / Apple Music / YouTube Music
        "spotify": "https://open.spotify.com",
        "applemusic": "https://music.apple.com",
        "youtubemusic": "https://music.youtube.com",
        "ytmusic": "https://music.youtube.com",

        // Discord / Slack / Teams / Zoom
        "discord": "https://discord.com",
        "slack": "https://slack.com",
        "teams": "https://teams.microsoft.com",
        "msteams": "https://teams.microsoft.com",
        "zoom": "https://zoom.us",

        // Notion / Figma / Linear / Jira
        "notion": "https://notion.so",
        "figma": "https://figma.com",
        "linear": "https://linear.app",
        "jira": "https://atlassian.com/software/jira",
        "atlassian": "https://atlassian.com",

        // News
        "nytimes": "https://nytimes.com",
        "newyorktimes": "https://nytimes.com",
        "nyt": "https://nytimes.com",
        "bbc": "https://bbc.com",
        "cnn": "https://cnn.com",
        "techcrunch": "https://techcrunch.com",
        "hackernews": "https://news.ycombinator.com",
        "hn": "https://news.ycombinator.com",
        "ycombinator": "https://news.ycombinator.com",

        // Dev / hosting / cloud
        "vercel": "https://vercel.com",
        "netlify": "https://netlify.com",
        "cloudflare": "https://cloudflare.com",
        "aws": "https://aws.amazon.com",
        "awsconsole": "https://console.aws.amazon.com",
        "gcp": "https://console.cloud.google.com",
        "googlecloud": "https://console.cloud.google.com",
        "azure": "https://portal.azure.com",
        "huggingface": "https://huggingface.co",
        "hf": "https://huggingface.co",

        // Shopping
        "ebay": "https://ebay.com",
        "etsy": "https://etsy.com",

        // Other common
        "yahoo": "https://yahoo.com",
        "bing": "https://bing.com",
        "duckduckgo": "https://duckduckgo.com",
        "ddg": "https://duckduckgo.com",
        "pinterest": "https://pinterest.com",
        "tiktok": "https://tiktok.com",
        "twitch": "https://twitch.tv",
        "paypal": "https://paypal.com",
        "venmo": "https://venmo.com"
    ]

    private static let browserAliases: [String: String] = [
        "safari": "Safari",
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "arc": "Arc",
        "firefox": "Firefox",
        "brave": "Brave Browser",
        "edge": "Microsoft Edge",
        "microsoft edge": "Microsoft Edge"
    ]

    private static func isBrowserName(_ name: String) -> Bool {
        browserAliases[name.lowercased()] != nil
    }

    private static func canonicalBrowserName(_ name: String) -> String {
        browserAliases[name.lowercased()] ?? name
    }

    private static func canonicalAppName(_ name: String) -> String {
        if let canonical = browserAliases[name.lowercased()] { return canonical }
        // Title-case-ish — most macOS apps are camelcased ("Notes", "Calendar").
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The regex matches against the lowercased prompt but we want to preserve
    /// the user's original casing for things they'll see (search queries, URLs).
    /// Find the substring in the raw prompt that corresponds to the lowercased
    /// match and return that.
    private static func preserveOriginalCase(_ lowercased: String, in rawPrompt: String) -> String {
        guard let range = rawPrompt.range(of: lowercased, options: [.caseInsensitive]) else {
            return lowercased
        }
        return String(rawPrompt[range])
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2 {
            let first = trimmed.first!
            let last = trimmed.last!
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                return String(trimmed.dropFirst().dropLast())
            }
        }
        return trimmed
    }
}

// MARK: - Accessibility-based clicker

/// Finds and invokes labelled UI controls (buttons, menu items, links, etc.)
/// using AXUIElement traversal. Lets the agent click "Stop Sharing" in Zoom
/// or "Send" in Messages without needing pixel coordinates or screenshots.
enum BlinkAgentAccessibilityClicker {
    enum Outcome {
        case pressed(role: String, title: String)
        case clicked(role: String, title: String, point: CGPoint)
        case notFound
        case axDenied
        case failed(String)
    }

    struct InspectedElement {
        let role: String
        let label: String
        let center: CGPoint
    }

    @MainActor
    static func inspect(pid: pid_t, query: String?, limit: Int) -> [InspectedElement] {
        guard AXIsProcessTrusted() else { return [] }
        let appElement = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = []
        if let focused = copyAXElement(appElement, kAXFocusedWindowAttribute as CFString) {
            roots.append(focused)
        }
        for window in copyAXElementArray(appElement, kAXWindowsAttribute as CFString)
            where !roots.contains(window) {
            roots.append(window)
        }
        if roots.isEmpty { roots.append(appElement) }

        let clickable = rolesForHint(nil)
        var seen = Set<String>()
        var results: [InspectedElement] = []
        for root in roots {
            traverse(root, depth: 0, maxDepth: 18) { element in
                guard results.count < limit else { return }
                guard let role = copyAXValue(element, kAXRoleAttribute) as? String,
                      clickable.contains(role) else { return }
                let labels: [String] = [
                    copyAXValue(element, kAXTitleAttribute) as? String,
                    copyAXValue(element, kAXDescriptionAttribute) as? String,
                    copyAXValue(element, kAXHelpAttribute) as? String,
                    copyAXValue(element, "AXLabel" as CFString) as? String,
                    copyAXValue(element, kAXValueAttribute) as? String
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard let label = labels.first else { return }
                if let query, !query.isEmpty, !label.lowercased().contains(query) { return }
                guard let frame = elementFrame(element), frame.width > 0, frame.height > 0 else { return }
                let key = "\(role)|\(label)|\(Int(frame.midX))|\(Int(frame.midY))"
                if seen.contains(key) { return }
                seen.insert(key)
                results.append(InspectedElement(
                    role: role,
                    label: label,
                    center: CGPoint(x: frame.midX, y: frame.midY)
                ))
            }
            if results.count >= limit { break }
        }
        return results
    }

    @MainActor
    static func resolveTargetPID(appHint: String?) -> (pid: pid_t?, appName: String) {
        let workspace = NSWorkspace.shared
        if let hint = appHint?.lowercased(), !hint.isEmpty {
            if let match = workspace.runningApplications.first(where: {
                if let bid = $0.bundleIdentifier?.lowercased(), bid == hint { return true }
                if let name = $0.localizedName?.lowercased(), name == hint || name.contains(hint) { return true }
                return false
            }) {
                match.activate(options: [.activateAllWindows])
                return (match.processIdentifier, match.localizedName ?? hint)
            }
            return (nil, hint)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = workspace.frontmostApplication, front.processIdentifier != ownPID {
            return (front.processIdentifier, front.localizedName ?? "frontmost app")
        }
        if let first = workspace.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }) {
            return (first.processIdentifier, first.localizedName ?? "running app")
        }
        return (nil, "(none)")
    }

    @MainActor
    static func click(label: String, pid: pid_t, roleHint: String?) -> Outcome {
        guard AXIsProcessTrusted() else { return .axDenied }
        let appElement = AXUIElementCreateApplication(pid)

        // Prefer focused window, but fall back to all windows so menu-bar
        // or sheet controls are still reachable.
        var roots: [AXUIElement] = []
        if let focused = copyAXElement(appElement, kAXFocusedWindowAttribute as CFString) {
            roots.append(focused)
        }
        for window in copyAXElementArray(appElement, kAXWindowsAttribute as CFString)
            where !roots.contains(window) {
            roots.append(window)
        }
        if roots.isEmpty { roots.append(appElement) }

        let needle = label.lowercased()
        let allowedRoles = rolesForHint(roleHint)

        var best: (element: AXUIElement, role: String, title: String, score: Int)?
        for root in roots {
            traverse(root, depth: 0, maxDepth: 18) { element in
                guard let role = copyAXValue(element, kAXRoleAttribute) as? String,
                      allowedRoles.contains(role) || allowedRoles.isEmpty else { return }
                let candidates: [String] = [
                    copyAXValue(element, kAXTitleAttribute) as? String,
                    copyAXValue(element, kAXDescriptionAttribute) as? String,
                    copyAXValue(element, kAXHelpAttribute) as? String,
                    copyAXValue(element, kAXValueAttribute) as? String,
                    copyAXValue(element, "AXLabel" as CFString) as? String
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                for candidate in candidates {
                    let lower = candidate.lowercased()
                    let score: Int
                    if lower == needle { score = 1000 }
                    else if lower.hasPrefix(needle) || needle.hasPrefix(lower) { score = 500 }
                    else if lower.contains(needle) || needle.contains(lower) { score = 200 }
                    else { continue }
                    if best == nil || score > best!.score {
                        best = (element, role, candidate, score)
                    }
                }
            }
            if let best, best.score >= 1000 { break }
        }

        guard let hit = best else { return .notFound }

        let actionNames = (copyActionNames(hit.element) ?? []).map { $0 as String }
        if actionNames.contains(kAXPressAction as String) {
            let err = AXUIElementPerformAction(hit.element, kAXPressAction as CFString)
            if err == .success {
                return .pressed(role: hit.role, title: hit.title)
            }
        }

        guard let frame = elementFrame(hit.element) else {
            return .failed("found '\(hit.title)' but could not read its bounds")
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        do {
            try BlinkComputerUseMouseInput.move(to: center, smoothly: true)
            try BlinkComputerUseMouseInput.click(at: center)
            return .clicked(role: hit.role, title: hit.title, point: center)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func rolesForHint(_ hint: String?) -> Set<String> {
        let allClickable: Set<String> = [
            kAXButtonRole, kAXMenuItemRole, kAXCheckBoxRole, kAXRadioButtonRole,
            kAXPopUpButtonRole, kAXTabGroupRole, kAXMenuButtonRole,
            kAXDisclosureTriangleRole, "AXTab", "AXLink", "AXSwitch"
        ]
        guard let hint, !hint.isEmpty else { return allClickable }
        switch hint {
        case "button": return [kAXButtonRole, kAXMenuButtonRole]
        case "menu_item", "menuitem", "menu": return [kAXMenuItemRole]
        case "checkbox": return [kAXCheckBoxRole]
        case "radio": return [kAXRadioButtonRole]
        case "link": return ["AXLink"]
        case "popup", "pop_up", "popupbutton": return [kAXPopUpButtonRole]
        case "tab": return ["AXTab", kAXTabGroupRole]
        default: return allClickable
        }
    }

    private static func traverse(_ element: AXUIElement, depth: Int, maxDepth: Int, visit: (AXUIElement) -> Void) {
        visit(element)
        guard depth < maxDepth else { return }
        let childAttrs: [CFString] = [
            kAXChildrenAttribute as CFString,
            "AXVisibleChildren" as CFString
        ]
        for attr in childAttrs {
            for child in copyAXElementArray(element, attr) {
                traverse(child, depth: depth + 1, maxDepth: maxDepth, visit: visit)
            }
        }
    }

    private static func copyAXElement(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // safe: TypeID checked above
    }

    private static func copyAXElementArray(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success,
              let value,
              CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray // safe: TypeID checked above
        let count = CFArrayGetCount(array)
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, i) else { continue }
            let element = Unmanaged<AXUIElement>.fromOpaque(raw).takeUnretainedValue()
            result.append(element)
        }
        return result
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        copyAXValue(element, attribute as CFString)
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success, let value else { return nil }
        return value as AnyObject
    }

    private static func copyActionNames(_ element: AXUIElement) -> [String]? {
        var names: CFArray?
        let err = AXUIElementCopyActionNames(element, &names)
        guard err == .success, let names else { return nil }
        return names as? [String]
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
