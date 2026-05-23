//
//  SystemTTSClient.swift
//  Blink
//
//  Built-in macOS Siri / system voice via AVSpeechSynthesizer. No API
//  key, no network — works the moment the app launches. Used as the
//  default TTS provider so the user can hear responses without first
//  configuring ElevenLabs / Cartesia / Deepgram credentials.
//

import AVFoundation
import Foundation

@MainActor
final class SystemTTSClient: NSObject, BlinkTTSClient {
    private(set) var voiceID: String
    private let synthesizer = AVSpeechSynthesizer()
    private let delegateBridge = SystemTTSDelegateBridge()
    private var speakRate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// Picks the best available system voice for English at process start.
    /// Prefers a premium / Siri voice if one is installed; falls back to
    /// the compact Samantha voice that ships with every macOS install.
    nonisolated static let defaultVoiceID: String = {
        let preferredIdentifiers = [
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.voice.premium.en-US.Ava",
            "com.apple.voice.premium.en-US.Nathan",
            "com.apple.voice.premium.en-US.Evan",
            "com.apple.voice.premium.en-US.Allison",
            "com.apple.voice.enhanced.en-US.Ava",
            "com.apple.voice.enhanced.en-US.Samantha",
            "com.apple.voice.compact.en-US.Samantha",
            "com.apple.speech.synthesis.voice.Alex"
        ]
        for identifier in preferredIdentifiers {
            if AVSpeechSynthesisVoice(identifier: identifier) != nil {
                return identifier
            }
        }
        return AVSpeechSynthesisVoice(language: "en-US")?.identifier
            ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)?.identifier
            ?? ""
    }()

    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    init(voiceID: String = SystemTTSClient.defaultVoiceID) {
        self.voiceID = voiceID
        super.init()
        synthesizer.delegate = delegateBridge
    }

    func updateConfiguration(apiKey: String?, voiceID: String) {
        let trimmed = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voiceID = trimmed.isEmpty ? Self.defaultVoiceID : trimmed
    }

    func warmUpConnection() {
        // AVSpeechSynthesizer has no network handshake to warm up.
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

        let utterance = makeUtterance(for: trimmed)

        if waitUntilFinished {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                delegateBridge.register(token: UUID(), startedCallback: {
                    Task { @MainActor in onPlaybackStarted?() }
                }, finishedCallback: {
                    continuation.resume()
                })
                utterance.preUtteranceDelay = 0
                synthesizer.speak(utterance)
            }
        } else {
            delegateBridge.register(token: UUID(), startedCallback: {
                Task { @MainActor in onPlaybackStarted?() }
            }, finishedCallback: nil)
            synthesizer.speak(utterance)
        }
    }

    func beginStreamingResponse(
        onPlaybackStarted: @escaping @MainActor () -> Void
    ) -> StreamingTTSSession {
        // AVSpeechSynthesizer begins emitting audio near-instantly per
        // utterance, so we fire the playback-started callback on session
        // creation. This avoids having to track a sendable "didStart"
        // flag across the @Sendable per-sentence closure boundary.
        onPlaybackStarted()
        return StreamingTTSSession.makeSystemVoiceSession { [weak self] sentence in
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let utterance = AVSpeechUtterance(string: trimmed)
                if let voice = AVSpeechSynthesisVoice(identifier: self.voiceID) {
                    utterance.voice = voice
                } else {
                    utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
                }
                utterance.rate = self.speakRate
                utterance.volume = 1.0
                self.delegateBridge.register(
                    token: UUID(),
                    startedCallback: nil,
                    finishedCallback: nil
                )
                self.synthesizer.speak(utterance)
            }
        }
    }

    func fetchSentenceSamples(_ text: String) async throws -> [Int16] {
        // AVSpeechSynthesizer renders audio through the system output
        // directly; there's nothing to schedule on a custom AVAudioPlayerNode.
        return []
    }

    func stopPlayback() {
        synthesizer.stopSpeaking(at: .immediate)
        delegateBridge.flushPendingFinishedCallbacks()
    }

    private func makeUtterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = speakRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0
        return utterance
    }
}

/// AVSpeechSynthesizer's delegate is callback-based with no per-utterance
/// context, so we keep a parallel registry keyed on a token attached via
/// `accessibilityLabel` (the only writable identifier on AVSpeechUtterance).
/// This bridge is `nonisolated` to satisfy the delegate's threading model
/// and hops back to the main actor before invoking the registered closures.
private final class SystemTTSDelegateBridge: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct CallbackPair {
        let started: (() -> Void)?
        let finished: (() -> Void)?
    }

    private let lock = NSLock()
    private var callbacks: [UUID: CallbackPair] = [:]
    private var orderedTokens: [UUID] = []

    func register(token: UUID, startedCallback: (() -> Void)?, finishedCallback: (() -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        callbacks[token] = CallbackPair(started: startedCallback, finished: finishedCallback)
        orderedTokens.append(token)
    }

    func flushPendingFinishedCallbacks() {
        let pending: [CallbackPair]
        lock.lock()
        pending = orderedTokens.compactMap { callbacks.removeValue(forKey: $0) }
        orderedTokens.removeAll()
        lock.unlock()
        for pair in pending {
            pair.finished?()
        }
    }

    private func popNextCallbacks() -> CallbackPair? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = orderedTokens.first else { return nil }
        orderedTokens.removeFirst()
        return callbacks.removeValue(forKey: token)
    }

    private func peekNextCallbacks() -> CallbackPair? {
        lock.lock()
        defer { lock.unlock() }
        guard let token = orderedTokens.first else { return nil }
        return callbacks[token]
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        peekNextCallbacks()?.started?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        popNextCallbacks()?.finished?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        popNextCallbacks()?.finished?()
    }
}

extension SystemTTSClient: @unchecked Sendable {}
