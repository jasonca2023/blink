//
//  BlinkBrowserAgent.swift
//  Blink
//
//  Playwright-style CUA Browser Agent runner. Uses Anthropic Claude Sonnet with
//  tools to interactively capture, read, and automate the active WKWebView tab.
//

import Foundation
import WebKit
import AppKit

@MainActor
final class BlinkBrowserAgentRunner {
    private let apiKey: String
    private let modelName: String
    private weak var browserModel: BlinkBrowserWorkspaceModelProtocol?
    
    // Tools schema matching Anthropic's Messages API format
    static let tools: [[String: Any]] = [
        [
            "name": "navigate",
            "description": "Navigate the browser tab to a URL or local HTML file path.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "The target URL or local HTML file path to load."
                    ]
                ],
                "required": ["url"]
            ]
        ],
        [
            "name": "screenshot",
            "description": "Capture the current visible webpage viewport as a screenshot to see its visual layout.",
            "input_schema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "click",
            "description": "Click an interactive element (link, button, input, checkbox, radio, etc.) using a CSS selector, XPath, text matching, or contains matching.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "The selector. E.g. CSS ('#submit', 'button.login'), XPath ('xpath=//button'), text match ('text=Login'), or contains ('button:contains(\"Log in\")')."
                    ]
                ],
                "required": ["selector"]
            ]
        ],
        [
            "name": "click_at",
            "description": "Click at specific viewport coordinates on the page if selectors are not working.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "x": [
                        "type": "number",
                        "description": "The horizontal coordinate in pixels from the left of the viewport."
                    ],
                    "y": [
                        "type": "number",
                        "description": "The vertical coordinate in pixels from the top of the viewport."
                    ]
                ],
                "required": ["x", "y"]
            ]
        ],
        [
            "name": "type",
            "description": "Type text into an input or editable field.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "The selector targeting the input element."
                    ],
                    "text": [
                        "type": "string",
                        "description": "The text to type into the field."
                    ]
                ],
                "required": ["selector", "text"]
            ]
        ],
        [
            "name": "press_key",
            "description": "Press a key on the keyboard, optionally targeting a specific element.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                        "description": "The key to press (e.g. 'Enter', 'Tab', 'Escape', 'ArrowDown')."
                    ],
                    "selector": [
                        "type": "string",
                        "description": "Optional selector targeting the element to focus before pressing."
                    ]
                ],
                "required": ["key"]
            ]
        ],
        [
            "name": "scroll",
            "description": "Scroll the page viewport or a scrollable element.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "direction": [
                        "type": "string",
                        "enum": ["up", "down", "left", "right"],
                        "description": "The direction to scroll."
                    ],
                    "amount": [
                        "type": "number",
                        "description": "Optional amount of pixels to scroll. Defaults to half the viewport height."
                    ],
                    "selector": [
                        "type": "string",
                        "description": "Optional selector targeting a specific scrollable element."
                    ]
                ],
                "required": ["direction"]
            ]
        ],
        [
            "name": "wait_for",
            "description": "Wait for a selector to match an element, or for text to be visible on the page.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "selector": [
                        "type": "string",
                        "description": "Optional selector to wait for."
                    ],
                    "text": [
                        "type": "string",
                        "description": "Optional text to wait for."
                    ],
                    "timeoutMs": [
                        "type": "number",
                        "description": "Optional max wait duration in milliseconds. Default 5000."
                    ]
                ]
            ]
        ],
        [
            "name": "get_content",
            "description": "Get the current page URL, title, selected text, and extracted readable text content.",
            "input_schema": [
                "type": "object",
                "properties": [:]
            ]
        ],
        [
            "name": "evaluate",
            "description": "Execute arbitrary Javascript in the page context and return the serialized result.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "script": [
                        "type": "string",
                        "description": "The Javascript code to execute."
                    ]
                ],
                "required": ["script"]
            ]
        ]
    ]

    init(apiKey: String, modelName: String, browserModel: BlinkBrowserWorkspaceModelProtocol) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = modelName
        self.browserModel = browserModel
    }

    /// Entry point to execute the CUA Agent loop.
    func run(prompt: String) async {
        guard let model = browserModel else { return }
        
        let useSDK = await MainActor.run {
            model.hasAgentSDK()
        }
        
        if useSDK {
            await runWithAgentSDK(prompt: prompt)
            return
        }
        
        var messages: [[String: Any]] = []
        
        // Retrieve initial context
        var userContentBlocks: [[String: Any]] = []
        
        var pageMeta = "No active page loaded yet."
        let tabContent = await getTabContentDetails()
        if let tabDetails = tabContent {
            pageMeta = "Current Tab URL: \(tabDetails["url"] as? String ?? "none")\n" +
                       "Page Title: \(tabDetails["title"] as? String ?? "Untitled")"
            if let selection = tabDetails["selection"] as? String, !selection.isEmpty {
                pageMeta += "\nSelected text: \(selection)"
            }
        }
        userContentBlocks.append(["type": "text", "text": "Page metadata:\n\(pageMeta)"])
        
        // Capture initial screenshot to seed Claude's sight
        if let screenshotData = await captureTabScreenshot() {
            let mediaType = detectImageMediaType(for: screenshotData)
            userContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": screenshotData.base64EncodedString()
                ]
            ])
        }
        
        userContentBlocks.append(["type": "text", "text": "Goal: \(prompt)"])
        messages.append(["role": "user", "content": userContentBlocks])
        
        let systemPrompt = """
        You are Blink's Browser CUA (Computer Use Agent), specializing in browser automation and page analysis.
        Your job is to interact with the active browser tab to achieve the user's goal.
        You can view the page visual layout using screenshots, locate and act on elements, and read page text.

        Guidelines:
        1. Always analyze the page screenshot first before acting.
        2. If you need to click, type, or interact, prefer using CSS, xpath, text, or contains selectors via the `click` or `type` tools.
        3. If an element is hard to select via selectors, you can use `click_at` with coordinates (x, y) visible on the page.
        4. If you navigate to a new page or perform an action that updates the view, you should call `screenshot` again to see the updated visual state.
        5. Provide a summary of your actions and the final answer to the user once you've successfully completed the task.
        """
        
        var loopCount = 0
        let maxLoops = 15
        
        while loopCount < maxLoops {
            loopCount += 1
            do {
                let response = try await callClaudeAPI(systemPrompt: systemPrompt, messages: messages)
                
                guard let content = response["content"] as? [[String: Any]] else {
                    appendAgentMessage(text: "I couldn't complete that in the browser because the model response was invalid.")
                    break
                }
                
                // Keep track of assistant content for the next conversation turn
                messages.append(["role": "assistant", "content": content])
                
                // Process assistant content blocks
                var textResponse = ""
                var toolCalls: [[String: Any]] = []
                
                for block in content {
                    let type = block["type"] as? String ?? ""
                    if type == "text" {
                        textResponse += block["text"] as? String ?? ""
                    } else if type == "tool_use" {
                        toolCalls.append(block)
                    }
                }
                
                if !textResponse.isEmpty {
                    appendAgentMessage(text: textResponse)
                }
                
                if toolCalls.isEmpty {
                    // No tools called, agent is done!
                    break
                }
                
                // Execute tool calls and collect results
                var toolResultBlocks: [[String: Any]] = []
                
                for toolCall in toolCalls {
                    guard let toolUseID = toolCall["id"] as? String,
                          let toolName = toolCall["name"] as? String,
                          let input = toolCall["input"] as? [String: Any] else {
                        continue
                    }
                    
                    let toolResult = await executeTool(name: toolName, input: input)
                    
                    var resultBlock: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": toolUseID
                    ]
                    
                    if toolResult.isError {
                        resultBlock["is_error"] = true
                    }
                    
                    if let image = toolResult.imageData {
                        // Return the screenshot directly in the tool result
                        let mediaType = detectImageMediaType(for: image)
                        resultBlock["content"] = [
                            [
                                "type": "text",
                                "text": toolResult.summary
                            ],
                            [
                                "type": "image",
                                "source": [
                                    "type": "base64",
                                    "media_type": mediaType,
                                    "data": image.base64EncodedString()
                                ]
                            ]
                        ]
                    } else {
                        resultBlock["content"] = toolResult.summary
                    }
                    
                    toolResultBlocks.append(resultBlock)
                }
                
                // Append tool results as a user turn
                messages.append(["role": "user", "content": toolResultBlocks])
                
            } catch {
                appendAgentMessage(text: "I couldn't complete that in the browser. Check the selected browser model/API setup and try again.")
                break
            }
        }
        
        if loopCount >= maxLoops {
            appendAgentMessage(text: "I couldn't finish that browser action within the step limit.")
        }
    }

    private struct ToolResult {
        let success: Bool
        let summary: String
        let isError: Bool
        let imageData: Data?
        
        static func success(summary: String, imageData: Data? = nil) -> ToolResult {
            return ToolResult(success: true, summary: summary, isError: false, imageData: imageData)
        }
        
        static func failure(summary: String) -> ToolResult {
            return ToolResult(success: false, summary: summary, isError: true, imageData: nil)
        }
    }

    // Router for executing tools on active tab
    private func executeTool(name: String, input: [String: Any]) async -> ToolResult {
        switch name {
        case "navigate":
            guard let url = input["url"] as? String else {
                return .failure(summary: "Missing required parameter: url")
            }
            return await executeNavigate(url: url)
            
        case "screenshot":
            if let screenshotData = await captureTabScreenshot() {
                return .success(summary: "Captured page layout screenshot.", imageData: screenshotData)
            } else {
                return .failure(summary: "Failed to capture page screenshot.")
            }
            
        case "click":
            guard let selector = input["selector"] as? String else {
                return .failure(summary: "Missing required parameter: selector")
            }
            return await runInjectedJSAction(kind: "click", selector: selector, value: nil)
            
        case "click_at":
            guard let x = input["x"] as? Double, let y = input["y"] as? Double else {
                return .failure(summary: "Missing required parameter: x, y")
            }
            return await runInjectedJSAction(kind: "click_at", selector: "\(x)", value: "\(y)")
            
        case "type":
            guard let selector = input["selector"] as? String,
                  let text = input["text"] as? String else {
                return .failure(summary: "Missing required parameter: selector, text")
            }
            return await runInjectedJSAction(kind: "type", selector: selector, value: text)
            
        case "press_key":
            guard let key = input["key"] as? String else {
                return .failure(summary: "Missing required parameter: key")
            }
            let selector = input["selector"] as? String
            return await runInjectedJSAction(kind: "press_key", selector: selector, value: key)
            
        case "scroll":
            guard let direction = input["direction"] as? String else {
                return .failure(summary: "Missing required parameter: direction")
            }
            let amount = input["amount"] as? Double
            let selector = input["selector"] as? String
            let val = amount != nil ? "\(amount!)" : direction
            return await runInjectedJSAction(kind: "scroll", selector: selector, value: val)
            
        case "wait_for":
            let selector = input["selector"] as? String
            let text = input["text"] as? String
            let timeoutMs = input["timeoutMs"] as? Double ?? 5000.0
            return await executeWaitFor(selector: selector, text: text, timeoutMs: timeoutMs)
            
        case "get_content":
            let result = await runInjectedJSAction(kind: "get_content", selector: nil, value: nil)
            return result
            
        case "evaluate":
            guard let script = input["script"] as? String else {
                return .failure(summary: "Missing required parameter: script")
            }
            return await executeEvaluate(script: script)
            
        default:
            return .failure(summary: "Unknown tool: \(name)")
        }
    }

    // MARK: - Specific Tool Handlers
    
    private func executeNavigate(url: String) async -> ToolResult {
        let lower = url.lowercased()
        var targetURL: URL?
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://") || lower.hasPrefix("open-blink://") {
            targetURL = URL(string: url)
        } else if url.contains(".") && !url.contains(" ") {
            targetURL = URL(string: "https://\(url)")
        }
        
        guard let targetURL = targetURL else {
            return .failure(summary: "Failed: Invalid URL format '\(url)'.")
        }
        
        await MainActor.run {
            _ = self.browserModel?.loadAddress(targetURL.absoluteString)
        }
        
        // Wait a second for navigation to initiate
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return .success(summary: "Successfully initiated navigation to \(targetURL.absoluteString).")
    }

    private func executeWaitFor(selector: String?, text: String?, timeoutMs: Double) async -> ToolResult {
        guard selector != nil || text != nil else {
            return .failure(summary: "Failed: Must specify either selector or text to wait for.")
        }
        
        let start = Date()
        let limit = timeoutMs / 1000.0
        let step = 0.25 // check every 250ms
        
        while Date().timeIntervalSince(start) < limit {
            if let sel = selector {
                let js = "document.querySelector(\(escapeJSString(sel))) !== null"
                if let exists = await evaluateRawJS(js) as? Bool, exists {
                    return .success(summary: "Element matching '\(sel)' appeared on the page.")
                }
            } else if let txt = text {
                let js = "document.body.innerText.toLowerCase().includes(\(escapeJSString(txt.lowercased())))"
                if let exists = await evaluateRawJS(js) as? Bool, exists {
                    return .success(summary: "Text '\(txt)' appeared on the page.")
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        
        let desc = selector != nil ? "element matching '\(selector!)'" : "text '\(text!)'"
        return .failure(summary: "Timed out waiting for \(desc) to appear after \(timeoutMs)ms.")
    }

    private func executeEvaluate(script: String) async -> ToolResult {
        do {
            if let result = try await evaluateRawJSWithThrowing(script) {
                return .success(summary: "Script evaluated. Result: \(result)")
            } else {
                return .success(summary: "Script evaluated successfully (no return value).")
            }
        } catch {
            return .failure(summary: "Javascript execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Injected Action Engine
    
    private func runInjectedJSAction(kind: String, selector: String?, value: String?) async -> ToolResult {
        let script = CuaInjectedScriptGenerator.generateScript(actionKind: kind, selector: selector, value: value)
        
        do {
            let result = try await evaluateRawJSWithThrowing(script)
            guard let dict = result as? [String: Any] else {
                return .failure(summary: "Invalid response from page actions script.")
            }
            
            let success = dict["success"] as? Bool ?? false
            let summary = dict["summary"] as? String ?? dict["error"] as? String ?? "Done."
            
            if success {
                // If it is get_content, summarize the content
                if kind == "get_content" {
                    let pageTitle = dict["title"] as? String ?? "Untitled"
                    let pageURL = dict["url"] as? String ?? "none"
                    return .success(summary: "Extracted content for tab: '\(pageTitle)' (\(pageURL)).")
                }
                return .success(summary: summary)
            } else {
                return .failure(summary: "Failed: \(summary)")
            }
        } catch {
            return .failure(summary: "Execution error on webpage: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Bridges
    
    private func getTabContentDetails() async -> [String: Any]? {
        let script = CuaInjectedScriptGenerator.generateScript(actionKind: "get_content", selector: nil, value: nil)
        if let result = await evaluateRawJS(script) as? [String: Any] {
            return result
        }
        return nil
    }

    private func evaluateRawJS(_ js: String) async -> Any? {
        do {
            return try await evaluateRawJSWithThrowing(js)
        } catch {
            return nil
        }
    }

    private func evaluateRawJSWithThrowing(_ js: String) async throws -> Any? {
        guard let webView = await getActiveWebView() else {
            throw NSError(domain: "BrowserAgent", code: -101, userInfo: [NSLocalizedDescriptionKey: "No active WKWebView tab loaded."])
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func getActiveWebView() async -> WKWebView? {
        await MainActor.run {
            self.browserModel?.getActiveWebView()
        }
    }

    private func captureTabScreenshot() async -> Data? {
        await self.browserModel?.captureActiveTabScreenshot()
    }

    // MARK: - UI Message Dispatchers
    
    private func appendAgentMessage(text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        
        Task { @MainActor in
            self.browserModel?.appendAgentMessage(text: cleaned)
        }
    }

    private func updateAgentStatusMessage(text: String) {
        // Browser-agent progress is intentionally not surfaced as chat bubbles.
        // The side chat should look like normal Blink chat: user prompt in,
        // final answer or concise failure out.
    }

    // MARK: - Networking
    
    private func callClaudeAPI(systemPrompt: String, messages: [[String: Any]]) async throws -> [String: Any] {
        let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 4000,
            "system": systemPrompt,
            "messages": messages,
            "tools": Self.tools
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "BrowserAgent", code: -102, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP status \(httpResponse.statusCode)"
            throw NSError(domain: "BrowserAgent", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude API Error: \(errorText)"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "BrowserAgent", code: -103, userInfo: [NSLocalizedDescriptionKey: "Failed to parse API response as JSON."])
        }
        
        return json
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private func escapeJSString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    private func runWithAgentSDK(prompt: String) async {
        guard let model = browserModel else { return }
        
        var sdkHistory: [(userPlaceholder: String, assistantResponse: String)] = []
        
        var loopCount = 0
        let maxLoops = 15
        
        var pageMeta = "No active page loaded yet."
        let tabContent = await getTabContentDetails()
        if let tabDetails = tabContent {
            pageMeta = "Current Tab URL: \(tabDetails["url"] as? String ?? "none")\n" +
                       "Page Title: \(tabDetails["title"] as? String ?? "Untitled")"
            if let selection = tabDetails["selection"] as? String, !selection.isEmpty {
                pageMeta += "\nSelected text: \(selection)"
            }
        }
        
        let initialUserPrompt = "Goal: \(prompt)\n\nPage metadata:\n\(pageMeta)"
        var currentImages: [(data: Data, label: String)] = []
        if let screenshotData = await captureTabScreenshot() {
            currentImages.append((screenshotData, "current_screen"))
        }
        
        let sdkSystemPrompt = """
        You are Blink's Browser CUA (Computer Use Agent), specializing in browser automation.
        Your job is to interact with the active browser tab to achieve the user's goal.
        You can view the page visual layout using screenshots, locate and act on elements, and read page text.

        To execute an action, you MUST reply with a JSON object of the form:
        {
          "tool": "tool_name",
          "input": { ... }
        }

        Do not write any conversational text or explanations outside the JSON object when you want to execute a tool. Reply with ONLY the JSON object.

        AVAILABLE TOOLS:
        1. {"name": "navigate", "description": "Navigate to a URL.", "input_schema": {"properties": {"url": {"type": "string"}}, "required": ["url"]}}
        2. {"name": "click", "description": "Click an element by CSS or text selector.", "input_schema": {"properties": {"selector": {"type": "string"}}, "required": ["selector"]}}
        3. {"name": "click_at", "description": "Click at relative coordinate x, y.", "input_schema": {"properties": {"x": {"type": "number"}, "y": {"type": "number"}}, "required": ["x", "y"]}}
        4. {"name": "type", "description": "Type text into selector.", "input_schema": {"properties": {"selector": {"type": "string"}, "text": {"type": "string"}}, "required": ["selector", "text"]}}
        5. {"name": "press_key", "description": "Press a key (e.g. Enter).", "input_schema": {"properties": {"key": {"type": "string"}, "selector": {"type": "string"}}, "required": ["key"]}}
        6. {"name": "scroll", "description": "Scroll the page.", "input_schema": {"properties": {"direction": {"type": "string", "enum": ["up", "down", "left", "right"]}, "amount": {"type": "number"}, "selector": {"type": "string"}}, "required": ["direction"]}}
        7. {"name": "wait_for", "description": "Wait for selector or text.", "input_schema": {"properties": {"selector": {"type": "string"}, "text": {"type": "string"}, "timeoutMs": {"type": "number"}}}}
        8. {"name": "get_content", "description": "Get current page URL, title, and text content.", "input_schema": {}}

        Example Response to click a button:
        {
          "tool": "click",
          "input": {
            "selector": "button#submit"
          }
        }

        Once the user's goal has been achieved successfully, output a natural conversational response explaining that you are finished.
        """
        
        var nextUserPrompt = initialUserPrompt
        
        while loopCount < maxLoops {
            loopCount += 1
            do {
                let responseText = try await model.analyzeImageWithAgentSDK(
                    images: currentImages,
                    systemPrompt: sdkSystemPrompt,
                    conversationHistory: sdkHistory,
                    userPrompt: nextUserPrompt,
                    onTextChunk: { chunk in
                        // Can stream updates if needed
                    }
                )
                
                // Track this turn in sdkHistory
                sdkHistory.append((nextUserPrompt, responseText))
                
                // Parse tool call from response
                if let toolCall = parseJSONToolCall(from: responseText) {
                    let toolName = toolCall.name
                    let input = toolCall.input
                    
                    let toolResult = await executeTool(name: toolName, input: input)
                    
                    // Capture a new screenshot for the next step
                    currentImages.removeAll()
                    if let screenshotData = await captureTabScreenshot() {
                        currentImages.append((screenshotData, "current_screen"))
                    }
                    
                    nextUserPrompt = "Tool '\(toolName)' executed with result: \(toolResult.summary)"
                } else {
                    // No valid JSON tool call was parsed from responseText, so print response and stop
                    appendAgentMessage(text: responseText)
                    break
                }
                
            } catch {
                appendAgentMessage(text: "I couldn't complete that in the browser. Check the selected browser model/API setup and try again.")
                break
            }
        }
        
        if loopCount >= maxLoops {
            appendAgentMessage(text: "I couldn't finish that browser action within the step limit.")
        }
    }

    private func parseJSONToolCall(from text: String) -> (name: String, input: [String: Any])? {
        guard let start = text.range(of: "{"),
              let end = text.range(of: "}", options: .backwards),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        
        let jsonStr = String(text[start.lowerBound...end.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["tool"] as? String,
              let input = dict["input"] as? [String: Any] else {
            return nil
        }
        
        return (name, input)
    }
}

// MARK: - Script Generator

private enum CuaInjectedScriptGenerator {
    static func generateScript(actionKind: String, selector: String?, value: String?) -> String {
        let selectorJSON = selector != nil ? escapeJSString(selector!) : "null"
        let valueJSON = value != nil ? escapeJSString(value!) : "null"
        
        return """
        (() => {
          const specRaw = \(selectorJSON);
          const actionKind = "\(actionKind)";
          const value = \(valueJSON);
          
          const stripQuotes = (val) => {
            const t = val.trim();
            if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
              return t.slice(1, -1);
            }
            return t;
          };
          
          const parseSelectorSpec = (raw) => {
            const trimmed = String(raw || '').trim();
            const lower = trimmed.toLowerCase();
            if (lower.startsWith('css=')) {
              return { kind: 'css', selector: trimmed.slice(4).trim() };
            }
            if (lower.startsWith('xpath=')) {
              return { kind: 'xpath', xpath: trimmed.slice(6).trim() };
            }
            const textMatch = /^text\\s*=\\s*(.+)$/i.exec(trimmed);
            if (textMatch) {
              return { kind: 'text', text: stripQuotes(textMatch[1]).trim() };
            }
            const containsDotQuoted = /^([a-zA-Z][\\\\w-]*)\\s*\\.\\s*contains\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (containsDotQuoted) {
              return { kind: 'contains', base: containsDotQuoted[1], text: containsDotQuoted[3].trim() };
            }
            const containsDotBare = /^([a-zA-Z][\\\\w-]*)\\s*\\.\\s*contains\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (containsDotBare) {
              return { kind: 'contains', base: containsDotBare[1], text: String(containsDotBare[2] || '').trim() };
            }
            const pseudoContainsQuoted = /^(.+?):\\s*contains\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoContainsQuoted) {
              return { kind: 'contains', base: pseudoContainsQuoted[1].trim(), text: pseudoContainsQuoted[3].trim() };
            }
            const pseudoContainsBare = /^(.+?):\\s*contains\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoContainsBare) {
              return { kind: 'contains', base: pseudoContainsBare[1].trim(), text: String(pseudoContainsBare[2] || '').trim() };
            }
            const pseudoHasTextQuoted = /^(.+?):\\s*has-text\\s*\\(\\s*(['"])([\\\\s\\\\S]*?)\\2\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoHasTextQuoted) {
              return { kind: 'contains', base: pseudoHasTextQuoted[1].trim(), text: pseudoHasTextQuoted[3].trim() };
            }
            const pseudoHasTextBare = /^(.+?):\\s*has-text\\s*\\(\\s*([\\\\s\\\\S]*?)\\s*\\)\\s*$/.exec(trimmed);
            if (pseudoHasTextBare) {
              return { kind: 'contains', base: pseudoHasTextBare[1].trim(), text: String(pseudoHasTextBare[2] || '').trim() };
            }
            return { kind: 'css', selector: trimmed };
          };

          const isVisible = (el) => {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            const style = window.getComputedStyle(el);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            if (parseFloat(style.opacity || '1') === 0) return false;
            return true;
          };

          const deepQuerySelectorAll = (css, maxNodes = 25000) => {
            const out = [];
            let parsedOk = true;
            try {
              document.querySelector(css);
            } catch {
              parsedOk = false;
            }
            if (!parsedOk) return out;

            const stack = [document];
            let visited = 0;
            while (stack.length && visited < maxNodes) {
              const node = stack.pop();
              if (node instanceof Element) {
                visited += 1;
                try {
                  if (node.matches(css)) out.push(node);
                } catch {}
                const sr = node.shadowRoot;
                if (sr) stack.push(sr);
                for (const child of Array.from(node.children)) stack.push(child);
              } else {
                const children = node instanceof Document ? [node.documentElement] : Array.from(node.children);
                for (const child of children) if (child) stack.push(child);
              }
            }
            return out;
          };

          const findByText = (text, baseSelector = '', allowDeepSearch = true) => {
            const wanted = String(text || '').replace(/\\s+/g, ' ').trim().toLowerCase();
            if (!wanted) return { el: null, candidates: 0 };
            
            let preferred = [];
            if (baseSelector) {
              try {
                preferred = Array.from(document.querySelectorAll(baseSelector));
              } catch (e) {
                if (allowDeepSearch) preferred = deepQuerySelectorAll(baseSelector);
              }
            } else {
              preferred = Array.from(document.querySelectorAll('a, button, input, [role="button"], [role="link"], summary'));
            }
            
            const pool = preferred.length > 0 ? preferred : Array.from(document.querySelectorAll('body *'));
            let best = null;
            let bestScore = -1;
            let seen = 0;
            
            for (const el of pool) {
              if (!(el instanceof HTMLElement)) continue;
              if (!isVisible(el)) continue;
              const txt = String(el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase();
              if (!txt) continue;
              if (!txt.includes(wanted)) continue;
              seen += 1;
              
              const tag = el.tagName.toLowerCase();
              let score = 1;
              if (tag === 'button') score += 4;
              if (tag === 'a') score += 3;
              if (tag === 'input') score += 2;
              if (el.getAttribute('role') === 'button') score += 2;
              if (score > bestScore) {
                best = el;
                bestScore = score;
              }
            }
            return { el: best, candidates: seen };
          };

          const resolveElement = (spec, allowDeepSearch) => {
            if (!spec) return { el: null, strategy: 'none', candidates: 0, error: 'Missing selector.' };
            
            if (spec.kind === 'xpath') {
              const expr = String(spec.xpath || '').trim();
              try {
                const res = document.evaluate(expr, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null);
                const node = res.singleNodeValue;
                if (node && node instanceof HTMLElement) return { el: node, strategy: 'xpath', candidates: 1 };
                return { el: null, strategy: 'xpath', candidates: 0, error: 'Element not found.' };
              } catch (e) {
                return { el: null, strategy: 'xpath', candidates: 0, error: 'Invalid XPath.', hint: e.message };
              }
            }
            
            if (spec.kind === 'text') {
              const { el, candidates } = findByText(spec.text, '', allowDeepSearch);
              return el ? { el, strategy: 'text', candidates } : { el: null, strategy: 'text', candidates, error: 'Element not found.' };
            }
            
            if (spec.kind === 'contains') {
              const { el, candidates } = findByText(spec.text, spec.base, allowDeepSearch);
              return el ? { el, strategy: 'contains', candidates } : { el: null, strategy: 'contains', candidates, error: 'Element not found.' };
            }
            
            const css = String(spec.selector || '').trim();
            try {
              const matches = Array.from(document.querySelectorAll(css));
              const vis = matches.filter(isVisible);
              const el = vis[0] || matches[0] || null;
              if (el) return { el, strategy: 'css', candidates: matches.length };
            } catch (e) {
              return { el: null, strategy: 'css', candidates: 0, error: 'Invalid selector.', hint: e.message };
            }
            
            if (allowDeepSearch) {
              const deep = deepQuerySelectorAll(css);
              const deepVis = deep.filter(isVisible);
              const el = deepVis[0] || deep[0] || null;
              if (el) return { el, strategy: 'css(deep)', candidates: deep.length };
            }
            
            return { el: null, strategy: 'css', candidates: 0, error: 'Element not found.' };
          };

          const doClick = (el) => {
            try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch(e){}
            try { el.focus({ preventScroll: true }); } catch(e){}
            
            const rect = el.getBoundingClientRect();
            const cx = Math.max(1, Math.min(window.innerWidth - 2, rect.left + rect.width / 2));
            const cy = Math.max(1, Math.min(window.innerHeight - 2, rect.top + rect.height / 2));
            const top = document.elementFromPoint(cx, cy);
            const target = top && (top === el || el.contains(top)) ? top : el;
            
            const fire = (type, cls) => {
              try {
                const ev = new cls(type, { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 0 });
                target.dispatchEvent(ev);
              } catch(e){}
            };
            
            fire('pointerover', window.PointerEvent || MouseEvent);
            fire('mouseover', MouseEvent);
            fire('pointerdown', window.PointerEvent || MouseEvent);
            fire('mousedown', MouseEvent);
            fire('pointerup', window.PointerEvent || MouseEvent);
            fire('mouseup', MouseEvent);
            fire('click', MouseEvent);
            try { target.click(); } catch(e){}
            return { success: true, clickedTagName: target.tagName, x: cx, y: cy };
          };

          const doType = (el, text) => {
            try { el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch(e){}
            try { el.focus({ preventScroll: true }); } catch(e){}
            
            const resolveEditable = (candidate) => {
              if (!candidate) return null;
              if (candidate instanceof HTMLInputElement || candidate instanceof HTMLTextAreaElement || candidate.isContentEditable) {
                return candidate;
              }
              return candidate.querySelector('textarea, input, [contenteditable="true"], [contenteditable=""], [role="textbox"]');
            };
            
            const editable = resolveEditable(el);
            if (!editable) return { success: false, error: 'Target element is not inputable/editable.' };
            
            if (editable instanceof HTMLInputElement || editable instanceof HTMLTextAreaElement) {
              if (editable.type === 'checkbox' || editable.type === 'radio') {
                return { success: false, error: 'Element is a checkbox/radio, use click instead.' };
              }
              
              if (typeof editable.select === 'function') {
                try { editable.select(); } catch(e){}
              }
              
              const setVal = (tgt, val) => {
                const proto = Object.getPrototypeOf(tgt);
                const desc = Object.getOwnPropertyDescriptor(proto, 'value');
                if (desc && desc.set) {
                  desc.set.call(tgt, val);
                } else {
                  tgt.value = val;
                }
              };
              
              setVal(editable, text);
              
              const dispatch = (type, cls, opts) => {
                try { editable.dispatchEvent(new cls(type, opts)); } catch(e){}
              };
              
              dispatch('input', InputEvent, { bubbles: true, inputType: 'insertText', data: text });
              dispatch('change', Event, { bubbles: true });
              return { success: true };
            }
            
            if (editable.isContentEditable) {
              const selection = window.getSelection();
              if (selection) {
                selection.removeAllRanges();
                const range = document.createRange();
                range.selectNodeContents(editable);
                selection.addRange(range);
              }
              document.execCommand?.('insertText', false, text);
              if (editable.textContent !== text) {
                editable.textContent = text;
              }
              editable.dispatchEvent(new Event('input', { bubbles: true }));
              editable.dispatchEvent(new Event('change', { bubbles: true }));
              return { success: true };
            }
            return { success: false, error: 'Target is not editable.' };
          };

          try {
            if (actionKind === 'get_content') {
              const visibleText = document.body ? document.body.innerText : '';
              const selection = window.getSelection() ? window.getSelection().toString() : '';
              return {
                success: true,
                url: window.location.href,
                title: document.title,
                selection: selection,
                readableText: visibleText.slice(0, 10000)
              };
            }
            
            if (actionKind === 'scroll') {
              let scrollTarget = window;
              if (specRaw) {
                const spec = parseSelectorSpec(specRaw);
                const res = resolveElement(spec, true);
                if (res.el) scrollTarget = res.el;
              }
              
              const amt = value ? parseFloat(value) : window.innerHeight / 2;
              let dx = 0, dy = 0;
              const dir = String(value || 'down').toLowerCase();
              if (dir === 'up') dy = -amt;
              else if (dir === 'down') dy = amt;
              else if (dir === 'left') dx = -amt;
              else if (dir === 'right') dx = amt;
              
              if (scrollTarget === window) {
                window.scrollBy({ left: dx, top: dy, behavior: 'instant' });
              } else {
                scrollTarget.scrollLeft += dx;
                scrollTarget.scrollTop += dy;
              }
              return { success: true, summary: `Scrolled ${dir} by ${amt}px.` };
            }
            
            if (actionKind === 'press_key') {
              let target = document.activeElement || document.body;
              if (specRaw) {
                const spec = parseSelectorSpec(specRaw);
                const res = resolveElement(spec, true);
                if (res.el) target = res.el;
              }
              const key = String(value || 'Enter');
              const fireKey = (type) => {
                const ev = new KeyboardEvent(type, { key: key, code: key, bubbles: true, cancelable: true });
                target.dispatchEvent(ev);
              };
              fireKey('keydown');
              fireKey('keypress');
              fireKey('keyup');
              return { success: true, summary: `Pressed key '${key}' on target.` };
            }
            
            if (actionKind === 'click_at') {
              const cx = parseFloat(specRaw);
              const cy = parseFloat(value);
              const target = document.elementFromPoint(cx, cy) || document.body;
              const fire = (type, cls) => {
                try {
                  const ev = new cls(type, { bubbles: true, cancelable: true, view: window, clientX: cx, clientY: cy, button: 0 });
                  target.dispatchEvent(ev);
                } catch(e){}
              };
              fire('pointerover', window.PointerEvent || MouseEvent);
              fire('mouseover', MouseEvent);
              fire('pointerdown', window.PointerEvent || MouseEvent);
              fire('mousedown', MouseEvent);
              fire('pointerup', window.PointerEvent || MouseEvent);
              fire('mouseup', MouseEvent);
              fire('click', MouseEvent);
              try { target.click(); } catch(e){}
              return { success: true, summary: `Clicked coordinate (${cx}, ${cy}) targeting tag ${target.tagName}.` };
            }

            const spec = parseSelectorSpec(specRaw);
            const res = resolveElement(spec, true);
            if (!res.el) {
              return { success: false, error: res.error || 'Element not found.', strategy: res.strategy, candidates: res.candidates };
            }
            
            if (actionKind === 'click') {
              const clickRes = doClick(res.el);
              const name = res.el.innerText || res.el.value || res.el.getAttribute('aria-label') || res.el.id || res.el.tagName;
              return { ...clickRes, summary: `Successfully clicked element: "${name.substring(0, 30).trim()}"` };
            }
            
            if (actionKind === 'type') {
              const typeRes = doType(res.el, value);
              const name = res.el.placeholder || res.el.name || res.el.id || res.el.tagName;
              return { ...typeRes, summary: typeRes.success ? `Typed content into: "${name.substring(0, 30).trim()}"` : typeRes.error };
            }
            
            return { success: false, error: `Unknown action: ${actionKind}` };
          } catch (err) {
            return { success: false, error: err.message };
          }
        })();
        """
    }

    private static func escapeJSString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}
