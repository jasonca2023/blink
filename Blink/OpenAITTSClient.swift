//
//  OpenAITTSClient.swift
//  Blink
//
//  Simple HTTP TTS via OpenAI's /v1/audio/speech endpoint. Posts JSON,
//  gets mp3 bytes back, plays via AVAudioPlayer. No WebSocket, no
//  streaming complexity — way more reliable than the Realtime path.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAITTSClient: NSObject, BlinkTTSClient {
    private(set) var voiceID: String
    private var apiKey: String?
    private var model: String = "tts-1"
    private let session: URLSession
    private var currentPlayer: AVAudioPlayer?
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/speech")!
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private let playerDelegateBridge = OpenAITTSPlayerDelegate()

    /// One of OpenAI's stock TTS voices. Defaults to "nova" (clear, warm).
    /// User can override via the existing voiceID field in Settings.
    nonisolated static let defaultVoiceID = "nova"

    var isPlaying: Bool {
        currentPlayer?.isPlaying ?? false
    }

    init(apiKey: String?, voiceID: String = OpenAITTSClient.defaultVoiceID) {
        self.apiKey = apiKey
        self.voiceID = voiceID.isEmpty ? OpenAITTSClient.defaultVoiceID : voiceID
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
        super.init()
        playerDelegateBridge.client = self
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        self.apiKey = apiKey
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = trimmed.isEmpty ? Self.defaultVoiceID : trimmed
    }

    func warmUpConnection() {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    func speakText(
        _ text: String,
        waitUntilFinished: Bool,
        onPlaybackStarted: (() -> Void)?
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onPlaybackStarted?()
            return
        }
        guard let apiKey, !apiKey.isEmpty else {
            print("OpenAITTSClient: no API key configured")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "input": trimmed,
            "voice": voiceID,
            "response_format": "mp3"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<binary>"
            print("OpenAITTSClient HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(bodyText)")
            return
        }

        let player = try AVAudioPlayer(data: data)
        player.delegate = playerDelegateBridge
        player.prepareToPlay()
        currentPlayer = player

        onPlaybackStarted?()
        player.play()

        if waitUntilFinished {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let token = UUID()
                continuations[token] = continuation
                playerDelegateBridge.enqueueToken(token)
            }
        }
    }

    func beginStreamingResponse(
        onPlaybackStarted: @escaping @MainActor () -> Void
    ) -> StreamingTTSSession {
        // For HTTP TTS we buffer per sentence and POST each one. The
        // session.appendText -> flushCompleteSentences calls fetchSamples
        // which calls our speakText. Returns empty PCM since playback is
        // owned by AVAudioPlayer, not the session's player node.
        onPlaybackStarted()
        return StreamingTTSSession.makeSystemVoiceSession { [weak self] sentence in
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    try? await self?.speakText(trimmed, waitUntilFinished: true, onPlaybackStarted: nil)
                }
            }
        }
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        return []
    }

    func stopPlayback() {
        currentPlayer?.stop()
        currentPlayer = nil
        playerDelegateBridge.flushTokens()
    }

    fileprivate func playerDidFinish() {
        if let token = playerDelegateBridge.popToken(),
           let continuation = continuations.removeValue(forKey: token) {
            continuation.resume()
        }
    }
}

private final class OpenAITTSPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    weak var client: OpenAITTSClient?
    private let lock = NSLock()
    private var tokens: [UUID] = []

    func enqueueToken(_ token: UUID) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func popToken() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return tokens.isEmpty ? nil : tokens.removeFirst()
    }

    func flushTokens() {
        lock.lock()
        tokens.removeAll()
        lock.unlock()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            self.client?.playerDidFinish()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.client?.playerDidFinish()
        }
    }
}
