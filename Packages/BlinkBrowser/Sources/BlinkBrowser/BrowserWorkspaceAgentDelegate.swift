import Foundation

public protocol BrowserWorkspaceAgentSessionProtocol {
    var id: UUID { get }
    var title: String { get }
}

@MainActor
public protocol BrowserWorkspaceAgentDelegate: AnyObject {
    func hasLinkedAgentSession(id: UUID) -> Bool
    func selectCodexAgentSession(_ id: UUID)
    func submitAgentPromptFromUI(_ prompt: String)
    func submitNewAgentTaskFromUI(_ prompt: String, source: String) -> BrowserWorkspaceAgentSessionProtocol?
    func hasAgentSDK() -> Bool
    func analyzeImageWithAgentSDK(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> String
    
    // Config and Models providers
    func getAnthropicAPIKey() -> String
    func getSelectedComputerUseModelID() -> String
    func selectedComputerUseModelUsesAnthropic() -> Bool
}
