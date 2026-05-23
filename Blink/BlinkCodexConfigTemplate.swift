import Foundation

enum BlinkAgentBackendKind: String {
    case openAI = "openai"
    case huggingFace = "huggingface"

    static let userDefaultsKey = "blinkAgentBackend"

    static func current() -> BlinkAgentBackendKind {
        if let raw = ProcessInfo.processInfo.environment["BLINK_AGENT_BACKEND"],
           let kind = BlinkAgentBackendKind(rawValue: raw.lowercased()) {
            return kind
        }
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let kind = BlinkAgentBackendKind(rawValue: raw.lowercased()) {
            return kind
        }
        return .openAI
    }
}

struct BlinkCodexConfigTemplate: Equatable {
    static let defaultModelProviderID = "openai"
    static let customModelProviderID = "blink"
    static let huggingFaceProviderID = "huggingface"

    static let huggingFaceDefaultModel = "Qwen/Qwen2.5-Coder-32B-Instruct"

    var model: String
    var reasoningEffort: String
    var workerBaseURL: URL
    var backendKind: BlinkAgentBackendKind
    var modelInstructionsFileName: String
    var bundledSkillsDirectoryName: String
    var learnedSkillsDirectoryName: String
    var includeOpenAIDeveloperDocsMCP: Bool
    var cuaDriverMCPCommand: String?

    init(
        model: String = BlinkModelCatalog.defaultCodexActionsModelID,
        reasoningEffort: String = "medium",
        workerBaseURL: URL = BlinkCodexBackend.configuredWorkerBaseURL(),
        backendKind: BlinkAgentBackendKind = BlinkAgentBackendKind.current(),
        modelInstructionsFileName: String = "BlinkModelInstructions.md",
        bundledSkillsDirectoryName: String = "BlinkBundledSkills",
        learnedSkillsDirectoryName: String = "BlinkLearnedSkills",
        includeOpenAIDeveloperDocsMCP: Bool = true,
        cuaDriverMCPCommand: String? = CuaDriverMCPConfiguration.resolvedCommandPath()
    ) {
        self.model = Self.effectiveModel(model, for: backendKind)
        self.reasoningEffort = reasoningEffort
        self.workerBaseURL = workerBaseURL
        self.backendKind = backendKind
        self.modelInstructionsFileName = modelInstructionsFileName
        self.bundledSkillsDirectoryName = bundledSkillsDirectoryName
        self.learnedSkillsDirectoryName = learnedSkillsDirectoryName
        self.includeOpenAIDeveloperDocsMCP = includeOpenAIDeveloperDocsMCP
        self.cuaDriverMCPCommand = cuaDriverMCPCommand
    }

    var openAICompatibleEndpoint: URL {
        if workerBaseURL.lastPathComponent == "v1" {
            return workerBaseURL
        }
        return workerBaseURL.appendingPathComponent("v1", isDirectory: false)
    }

