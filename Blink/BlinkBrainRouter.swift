//
//  BlinkBrainRouter.swift
//  Blink
//
//  Multi-step OpenAI agent loop. The model receives the user's
//  utterance + a screenshot each iteration and calls one tool. After
//  the tool dispatches, we wait for the UI to settle, capture a fresh
//  screenshot, feed everything back, and let the model decide the
//  next step. Loop ends when the model calls finish_task, hits the
//  step cap, or fails to choose a tool.
//

import AppKit
import Foundation

@MainActor
final class BlinkBrainRouter {
    private weak var companionManager: CompanionManager?
    private let openAIAPI: OpenAIAPI

    private static let maxSteps = 8
    private static let postActionDelayNanoseconds: UInt64 = 1_500_000_000

    init(companionManager: CompanionManager, openAIAPI: OpenAIAPI) {
        self.companionManager = companionManager
        self.openAIAPI = openAIAPI
    }

    func route(transcript: String) async -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let systemPrompt = Self.systemPrompt
        let tools = Self.chatTools

        // Seed conversation with user's request + initial screenshot (chat completions format).
        var userContent: [[String: Any]] = [[
            "type": "text",
            "text": trimmed
        ]]
        if let screenshot = await companionManager?.brainCaptureScreenshot() {
            userContent.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(screenshot.base64EncodedString())"]
            ])
        }
        var messages: [[String: Any]] = [[
            "role": "user",
            "content": userContent
        ]]

        var didDispatchAtLeastOneTool = false

        for step in 0..<Self.maxSteps {
            let toolCall: OpenAIAPI.ToolCall?
            do {
                toolCall = try await openAIAPI.runChatCompletionsTurn(
                    systemPrompt: systemPrompt,
                    messages: messages,
                    tools: tools
                )
            } catch {
                print("BlinkBrainRouter step \(step) error: \(error.localizedDescription)")
                return didDispatchAtLeastOneTool
            }

            guard let toolCall else {
                return didDispatchAtLeastOneTool
            }

            if toolCall.name == "finish_task" {
                let summary = (toolCall.arguments["summary"] as? String) ?? ""
                companionManager?.brainSpeak(summary.isEmpty ? "done" : summary)
                return true
            }

            let dispatchResult = dispatch(toolCall: toolCall, transcript: trimmed, isFinalStep: false)
            didDispatchAtLeastOneTool = didDispatchAtLeastOneTool || dispatchResult.handled

            if dispatchResult.isTerminal {
                return true
            }

            // Append assistant tool_calls + tool result in chat completions format.
            messages.append([
                "role": "assistant",
                "tool_calls": [[
                    "id": toolCall.callID,
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ]]
            ])
            messages.append([
                "role": "tool",
                "tool_call_id": toolCall.callID,
                "content": dispatchResult.handled ? "ok" : "failed"
            ])

            try? await Task.sleep(nanoseconds: Self.postActionDelayNanoseconds)
            if let nextScreenshot = await companionManager?.brainCaptureScreenshot() {
                messages.append([
                    "role": "user",
                    "content": [[
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(nextScreenshot.base64EncodedString())"]
                    ]]
                ])
            }
        }

        return didDispatchAtLeastOneTool
    }

    private struct DispatchResult {
        let handled: Bool
        let isTerminal: Bool
    }

    private func dispatch(
        toolCall: OpenAIAPI.ToolCall,
        transcript: String,
        isFinalStep: Bool
    ) -> DispatchResult {
        guard let companionManager else {
            return DispatchResult(handled: false, isTerminal: true)
        }

        switch toolCall.name {
        case "open_url":
            guard let urlString = toolCall.arguments["url"] as? String,
                  let url = URL(string: urlString) else {
                return DispatchResult(handled: false, isTerminal: false)
            }
            NSWorkspace.shared.open(url)
            let displayName = (toolCall.arguments["display_name"] as? String) ?? url.host ?? urlString
            companionManager.brainSpeak("opening \(displayName)")
            return DispatchResult(handled: true, isTerminal: true)

        case "open_app":
            guard let appName = toolCall.arguments["app"] as? String, !appName.isEmpty else {
                return DispatchResult(handled: false, isTerminal: false)
            }
            companionManager.brainOpenApp(appName)
            return DispatchResult(handled: true, isTerminal: false)

        case "speak_answer":
            let text = (toolCall.arguments["text"] as? String) ?? ""
            let needsVisual = (toolCall.arguments["needs_visual"] as? Bool) ?? false
            let imageTopic = (toolCall.arguments["image_topic"] as? String) ?? ""
            guard !text.isEmpty else {
                return DispatchResult(handled: false, isTerminal: true)
            }
            companionManager.brainSpeakWithVisual(
                text: text,
                imageTopic: imageTopic,
                transcript: transcript,
                needsVisual: needsVisual
            )
            return DispatchResult(handled: true, isTerminal: true)

        case "run_background_agent":
            guard let instruction = toolCall.arguments["instruction"] as? String,
                  !instruction.isEmpty else {
                return DispatchResult(handled: false, isTerminal: true)
            }
            companionManager.brainSpawnAgent(instruction: instruction)
            return DispatchResult(handled: true, isTerminal: true)

        case "web_search":
            guard let query = toolCall.arguments["query"] as? String, !query.isEmpty else {
                return DispatchResult(handled: false, isTerminal: true)
            }
            let targetURL: URL?
            if let direct = URL(string: query),
               direct.scheme == "https" || direct.scheme == "http" {
                targetURL = direct
            } else {
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                targetURL = URL(string: "https://www.google.com/search?q=\(encoded)")
            }
            guard let url = targetURL else {
                return DispatchResult(handled: false, isTerminal: true)
            }
            NSWorkspace.shared.open(url)
            companionManager.brainSpeak("Searching for \(query)")
            return DispatchResult(handled: true, isTerminal: true)

        case "press_keys":
            guard let combo = toolCall.arguments["combo"] as? String, !combo.isEmpty else {
                return DispatchResult(handled: false, isTerminal: false)
            }
            companionManager.brainPressKeys(combo: combo)
            return DispatchResult(handled: true, isTerminal: false)

        case "type_text":
            guard let text = toolCall.arguments["text"] as? String, !text.isEmpty else {
                return DispatchResult(handled: false, isTerminal: false)
            }
            companionManager.brainTypeText(text)
            return DispatchResult(handled: true, isTerminal: false)

        case "click_at":
            guard let x = toolCall.arguments["x"] as? Double,
                  let y = toolCall.arguments["y"] as? Double else {
                return DispatchResult(handled: false, isTerminal: false)
            }
            let label = toolCall.arguments["label"] as? String
            companionManager.brainClickAt(x: x, y: y, label: label)
            return DispatchResult(handled: true, isTerminal: false)

        default:
            return DispatchResult(handled: false, isTerminal: false)
        }
    }

    private static let systemPrompt = """
    You are Blink, a macOS voice assistant that drives the screen. The user speaks; you see the screen each turn; you execute tools until the task is complete.

    Every turn call EXACTLY ONE tool. Never refuse, never ask for clarification.

    Multi-step tasks are normal. Plan ahead.
    Example — "open github and click my synapse repo":
      step 1: open_url https://github.com
      step 2: (after page loads) click_at the synapse repo card you can see on the dashboard
      step 3: finish_task — summary "opened your synapse repo"

    Example — "end screen sharing":
      step 1: press_keys "cmd+shift+m" (Zoom stop-share shortcut)
      step 2: finish_task — summary "stopped screen sharing"

    Example — "search github for a typescript router":
      step 1: open_url https://github.com/search?q=typescript+router
      step 2: finish_task

    Example — "open the blink repo" / "open my repo" / "open [repo name] on github":
      step 1: open_url https://github.com/search?q=reponame (if exact owner/repo unknown) OR open_url https://github.com/owner/repo (if known from context)
      (open_url speaks a confirmation automatically — do NOT call finish_task after open_url)

    Tool selection rules:
    - open_url for any WEBSITE or web brand (github, gmail, youtube, hacker news, twitter, reddit, the verge, anthropic, openai, claude, anything that lives on the web). ALWAYS use open_url for these — never open_app. Recover garbled Apple Speech ("opengithub.com", "github dot com") into the real domain.
    - open_app ONLY for native macOS applications installed on the user's Mac (Chrome, Notes, Slack, Spotify, Cursor, Xcode, Terminal, Finder, Messages, Mail, Calendar). Web services like github are NOT apps.
    - press_keys for macOS shortcuts (cmd+w close, cmd+shift+m Zoom stop share, cmd+t new tab, cmd+space Spotlight, cmd+option+esc force quit, cmd+f find, cmd+l URL bar).
    - click_at for clicking visible UI elements when no shortcut exists. x/y in points relative to the screenshot top-left.
    - type_text to type a string into the focused field.
    - speak_answer for factual / conversational replies (no UI action). Setting needs_visual=true only for places, food, nature, animals, products, recipes.
    - run_background_agent for ANY work that involves writing, editing, generating, refactoring, building, debugging, or researching source code, scripts, configuration, or content. Examples that ALWAYS go to run_background_agent: "code a website", "build a python script", "make me a chrome extension", "write a SwiftUI view that…", "refactor this file", "fix the bug in…", "set up a node project", "write tests for…", "research X and write it up". NEVER open Terminal, Xcode, Cursor, VS Code, or any editor to type code yourself via type_text — that wastes the user's foreground. Hand the instruction to run_background_agent and call finish_task.
    - web_search for explicit "google X" requests.
    - finish_task ALWAYS at the end of a multi-step task once everything is done. Provide a 4-10 word summary that will be spoken aloud.

    Example — "code me a website that tracks sleep":
      step 1: run_background_agent instruction "Build a single-page website that tracks daily sleep. Include HTML, CSS, and minimal JS to log hours, persist to localStorage, and chart the last 14 days."
      step 2: finish_task — summary "spawned a background agent to build your sleep tracker"

    Example — "fix the bug in BlinkAgentLoop.swift":
      step 1: run_background_agent instruction "Open BlinkAgentLoop.swift in the current workspace, identify and fix the bug the user mentioned, and report what you changed."
      step 2: finish_task — summary "handed the fix off to a background agent"

    Stop calling intermediate tools and call finish_task as soon as the goal is visibly achieved in the screenshot.

    speak_answer.text: 1-3 sentences, conversational, under 40 words. MUST be COMPLETE sentences ending in proper punctuation (. ! ?). NEVER trail off with ellipsis. NEVER end mid-phrase like "it's a ..." — finish the thought.
    speak_answer.image_topic: 1-3 concrete nouns. Only when needs_visual=true.
    finish_task.summary: COMPLETE sentence ending in punctuation. Never end with ellipsis or a fragment.
    """

    private static let chatTools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "open_url",
                "description": "Open a fully-qualified URL in the default browser. Infer the URL from brand names if needed.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string"],
                        "display_name": ["type": "string"]
                    ],
                    "required": ["url"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "open_app",
                "description": "Launch a native macOS application by name.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string"]
                    ],
                    "required": ["app"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "press_keys",
                "description": "Post a macOS keyboard shortcut via CGEvent. Combo is '+'-separated lowercase tokens, e.g. 'cmd+shift+m'.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "combo": ["type": "string"]
                    ],
                    "required": ["combo"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "click_at",
                "description": "Click at screen coordinates grounded against the supplied screenshot.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "number"],
                        "y": ["type": "number"],
                        "label": ["type": "string"]
                    ],
                    "required": ["x", "y", "label"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "type_text",
                "description": "Type literal text into the focused field via CGEvent keystrokes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"]
                    ],
                    "required": ["text"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "speak_answer",
                "description": "Speak a short conversational reply aloud. Optionally show a centered translucent panel with a topical photo when needs_visual=true.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "needs_visual": ["type": "boolean"],
                        "image_topic": ["type": "string"]
                    ],
                    "required": ["text", "needs_visual"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "run_background_agent",
                "description": "Spawn a background Codex agent. REQUIRED for any coding, scripting, refactoring, building, debugging, file editing, content writing, or multi-step research task — anything the user would otherwise type into an editor or terminal. Use this instead of opening Terminal/Xcode/Cursor and driving them via keystrokes. The instruction string is handed directly to the background agent.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "instruction": ["type": "string"]
                    ],
                    "required": ["instruction"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Open Google search for an explicit search query.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"]
                    ],
                    "required": ["query"],
                    "additionalProperties": false
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "finish_task",
                "description": "End the task. Always call when the user's goal is achieved.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "summary": ["type": "string", "description": "4-10 word spoken summary of what got done"]
                    ],
                    "required": ["summary"],
                    "additionalProperties": false
                ]
            ]
        ]
    ]
}
