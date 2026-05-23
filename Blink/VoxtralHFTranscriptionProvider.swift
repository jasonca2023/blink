//
//  VoxtralHFTranscriptionProvider.swift
//  Blink
//
//  Transcription provider backed by mistralai/Voxtral-Small-24B-2507 via the
//  HuggingFace router's OpenAI-compatible /v1/audio/transcriptions endpoint.
//  Authenticates with the user's HF token (same key the agent backend uses).
//

import AVFoundation
import Foundation

struct VoxtralHFTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class VoxtralHFTranscriptionProvider: BuddyTranscriptionProvider {
    private let apiKey = AppBundleConfiguration.huggingFaceAPIKey()
    private let modelName: String

    let displayName = "Voxtral"
    let requiresSpeechRecognitionPermission = false

    init() {
        self.modelName = ProcessInfo.processInfo.environment["BLINK_VOXTRAL_MODEL"]
            ?? AppBundleConfiguration.stringValue(forKey: "VoxtralTranscriptionModel")
            ?? "mistralai/Voxtral-Small-24B-2507"
    }

    var isConfigured: Bool {
        guard let apiKey else { return false }
        return !apiKey.isEmpty
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "Voxtral transcription is not configured. Add a HuggingFace token under API Keys."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let apiKey, !apiKey.isEmpty else {
            throw VoxtralHFTranscriptionProviderError(
                message: unavailableExplanation ?? "Voxtral transcription is not configured."
            )
        }
        return VoxtralHFTranscriptionSession(
            apiKey: apiKey,
            modelName: modelName,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class VoxtralHFTranscriptionSession: BuddyStreamingTranscriptionSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 10.0

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private static let transcriptionURL = URL(string: "https://router.huggingface.co/v1/audio/transcriptions")!
    private static let targetSampleRate = 16_000

    private let apiKey: String
    private let modelName: String
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.blink.voxtral.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        apiKey: String,
        modelName: String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: cfg)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let pcm16 = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !pcm16.isEmpty else { return }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(pcm16)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            let buffered = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribe(buffered)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribe(_ pcm16Data: Data) async {
        guard !Task.isCancelled else { return }

        let isEmpty = stateQueue.sync { isCancelled || pcm16Data.isEmpty }
        if isEmpty {
            deliverFinalTranscript("")
            return
        }

        let wav = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: pcm16Data,
            sampleRate: Self.targetSampleRate
        )

        do {
            let text = try await upload(wav: wav)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            if !text.isEmpty {
                onTranscriptUpdate(text)
            }
            deliverFinalTranscript(text)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Voxtral] ❌ Upload failed (\(wav.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func upload(wav: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeBody(boundary: boundary, wav: wav)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoxtralHFTranscriptionProviderError(message: "Voxtral returned an invalid HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw VoxtralHFTranscriptionProviderError(
                message: "Voxtral transcription failed (\(http.statusCode)): \(body.prefix(400))"
            )
        }

        if let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) {
            return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return raw }
        throw VoxtralHFTranscriptionProviderError(message: "Voxtral returned an empty transcript.")
    }

    private func makeBody(boundary: String, wav: Data) -> Data {
        var body = Data()
        body.appendVoxtralFormField(name: "model", value: modelName, boundary: boundary)
        body.appendVoxtralFormField(name: "language", value: "en", boundary: boundary)
        body.appendVoxtralFormField(name: "response_format", value: "json", boundary: boundary)
        if let hint = promptHint() {
            body.appendVoxtralFormField(name: "prompt", value: hint, boundary: boundary)
        }
        body.appendVoxtralFileField(
            name: "file",
            filename: "voice-input.wav",
            mimeType: "audio/wav",
            fileData: wav,
            boundary: boundary
        )
        body.appendVoxtralString("--\(boundary)--\r\n")
        return body
    }

    private func promptHint() -> String? {
        let terms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return "Push-to-talk transcript for a Mac coding/productivity app. Expect terms: \(terms.joined(separator: ", "))."
    }

    private func deliverFinalTranscript(_ text: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(text)
    }

    deinit {
        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }
}

private extension Data {
    mutating func appendVoxtralString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendVoxtralFormField(name: String, value: String, boundary: String) {
        appendVoxtralString("--\(boundary)\r\n")
        appendVoxtralString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendVoxtralString("\(value)\r\n")
    }

    mutating func appendVoxtralFileField(
        name: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        boundary: String
    ) {
        appendVoxtralString("--\(boundary)\r\n")
        appendVoxtralString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendVoxtralString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendVoxtralString("\r\n")
    }
}
