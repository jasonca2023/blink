import Foundation

enum BlinkModelProvider: String, Equatable {
    case anthropic
    case openAI
    case codex
    case deepgram

    var displayName: String {
        switch self {
        case .anthropic:
            return "Anthropic"
        case .openAI:
            return "OpenAI"
        case .codex:
            return "Codex"
        case .deepgram:
            return "Deepgram"
        }
    }
}

struct BlinkModelOption: Identifiable, Equatable {
    let id: String
    let label: String
    let provider: BlinkModelProvider
    /// Published maximum generated output tokens for this model.
    /// For Anthropic this maps to `max_tokens`; for OpenAI Responses this maps to `max_output_tokens`.
    let maxOutputTokens: Int
}

enum BlinkModelCatalog {
    /// Fast conversational responder. Used for the always-on voice loop —
    /// hears you, decides whether to delegate, narrates progress.
    /// Haiku 4.5 has ~150-250ms TTFT vs ~400-600ms for Sonnet.
    static let defaultVoiceResponseModelID = "claude-haiku-4-5"
    static let defaultSpeechModelID = "gpt-realtime-2"
    /// Heavier model used when the voice responder delegates a coding/agent task.
    /// Coding work goes here; the voice path stays on the fast model.
    static let defaultDelegationModelID = "claude-sonnet-4-6"
    static let defaultComputerUseModelID = "claude-sonnet-4-6"
    // gpt-5-codex is the publicly-available OpenAI Codex model accessible
    // to standard project keys. Earlier defaults referenced "gpt-5.4",
    // which isn't a real model id and surfaced as 401 invalid_api_key on
    // /v1/responses for fresh installs.
    static let defaultCodexActionsModelID = "gpt-5-codex"

    /// Resolves the delegation model — falls back to a sensible coder
    /// when the user hasn't picked one explicitly.
    static func delegationModel(withID modelID: String?) -> BlinkModelOption {
        if let modelID, let match = voiceResponseModels.first(where: { $0.id == modelID }) {
            return match
        }
        return voiceResponseModel(withID: defaultDelegationModelID)
    }

    static let voiceResponseModels: [BlinkModelOption] = [
        // Voice turns should be short, stream quickly, and hand off deep work
        // to Agent Mode. Large 64k/128k generation budgets add latency risk
        // and are unnecessary for spoken responses.
        BlinkModelOption(id: "claude-haiku-4-5", label: "Claude Haiku", provider: .anthropic, maxOutputTokens: 1_200),
        BlinkModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 1_200),
        BlinkModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 1_200),
        BlinkModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 1_200),
        BlinkModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 1_200),
        BlinkModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 1_200),
        BlinkModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 1_200)
    ]

    static let speechModels: [BlinkModelOption] = [
        // Realtime models are speech-to-speech response models. When one
        // is selected as the response voice model, it owns both the spoken
        // reply generation and the audio playback path instead of chaining
        // a separate text model into TTS.
        BlinkModelOption(id: "gpt-realtime-2", label: "GPT Realtime 2", provider: .openAI, maxOutputTokens: 1_200),
        BlinkModelOption(id: "gpt-realtime-1.5", label: "GPT Realtime 1.5", provider: .openAI, maxOutputTokens: 1_200),
        BlinkModelOption(id: "deepgram-voice-agent", label: "Deepgram Voice Agent", provider: .deepgram, maxOutputTokens: 1_200)
    ]

    static let responseVoiceModels: [BlinkModelOption] = speechModels + voiceResponseModels

    static let computerUseModels: [BlinkModelOption] = [
        BlinkModelOption(id: "claude-sonnet-4-6", label: "Claude Sonnet", provider: .anthropic, maxOutputTokens: 64_000),
        BlinkModelOption(id: "claude-opus-4-6", label: "Claude Opus", provider: .anthropic, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .codex, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .codex, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .codex, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .codex, maxOutputTokens: 128_000)
    ]

    static let codexActionsModels: [BlinkModelOption] = [
        BlinkModelOption(id: "gpt-5.5", label: "GPT-5.5", provider: .openAI, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.4", label: "GPT-5.4", provider: .openAI, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.4-mini", label: "GPT-5.4 Mini", provider: .openAI, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.3-codex", label: "GPT-5.3 Codex", provider: .openAI, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.2-codex", label: "GPT-5.2 Codex", provider: .openAI, maxOutputTokens: 128_000),
        BlinkModelOption(id: "gpt-5.2", label: "GPT-5.2", provider: .openAI, maxOutputTokens: 128_000)
    ]

    static func voiceResponseModel(withID modelID: String) -> BlinkModelOption {
        responseVoiceModels.first { $0.id == modelID } ?? voiceResponseModels[0]
    }

    static func isSpeechModelID(_ modelID: String) -> Bool {
        speechModels.contains { $0.id == modelID }
    }

    static func speechModel(withID modelID: String?) -> BlinkModelOption {
        if let modelID, let match = speechModels.first(where: { $0.id == modelID }) {
            return match
        }
        return speechModels.first { $0.id == defaultSpeechModelID } ?? speechModels[0]
    }

    static func computerUseModel(withID modelID: String) -> BlinkModelOption {
        computerUseModels.first { $0.id == modelID } ?? computerUseModels[0]
    }

    static func codexActionsModel(withID modelID: String) -> BlinkModelOption {
        codexActionsModels.first { $0.id == modelID } ?? codexActionsModels[0]
    }
}
