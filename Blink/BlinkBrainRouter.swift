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
        let tools = Self.tools

        // Seed the conversation with the user's request and the initial
        // screenshot so the model can see the starting state.
        var input: [[String: Any]] = []
        var userContent: [[String: Any]] = [[
            "type": "input_text",
            "text": trimmed
        ]]
        if let screenshot = await companionManager?.brainCaptureScreenshot() {
            userContent.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(screenshot.base64EncodedString())"
            ])
        }
        input.append([
            "role": "user",
            "content": userContent
        ])

        var didDispatchAtLeastOneTool = false

        for step in 0..<Self.maxSteps {
            let toolCall: OpenAIAPI.ToolCall?
            do {
                toolCall = try await openAIAPI.runToolLoopStep(
                    systemPrompt: systemPrompt,
                    input: input,
                    tools: tools
                )
            } catch {
                print("BlinkBrainRouter step \(step) error: \(error.localizedDescription)")
                return didDispatchAtLeastOneTool
            }

            guard let toolCall else {
                // Model emitted only text — stop. Already-dispatched
                // tools count as a successful turn.
                return didDispatchAtLeastOneTool
            }

            // finish_task ends the loop cleanly.
            if toolCall.name == "finish_task" {
                let summary = (toolCall.arguments["summary"] as? String) ?? ""
                if !summary.isEmpty {
                    companionManager?.brainSpeak(summary)
                }
                return true
            }

            let dispatchResult = dispatch(toolCall: toolCall, transcript: trimmed, isFinalStep: false)
            didDispatchAtLeastOneTool = didDispatchAtLeastOneTool || dispatchResult.handled

            // speak_answer / run_background_agent / web_search are terminal
            // — no follow-up screenshot makes sense, so end the loop here.
            if dispatchResult.isTerminal {
                return true
            }

            // Record the function call + a synthetic output so the model
            // can ground the next step against the prior decision.
            input.append([
                "type": "function_call",
                "call_id": toolCall.callID,
                "name": toolCall.name,
                "arguments": toolCall.argumentsJSON
            ])
            input.append([
                "type": "function_call_output",
                "call_id": toolCall.callID,
                "output": dispatchResult.handled ? "ok" : "failed"
            ])

            // Wait for the UI to settle (page load, animation, app
            // launch) before capturing a fresh screenshot for the next
            // step.
            try? await Task.sleep(nanoseconds: Self.postActionDelayNanoseconds)
            if let nextScreenshot = await companionManager?.brainCaptureScreenshot() {
                input.append([
                    "role": "user",
                    "content": [[
                        "type": "input_image",
                        "image_url": "data:image/jpeg;base64,\(nextScreenshot.base64EncodedString())"
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
            return DispatchResult(handled: true, isTerminal: false)

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
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
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

    Tool selection rules:
    - open_url for any WEBSITE or web brand (github, gmail, youtube, hacker news, twitter, reddit, the verge, anthropic, openai, claude, anything that lives on the web). ALWAYS use open_url for these — never open_app. Recover garbled Apple Speech ("opengithub.com", "github dot com") into the real domain.
    - open_app ONLY for native macOS applications installed on the user's Mac (Chrome, Notes, Slack, Spotify, Cursor, Xcode, Terminal, Finder, Messages, Mail, Calendar). Web services like github are NOT apps.
    - press_keys for macOS shortcuts (cmd+w close, cmd+shift+m Zoom stop share, cmd+t new tab, cmd+space Spotlight, cmd+option+esc force quit, cmd+f find, cmd+l URL bar).
    - click_at for clicking visible UI elements when no shortcut exists. x/y in points relative to the screenshot top-left.
    - type_text to type a string into the focused field.
    - speak_answer for factual / conversational replies (no UI action). Setting needs_visual=true only for places, food, nature, animals, products, recipes.
    - run_background_agent for long minutes-long work (build a script, refactor, research report).
    - web_search for explicit "google X" requests.
    - finish_task ALWAYS at the end of a multi-step task once everything is done. Provide a 4-10 word summary that will be spoken aloud.

    Stop calling intermediate tools and call finish_task as soon as the goal is visibly achieved in the screenshot.

    speak_answer.text: 1-3 sentences, conversational, under 40 words. MUST be COMPLETE sentences ending in proper punctuation (. ! ?). NEVER trail off with ellipsis. NEVER end mid-phrase like "it's a ..." — finish the thought.
    speak_answer.image_topic: 1-3 concrete nouns. Only when needs_visual=true.
    finish_task.summary: COMPLETE sentence ending in punctuation. Never end with ellipsis or a fragment.
    """

    private static let tools: [[String: Any]] = [
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
            "name": "run_background_agent",
            "description": "Spawn a background Codex agent for substantial work (minutes-long).",
            "parameters": [
                "type": "object",
                "properties": [
                    "instruction": ["type": "string"]
                ],
                "required": ["instruction"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
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
        ],
        [
            "type": "function",
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
}