    var modelProviderID: String {
        switch backendKind {
        case .openAI:
            return BlinkCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) ? Self.defaultModelProviderID : Self.customModelProviderID
        case .huggingFace:
            return Self.huggingFaceProviderID
        }
    }

    func render() -> String {
        var lines: [String] = [
            "model = \"\(escape(model))\"",
            "model_reasoning_effort = \"\(escape(reasoningEffort))\"",
            "model_provider = \"\(modelProviderID)\"",
            "preferred_auth_method = \"\(preferredAuthMethod)\"",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "personality = \"friendly\"",
            "cli_auth_credentials_store = \"file\"",
            "history.persistence = \"save-all\"",
            "",
            "[analytics]",
            "enabled = false"
        ]

        switch backendKind {
        case .openAI:
            if !BlinkCodexBackend.isDefaultOpenAIBaseURL(workerBaseURL) {
                lines.append(contentsOf: [
                    "",
                    "[model_providers.\(Self.customModelProviderID)]",
                    "name = \"Blink\"",
                    "env_key = \"OPENAI_API_KEY\"",
                    "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
                    "wire_api = \"responses\"",
                    "trust_level = \"trusted\"",
                    "hide_full_access_warning = true",
                    "fast_mode = true",
                    "multi_agent = true"
                ])
            }
        case .huggingFace:
            // Codex CLI dropped `wire_api = "chat"` in late 2026 and now
            // only accepts `"responses"` (the OpenAI Responses API). HF
            // doesn't speak Responses, so Codex+HF cannot work directly.
            // Emit "responses" so Codex loads the config without crashing,
            // and surface a comment pointing the user at the Live agent
            // control panel — that path talks to HF via chat completions
            // directly and does not go through Codex.
            lines.append(contentsOf: [
                "",
                "# HuggingFace cannot be used as a Codex provider: Codex requires",
                "# the OpenAI Responses API, which HF does not implement.",
                "# Use Settings -> Agent Mode -> Live agent control for HF tasks.",
                "[model_providers.\(Self.huggingFaceProviderID)]",
                "name = \"HuggingFace (Codex incompatible — use Live agent control)\"",
                "env_key = \"HUGGINGFACE_API_KEY\"",
                "base_url = \"\(escape(openAICompatibleEndpoint.absoluteString))\"",
                "wire_api = \"responses\"",
                "trust_level = \"trusted\"",
                "hide_full_access_warning = true"
            ])
        }

        if includeOpenAIDeveloperDocsMCP, backendKind == .openAI {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.openaiDeveloperDocs]",
                "url = \"https://developers.openai.com/mcp\""
            ])
        }

        if let cuaDriverMCPCommand = normalizedOptionalString(cuaDriverMCPCommand) {
            lines.append(contentsOf: [
                "",
                "[mcp_servers.cuaDriver]",
                "command = \"\(escape(cuaDriverMCPCommand))\"",
                "args = [\"mcp\"]",
                "",
                "[mcp_servers.cuaDriver.env]",
                "CUA_DRIVER_TELEMETRY_ENABLED = \"false\"",
                "CUA_TELEMETRY_ENABLED = \"false\""
            ])
        }

        lines.append(contentsOf: [
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(bundledSkillsDirectoryName))\"",
            "enabled = true",
            "",
            "[[skills.config]]",
            "model_instructions_file = \"\(escape(modelInstructionsFileName))\"",
            "bundled_skills_dir = \"\(escape(learnedSkillsDirectoryName))\"",
            "enabled = true"
        ])

        return lines.joined(separator: "\n") + "\n"
    }

    private var preferredAuthMethod: String {
        return "apikey"
    }

    private func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// HF needs a HuggingFace repo-style model ID. If the caller passed an
    /// OpenAI-style ID (e.g. `gpt-5-codex`), substitute the HF default so
    /// requests don't fail with "unknown model".
    private static func effectiveModel(_ requested: String, for backend: BlinkAgentBackendKind) -> String {
        switch backend {
        case .openAI:
            return requested
        case .huggingFace:
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return huggingFaceDefaultModel }
            if trimmed.contains("/") { return trimmed }
            return huggingFaceDefaultModel
        }
    }
}

enum CuaDriverMCPConfiguration {
    static let environmentOverrideKey = "BLINK_CUA_DRIVER_MCP_COMMAND"
    static let knownCommandPaths = [
        "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
        "/usr/local/bin/cua-driver",
        "/opt/homebrew/bin/cua-driver"
    ]

    static func resolvedCommandPath(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = normalized(environment[environmentOverrideKey]) {
            return override
        }

        return knownCommandPaths.first { fileManager.isExecutableFile(atPath: $0) || fileManager.fileExists(atPath: $0) }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum BlinkCodexBackend {
    static let defaultOpenAIBaseURL = URL(string: "https://api.openai.com/v1")!
    static let huggingFaceRouterBaseURL = URL(string: "https://router.huggingface.co/v1")!

    static func configuredWorkerBaseURL() -> URL {
        switch BlinkAgentBackendKind.current() {
        case .huggingFace:
            return huggingFaceRouterBaseURL
        case .openAI:
            if let raw = ProcessInfo.processInfo.environment["BLINK_AGENT_BASE_URL"],
               let url = URL(string: raw),
               url.scheme != nil {
                return url
            }

            if let raw = UserDefaults.standard.string(forKey: "blinkAgentBaseURL"),
               let url = URL(string: raw),
               url.scheme != nil {
                return url
            }

            return defaultOpenAIBaseURL
        }
    }

    static func isDefaultOpenAIBaseURL(_ url: URL) -> Bool {
        normalizedBaseURL(url) == normalizedBaseURL(defaultOpenAIBaseURL)
    }

    private static func normalizedBaseURL(_ url: URL) -> String {
        var normalized = url.absoluteString
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if !normalized.hasSuffix("/v1") {
            normalized += "/v1"
        }
        return normalized.lowercased()
    }
}
