//
//  ChromaDBClient.swift
//  Blink
//
//  On-device conversation memory. Persists past exchanges as embedding vectors
//  in a local file and recalls them by cosine similarity — entirely in-process,
//  with no server to install or run. Every Blink user gets working, persistent
//  memory once an embedding key (OpenAI or Hugging Face) is configured, and the
//  data never leaves their Mac.
//
//  ChromaDB used to back this over HTTP (localhost:8001), which required the
//  user to start a `chroma` server by hand. The public API here is unchanged so
//  callers didn't have to change; only the storage moved from that server to a
//  local file (~/Library/Application Support/Blink/conversation-memory.json).
//  Embeddings are still computed client-side: OpenAI text-embedding-3-small when
//  an OpenAI key is set, otherwise the HuggingFace router. The chosen model must
//  stay consistent for the store — switching providers changes the vector
//  dimension; mismatched vectors simply stop matching until the store is reset.
//

import Foundation

actor ChromaDBClient {
    static let shared = ChromaDBClient()

    init() {}

    private static let dateFormatter = ISO8601DateFormatter()

    // Cosine-distance bonus applied to memories recorded in the same app as the
    // current request, so they rank above equally-relevant cross-app ones.
    private static let sameAppBoost = 0.15

    // Pinned ("remember this") facts outrank incidental exchanges and tolerate a
    // looser distance, so a deliberately-saved fact still surfaces on a fuzzier
    // query than a normal exchange would.
    private static let pinnedBoost = 0.30
    private static let pinnedDistanceSlack = 0.15

    // Max cosine distance for a memory to count as relevant. Tuned for the
    // default embedding model (text-embedding-3-small): genuinely related
    // exchanges land <0.6, unrelated ones >0.85, so 0.75 drops noise without
    // dropping real matches. Without this, every query injects the top-N
    // memories even when nothing is actually relevant.
    private static let maxRelevantDistance = 0.75

    private static let openAIEmbeddingModel = "text-embedding-3-small"
    private static let hfEmbeddingModel = "sentence-transformers/all-MiniLM-L6-v2"

    // Hard cap on stored exchanges. Oldest are pruned past this so the local
    // store stays bounded. Checked periodically (every pruneCheckInterval
    // stores) rather than on every write.
    private static let maxStoredMemories = 1000
    private static let pruneCheckInterval = 20
    private var storeCountSinceLaunch = 0

    // Max cosine distance for a memory to be deleted by a "forget X" request.
    // Stricter than recall (maxRelevantDistance) because deletion is
    // destructive: only remove clearly-matching memories.
    private static let forgetMatchDistance = 0.6

    // MARK: - Local store

    /// One persisted exchange. Embeddings are stored as Float to keep the file
    /// compact; cosine math promotes back to Double.
    private struct MemoryRecord: Codable {
        let id: String
        var embedding: [Float]
        var transcript: String
        var response: String
        var appBundleID: String?
        var appName: String?
        var pinned: Bool
        var timestamp: String
    }

    private struct StoreFile: Codable {
        var embeddingModel: String?
        var records: [MemoryRecord]
    }

    private var records: [MemoryRecord] = []
    // The embedding model the stored vectors were built with. Used to detect a
    // provider switch — which changes the vector dimension so old vectors stop
    // matching — and surface the "reset memory" prompt in Settings.
    private var storedEmbeddingModel: String?
    private var loaded = false

    private var storeFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let dir = base.appendingPathComponent("Blink", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversation-memory.json", isDirectory: false)
    }

    private func loadIfNeeded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeFileURL),
              let file = try? JSONDecoder().decode(StoreFile.self, from: data)
        else { return }
        records = file.records
        storedEmbeddingModel = file.embeddingModel
    }

    private func persist() {
        let file = StoreFile(embeddingModel: storedEmbeddingModel, records: records)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: storeFileURL, options: .atomic)
    }

    /// The local store is always available — there is no server to be offline.
    /// Kept so the Settings/menu-bar reachability indicators read "on".
    func isReachable() async -> Bool { true }

    /// Persist a conversation turn, tagged with the app that was focused when it
    /// happened. Skips storage if a semantically identical exchange already
    /// exists in the same app (cosine distance < 0.1). Fire-and-forget.
    func store(transcript: String, response: String, appBundleID: String? = nil, appName: String? = nil) async {
        do {
            // Embed the full exchange once; reuse it for the dedup check and the add.
            let document = "User: \(transcript)\nBlink: \(response)"
            let embedding = try await embed(document)

            if let nearest = nearestDistance(embedding: embedding, appBundleID: appBundleID), nearest < 0.1 {
                return
            }

            appendRecord(embedding: embedding, transcript: transcript, response: response,
                         appBundleID: appBundleID, appName: appName, pinned: false)
            pruneIfNeeded()
            persist()
        } catch {
            print("memory store error: \(error)")
        }
    }

    /// Persist a deliberately-remembered fact ("remember my key is in ~/.config").
    /// Stored with pinned=true so recall ranks it above incidental exchanges and
    /// pruning never removes it. The fact lives in `transcript`; `response` is
    /// empty so callers render it as a standalone fact.
    func storePinned(fact: String, appBundleID: String? = nil, appName: String? = nil) async {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let embedding = try await embed(trimmed)
            appendRecord(embedding: embedding, transcript: trimmed, response: "",
                         appBundleID: appBundleID, appName: appName, pinned: true)
            persist()
        } catch {
            print("memory storePinned error: \(error)")
        }
    }

    /// Semantic search for past exchanges relevant to the current transcript.
    /// When `appBundleID` is supplied, memories recorded in that same app are
    /// promoted in the ranking. Returns empty if memory is empty or there's no
    /// embedding provider configured.
    func queryRelevant(
        for transcript: String,
        appBundleID: String? = nil,
        maxResults: Int = 3
    ) async -> [(transcript: String, response: String)] {
        do {
            let queryEmbedding = try await embed(transcript)
            loadIfNeeded()
            guard !records.isEmpty else { return [] }

            // Lower score = more relevant. Same-app memories get a distance bonus.
            var scored: [(transcript: String, response: String, score: Double)] = []
            for record in records {
                let distance = cosineDistance(queryEmbedding, record.embedding)
                // Drop clearly-irrelevant matches so unrelated queries inject
                // nothing. Pinned facts get extra slack and a stronger boost.
                let threshold = record.pinned ? Self.maxRelevantDistance + Self.pinnedDistanceSlack : Self.maxRelevantDistance
                if distance > threshold { continue }
                var score = distance
                if record.pinned {
                    score -= Self.pinnedBoost
                } else if let appBundleID, record.appBundleID == appBundleID {
                    score -= Self.sameAppBoost
                }
                scored.append((transcript: record.transcript, response: record.response, score: score))
            }
            return scored
                .sorted { $0.score < $1.score }
                .prefix(maxResults)
                .map { (transcript: $0.transcript, response: $0.response) }
        } catch {
            print("memory query error: \(error)")
            return []
        }
    }

    // MARK: - Management

    /// Snapshot for the Settings memory panel: stored count, the model new
    /// embeddings would use, and the model the store was actually built with (so
    /// the UI can warn on a provider switch). Always "reachable" — local.
    func status() async -> ChromaMemoryStatus {
        loadIfNeeded()
        return ChromaMemoryStatus(
            reachable: true,
            count: records.count,
            currentModel: currentEmbeddingModel(),
            storedModel: storedEmbeddingModel
        )
    }

    /// Every stored exchange, newest first, for the memory inspector.
    func allMemories(limit: Int = 500) async -> [ChromaMemoryRecord] {
        loadIfNeeded()
        return records
            .sorted { ($0.timestamp) > ($1.timestamp) }
            .prefix(limit)
            .map { record in
                ChromaMemoryRecord(
                    id: record.id,
                    transcript: record.transcript,
                    response: record.response,
                    appName: record.appName,
                    timestamp: record.timestamp
                )
            }
    }

    /// Delete a single stored exchange by id.
    func deleteMemory(id: String) async {
        loadIfNeeded()
        let before = records.count
        records.removeAll { $0.id == id }
        if records.count != before { persist() }
    }

    /// Drop the whole store. Used by "Forget all" and by the provider-switch
    /// reset (which also clears the old vector dimension). The model tag is
    /// cleared too, so the next store re-tags it with the current model.
    func clearAllMemories() async {
        loadIfNeeded()
        records.removeAll()
        storedEmbeddingModel = nil
        persist()
    }

    /// Semantic "forget": delete stored exchanges that clearly match a topic.
    /// Returns the number removed. Conservative threshold so an off-target
    /// phrase doesn't wipe unrelated memories.
    func forget(matching query: String, maxCandidates: Int = 10) async -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        do {
            let queryEmbedding = try await embed(trimmed)
            loadIfNeeded()
            guard !records.isEmpty else { return 0 }
            let matchingIDs = Set(
                records
                    .map { (id: $0.id, distance: cosineDistance(queryEmbedding, $0.embedding)) }
                    .filter { $0.distance <= Self.forgetMatchDistance }
                    .sorted { $0.distance < $1.distance }
                    .prefix(maxCandidates)
                    .map { $0.id }
            )
            guard !matchingIDs.isEmpty else { return 0 }
            records.removeAll { matchingIDs.contains($0.id) }
            persist()
            return matchingIDs.count
        } catch {
            print("memory forget error: \(error)")
            return 0
        }
    }

    // MARK: - Private

    private func appendRecord(
        embedding: [Double],
        transcript: String,
        response: String,
        appBundleID: String?,
        appName: String?,
        pinned: Bool
    ) {
        loadIfNeeded()
        if storedEmbeddingModel == nil { storedEmbeddingModel = currentEmbeddingModel() }
        let record = MemoryRecord(
            id: UUID().uuidString,
            embedding: embedding.map { Float($0) },
            transcript: transcript,
            response: response,
            appBundleID: (appBundleID?.isEmpty == false) ? appBundleID : nil,
            appName: (appName?.isEmpty == false) ? appName : nil,
            pinned: pinned,
            timestamp: Self.dateFormatter.string(from: Date())
        )
        records.append(record)
    }

    // Returns the cosine distance to the closest stored document, or nil if
    // there's nothing to compare against (in which case the caller should always
    // store). When `appBundleID` is supplied, dedup is scoped to that app so an
    // identical phrase said in a different app is still kept as its own memory.
    private func nearestDistance(embedding: [Double], appBundleID: String?) -> Double? {
        loadIfNeeded()
        let pool: [MemoryRecord]
        if let appBundleID, !appBundleID.isEmpty {
            pool = records.filter { $0.appBundleID == appBundleID }
        } else {
            pool = records
        }
        guard !pool.isEmpty else { return nil }
        var best = Double.greatestFiniteMagnitude
        for record in pool {
            let distance = cosineDistance(embedding, record.embedding)
            if distance < best { best = distance }
        }
        return best == Double.greatestFiniteMagnitude ? nil : best
    }

    // Trims the store back to maxStoredMemories by deleting the oldest
    // exchanges. Throttled so it isn't a full scan on every write. Pinned facts
    // are never pruned — they're deliberately remembered.
    private func pruneIfNeeded() {
        storeCountSinceLaunch += 1
        guard storeCountSinceLaunch % Self.pruneCheckInterval == 1 else { return }
        guard records.count > Self.maxStoredMemories else { return }
        let overflow = records.count - Self.maxStoredMemories
        let oldest = Set(
            records
                .filter { !$0.pinned }
                .sorted { $0.timestamp < $1.timestamp }
                .prefix(overflow)
                .map { $0.id }
        )
        guard !oldest.isEmpty else { return }
        records.removeAll { oldest.contains($0.id) }
    }

    // ChromaDB's "cosine" space returns distance = 1 - cosine_similarity, in
    // [0, 2]. We compute the same so the tuned thresholds above carry over
    // unchanged. Vectors of differing dimension (a provider switch left old
    // ones behind) are treated as infinitely far so they simply never match.
    private func cosineDistance(_ a: [Double], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .greatestFiniteMagnitude }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            let x = a[i]
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return .greatestFiniteMagnitude }
        return 1.0 - dot / (normA.squareRoot() * normB.squareRoot())
    }

    // MARK: - Embedding

    // The model embed() would use right now, mirroring its provider preference
    // (OpenAI when keyed, else HuggingFace). nil when neither key is present.
    private func currentEmbeddingModel() -> String? {
        if let key = AppBundleConfiguration.openAIAPIKey(), !key.isEmpty {
            return Self.openAIEmbeddingModel
        }
        if let key = AppBundleConfiguration.huggingFaceAPIKey(), !key.isEmpty {
            return Self.hfEmbeddingModel
        }
        return nil
    }

    // Embeds a single string client-side. Prefers OpenAI (reliable, and the key
    // is already configured for the brain router); falls back to the HuggingFace
    // router when no OpenAI key is present.
    private func embed(_ text: String) async throws -> [Double] {
        if let openAIKey = AppBundleConfiguration.openAIAPIKey(), !openAIKey.isEmpty {
            return try await embedViaOpenAI(text, apiKey: openAIKey)
        }
        if let hfKey = AppBundleConfiguration.huggingFaceAPIKey(), !hfKey.isEmpty {
            return try await embedViaHuggingFace(text, apiKey: hfKey)
        }
        throw ChromaError.noEmbeddingProvider
    }

    private func embedViaOpenAI(_ text: String, apiKey: String) async throws -> [Double] {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.openAIEmbeddingModel,
            "input": text
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChromaError.embeddingFailed("OpenAI HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArr = json["data"] as? [[String: Any]],
              let vec = dataArr.first?["embedding"] as? [Double], !vec.isEmpty
        else { throw ChromaError.embeddingFailed("OpenAI: unexpected response shape") }
        return vec
    }

    private func embedViaHuggingFace(_ text: String, apiKey: String) async throws -> [Double] {
        let url = URL(string: "https://router.huggingface.co/hf-inference/models/\(Self.hfEmbeddingModel)/pipeline/feature-extraction")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["inputs": text])
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChromaError.embeddingFailed("HF HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(body.prefix(200))")
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        // sentence-transformers feature-extraction returns a pooled [Double] for
        // a single input; some models return token-level [[Double]] to mean-pool.
        if let vec = parsed as? [Double], !vec.isEmpty {
            return vec
        }
        if let matrix = parsed as? [[Double]], !matrix.isEmpty {
            let dim = matrix[0].count
            var sum = [Double](repeating: 0, count: dim)
            for row in matrix where row.count == dim {
                for i in 0..<dim { sum[i] += row[i] }
            }
            return sum.map { $0 / Double(matrix.count) }
        }
        throw ChromaError.embeddingFailed("HF: unexpected response shape")
    }
}

enum ChromaError: Error {
    case invalidResponse
    case storeFailed(String)
    case embeddingFailed(String)
    case noEmbeddingProvider
}

/// One stored conversation exchange, surfaced to the Settings memory inspector.
struct ChromaMemoryRecord: Identifiable, Sendable {
    let id: String
    let transcript: String
    let response: String
    let appName: String?
    let timestamp: String?
}

/// Conversation-memory health for the Settings panel.
struct ChromaMemoryStatus: Sendable {
    let reachable: Bool
    let count: Int
    let currentModel: String?
    let storedModel: String?

    /// True when the store was built with a different embedding model than the
    /// one in use now — its vectors have the wrong dimension, so they stop
    /// matching until the store is reset.
    var providerMismatch: Bool {
        guard let stored = storedModel, let current = currentModel else { return false }
        return stored != current
    }
}
