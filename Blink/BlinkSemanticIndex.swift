//
//  BlinkSemanticIndex.swift
//  Blink
//
//  Semantic retrieval over BlinkAppKnowledgeStore entries using
//  HuggingFace-hosted sentence embeddings (all-MiniLM-L6-v2). Falls
//  back silently when the HF key is missing or the call fails — the
//  caller is expected to use lexical retrieval in that case.
//

import Foundation
import CryptoKit

/// Same shape as the lexical retrieval result so call sites can mix the
/// two without converting.
typealias BlinkSemanticRetrieval = BlinkAppKnowledgeRetrieval

actor BlinkSemanticIndex {
    static let shared = BlinkSemanticIndex()

    private struct CacheFile: Codable {
        let corpusFingerprint: String
        let model: String
        let vectors: [String: [Float]]
    }

    private let model = "sentence-transformers/all-MiniLM-L6-v2"
    private let baseURL = URL(string: "https://api-inference.huggingface.co/pipeline/feature-extraction/")!

    private var vectors: [String: [Float]] = [:]
    private var ready = false
    private var prepareTask: Task<Void, Never>?

    var isReady: Bool { ready }

    private var corpusFingerprint: String {
        var hasher = SHA256()
        for entry in BlinkAppKnowledgeStore.entries.sorted(by: { $0.id < $1.id }) {
            let line = "\(entry.id)\u{1F}\(entry.title)\u{1F}\(entry.body)\u{1F}\(entry.tags.joined(separator: ","))\u{1E}"
            if let data = line.data(using: .utf8) {
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Blink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("semantic-index.json", isDirectory: false)
    }

    func prepareIfNeeded() async {
        if ready { return }
        if let task = prepareTask {
            await task.value
            return
        }
        let task = Task { await self.prepare() }
        prepareTask = task
        await task.value
    }

    /// Force a rebuild — drops the disk cache and re-embeds everything.
    /// Use after the user enters a new HF key or after the knowledge
    /// corpus changes.
    func rebuild() async {
        ready = false
        vectors = [:]
        try? FileManager.default.removeItem(at: cacheFileURL)
        if let task = prepareTask {
            await task.value
            return
        }
        let task = Task { await self.prepare() }
        prepareTask = task
        await task.value
    }

    /// Quick read for settings UI. Tuple of (ready, entryCount, modelName).
    func status() -> (ready: Bool, count: Int, model: String) {
        (ready, vectors.count, model)
    }

    private func prepare() async {
        defer { prepareTask = nil }

        if let cache = loadCache(),
           cache.model == model,
           cache.corpusFingerprint == corpusFingerprint {
            vectors = cache.vectors
            ready = true
            return
        }

        guard AppBundleConfiguration.huggingFaceAPIKey() != nil else { return }

        let entries = BlinkAppKnowledgeStore.entries
        let texts = entries.map { "\($0.app)\n\($0.title)\n\($0.body)\n\($0.tags.joined(separator: " "))" }

        do {
            let embeddings = try await embed(texts: texts)
            guard embeddings.count == entries.count else { return }
            var fresh: [String: [Float]] = [:]
            for (i, entry) in entries.enumerated() {
                fresh[entry.id] = embeddings[i]
            }
            vectors = fresh
            saveCache(CacheFile(corpusFingerprint: corpusFingerprint, model: model, vectors: fresh))
            ready = true
        } catch {
            // Silent — caller falls back to lexical.
        }
    }

    /// Returns top-K semantic matches. Empty when the index isn't ready
    /// or the query embedding fails.
    func retrieve(
        query: String,
        focusedAppBundleID: String?,
        focusedAppName: String?,
        limit: Int
    ) async -> [BlinkSemanticRetrieval] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !trimmed.isEmpty else { return [] }

        let queryVec: [Float]
        do {
            guard let v = try await embed(texts: [trimmed]).first else { return [] }
            queryVec = v
        } catch {
            return []
        }

        let focusedBundleLower = focusedAppBundleID?.lowercased()
        let focusedNameLower = focusedAppName?.lowercased()

        let scored: [BlinkSemanticRetrieval] = BlinkAppKnowledgeStore.entries.compactMap { entry in
            guard let entryVec = vectors[entry.id] else { return nil }
            var score = Double(cosine(queryVec, entryVec))

            if let f = focusedBundleLower,
               entry.bundleIdHints.map({ $0.lowercased() }).contains(f) {
                score += 0.25
            }
            if let f = focusedNameLower,
               entry.appAliases.map({ $0.lowercased() }).contains(f) {
                score += 0.15
            }
            return BlinkSemanticRetrieval(entry: entry, score: score)
        }

        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - HTTP

    private func embed(texts: [String]) async throws -> [[Float]] {
        guard let token = AppBundleConfiguration.huggingFaceAPIKey() else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent(model, isDirectory: false))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let payload: [String: Any] = [
            "inputs": texts,
            "options": ["wait_for_model": true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let json = try JSONSerialization.jsonObject(with: data)

        // Sentence-transformers via the feature-extraction pipeline returns
        // mean-pooled sentence vectors as `[[Float]]` (one per input).
        if let sentenceVectors = json as? [[Double]] {
            return sentenceVectors.map { $0.map(Float.init) }
        }

        // Some HF backends return token-level vectors: `[[[Float]]]`. Mean
        // pool ourselves so the rest of the pipeline doesn't care.
        if let tokenVectors = json as? [[[Double]]] {
            return tokenVectors.map(Self.meanPool)
        }

        // Single-input convenience shape: `[Float]`.
        if let singleVector = json as? [Double] {
            return [singleVector.map(Float.init)]
        }

        throw URLError(.cannotParseResponse)
    }

    private static func meanPool(_ tokens: [[Double]]) -> [Float] {
        guard let first = tokens.first, !first.isEmpty else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for token in tokens {
            for i in 0..<min(dim, token.count) {
                sum[i] += Float(token[i])
            }
        }
        let count = Float(tokens.count)
        return count == 0 ? sum : sum.map { $0 / count }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0
        var na: Float = 0
        var nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - Cache

    private func loadCache() -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private func saveCache(_ cache: CacheFile) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheFileURL, options: [.atomic])
    }
}
