//
//  ChromaDBClient.swift
//  Blink
//
//  Local ChromaDB HTTP client. Stores/retrieves conversation memory.
//  ChromaDB's REST API does NOT embed text server-side — it requires
//  pre-computed vectors (`embeddings` on add, `query_embeddings` on query).
//  So we embed client-side: OpenAI text-embedding-3-small when an OpenAI key
//  is configured, otherwise the HuggingFace router. The chosen model must stay
//  consistent for a collection — switching providers changes the vector
//  dimension and requires wiping ~/blink-memory.
//
//  Requires a running ChromaDB server:
//    chroma run --path ~/blink-memory --port 8001
//

import Foundation

actor ChromaDBClient {
    static let shared = ChromaDBClient()

    private let serverURL: URL
    private let tenant = "default_tenant"
    private let database = "default_database"
    private let collectionName = "blink_memory"
    private var collectionID: String?

    private var apiURL: URL { serverURL.appendingPathComponent("api/v2") }

    init(port: Int = 8001) {
        serverURL = URL(string: "http://localhost:\(port)")!
    }

    func isReachable() async -> Bool {
        let url = apiURL.appendingPathComponent("heartbeat")
        guard let (_, resp) = try? await URLSession.shared.data(from: url),
              let http = resp as? HTTPURLResponse
        else { return false }
        return http.statusCode == 200
    }

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

    // The embedding model the live collection was built with, read from its
    // metadata. Used to detect a provider switch — which changes the vector
    // dimension and silently breaks add/query until the store is reset.
    private var storedEmbeddingModel: String?

    // Max cosine distance for a memory to be deleted by a "forget X" request.
    // Stricter than recall (maxRelevantDistance) because deletion is
    // destructive: only remove clearly-matching memories.
    private static let forgetMatchDistance = 0.6

    /// Persist a conversation turn, tagged with the app that was focused when it
    /// happened. Skips storage if a semantically identical exchange already
    /// exists in the same app (cosine distance < 0.1). Fire-and-forget.
    func store(transcript: String, response: String, appBundleID: String? = nil, appName: String? = nil) async {
        print("🧠 ChromaDB: store called for: \(transcript.prefix(40))")
        do {
            // Embed the full exchange once; reuse it for the dedup check and the add.
            let document = "User: \(transcript)\nBlink: \(response)"
            let embedding = try await embed(document)

            if let nearest = try await nearestDistance(embedding: embedding, appBundleID: appBundleID),
               nearest < 0.1 {
                print("🧠 ChromaDB: skipping duplicate (distance \(String(format: "%.3f", nearest)))")
                return
            }

            var metadata: [String: String] = [
                "transcript": transcript,
                "response": response,
                "timestamp": Self.dateFormatter.string(from: Date())
            ]
            if let appBundleID, !appBundleID.isEmpty { metadata["app_bundle_id"] = appBundleID }
            if let appName, !appName.isEmpty { metadata["app_name"] = appName }

            let (data, http) = try await postToCollection(pathSuffix: "add", body: [
                "ids": [UUID().uuidString],
                "embeddings": [embedding],
                "documents": [document],
                "metadatas": [metadata]
            ])
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ChromaError.storeFailed("HTTP \(http.statusCode): \(body.prefix(200))")
            }
            await pruneIfNeeded()
        } catch {
            print("⚠️ ChromaDB store error: \(error)")
        }
    }

    /// Persist a deliberately-remembered fact ("remember my key is in ~/.config").
    /// Stored with pinned=true so recall ranks it above incidental exchanges and
    /// pruning never removes it. The fact lives in `transcript`; `response` is
    /// empty so callers render it as a standalone fact.
    func storePinned(fact: String, appBundleID: String? = nil, appName: String? = nil) async {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        print("🧠 ChromaDB: storePinned: \(trimmed.prefix(40))")
        do {
            let embedding = try await embed(trimmed)
            var metadata: [String: String] = [
                "transcript": trimmed,
                "response": "",
                "pinned": "true",
                "timestamp": Self.dateFormatter.string(from: Date())
            ]
            if let appBundleID, !appBundleID.isEmpty { metadata["app_bundle_id"] = appBundleID }
            if let appName, !appName.isEmpty { metadata["app_name"] = appName }

            let (data, http) = try await postToCollection(pathSuffix: "add", body: [
                "ids": [UUID().uuidString],
                "embeddings": [embedding],
                "documents": [trimmed],
                "metadatas": [metadata]
            ])
            if !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ChromaError.storeFailed("HTTP \(http.statusCode): \(body.prefix(200))")
            }
        } catch {
            print("⚠️ ChromaDB storePinned error: \(error)")
        }
    }

    /// Semantic search for past exchanges relevant to the current transcript.
    /// When `appBundleID` is supplied, memories recorded in that same app are
    /// promoted in the ranking. Returns empty if ChromaDB is unreachable or has
    /// no stored data yet.
    func queryRelevant(
        for transcript: String,
        appBundleID: String? = nil,
        maxResults: Int = 3
    ) async -> [(transcript: String, response: String)] {
        do {
            // With an app in focus, pull a wider candidate set so same-app
            // memories can be promoted without dropping strong cross-app matches.
            let candidateCount = appBundleID == nil ? maxResults : maxResults + 3
            let queryEmbedding = try await embed(transcript)
            let (data, http) = try await postToCollection(pathSuffix: "query", body: [
                "query_embeddings": [queryEmbedding],
                "n_results": candidateCount,
                "include": ["metadatas", "distances"]
            ])
            guard (200...299).contains(http.statusCode) else { return [] }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let metaOuter = json["metadatas"] as? [[[String: Any]]],
                  let metaGroup = metaOuter.first
            else { return [] }
            let distGroup = (json["distances"] as? [[Double]])?.first ?? []

            // Lower score = more relevant. Same-app memories get a distance bonus.
            var scored: [(transcript: String, response: String, score: Double)] = []
            for (idx, meta) in metaGroup.enumerated() {
                guard let t = meta["transcript"] as? String,
                      let r = meta["response"] as? String
                else { continue }
                let isPinned = (meta["pinned"] as? String) == "true"
                let distance: Double? = idx < distGroup.count ? distGroup[idx] : nil
                // Drop clearly-irrelevant matches so unrelated queries inject
                // nothing. Pinned facts get extra slack and a stronger boost.
                let threshold = isPinned ? Self.maxRelevantDistance + Self.pinnedDistanceSlack : Self.maxRelevantDistance
                if let distance, distance > threshold { continue }
                var score = distance ?? Double(idx)
                if isPinned {
                    score -= Self.pinnedBoost
                } else if let appBundleID, meta["app_bundle_id"] as? String == appBundleID {
                    score -= Self.sameAppBoost
                }
                scored.append((transcript: t, response: r, score: score))
            }
            return scored
                .sorted { $0.score < $1.score }
                .prefix(maxResults)
                .map { (transcript: $0.transcript, response: $0.response) }
        } catch {
            print("⚠️ ChromaDB query error: \(error)")
            return []
        }
    }

    // MARK: - Management

    /// Snapshot for the Settings memory panel: server reachability, stored
    /// count, the model new embeddings would use, and the model the collection
    /// was actually built with (so the UI can warn on a provider switch).
    func status() async -> ChromaMemoryStatus {
        let current = currentEmbeddingModel()
        guard await isReachable() else {
            return ChromaMemoryStatus(reachable: false, count: 0, currentModel: current, storedModel: nil)
        }
        let count = (try? await collectionCount()) ?? 0
        return ChromaMemoryStatus(reachable: true, count: count, currentModel: current, storedModel: storedEmbeddingModel)
    }

    /// Every stored exchange, newest first, for the memory inspector.
    func allMemories(limit: Int = 500) async -> [ChromaMemoryRecord] {
        do {
            let (data, http) = try await postToCollection(pathSuffix: "get", body: [
                "include": ["metadatas"],
                "limit": limit
            ])
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = json["ids"] as? [String]
            else { return [] }
            let metas = (json["metadatas"] as? [[String: Any]]) ?? []
            let records = ids.enumerated().map { (idx, id) -> ChromaMemoryRecord in
                let meta = idx < metas.count ? metas[idx] : [:]
                return ChromaMemoryRecord(
                    id: id,
                    transcript: meta["transcript"] as? String ?? "",
                    response: meta["response"] as? String ?? "",
                    appName: meta["app_name"] as? String,
                    timestamp: meta["timestamp"] as? String
                )
            }
            return records.sorted { ($0.timestamp ?? "") > ($1.timestamp ?? "") }
        } catch {
            print("⚠️ ChromaDB allMemories error: \(error)")
            return []
        }
    }

    /// Delete a single stored exchange by id.
    func deleteMemory(id: String) async {
        _ = try? await postToCollection(pathSuffix: "delete", body: ["ids": [id]])
    }

    /// Drop the whole collection. Used by "Forget all" and by the provider-
    /// switch reset (deleting the collection also clears the old vector
    /// dimension). It is recreated lazily — with the current model's tag — on
    /// the next store or query.
    func clearAllMemories() async {
        let url = apiURL.appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(collectionName)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
        collectionID = nil
        storedEmbeddingModel = nil
    }

    /// Semantic "forget": delete stored exchanges that clearly match a topic.
    /// Returns the number removed. Conservative threshold so an off-target
    /// phrase doesn't wipe unrelated memories.
    func forget(matching query: String, maxCandidates: Int = 10) async -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        do {
            let queryEmbedding = try await embed(trimmed)
            let (data, http) = try await postToCollection(pathSuffix: "query", body: [
                "query_embeddings": [queryEmbedding],
                "n_results": maxCandidates,
                "include": ["distances"]
            ])
            guard (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ids = (json["ids"] as? [[String]])?.first
            else { return 0 }
            let distances = (json["distances"] as? [[Double]])?.first ?? []
            var toDelete: [String] = []
            for (idx, id) in ids.enumerated() {
                let distance = idx < distances.count ? distances[idx] : Double.greatestFiniteMagnitude
                if distance <= Self.forgetMatchDistance { toDelete.append(id) }
            }
            guard !toDelete.isEmpty else { return 0 }
            _ = try await postToCollection(pathSuffix: "delete", body: ["ids": toDelete])
            return toDelete.count
        } catch {
            print("⚠️ ChromaDB forget error: \(error)")
            return 0
        }
    }

    // MARK: - Private

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

    // Stored-document count. The /count endpoint returns a bare integer.
    private func collectionCount() async throws -> Int {
        let colID = try await ensureCollection()
        let url = apiURL.appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/count")
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return 0 }
        if let n = try? JSONSerialization.jsonObject(with: data) as? Int { return n }
        if let s = String(data: data, encoding: .utf8),
           let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return n }
        return 0
    }

    // Trims the store back to maxStoredMemories by deleting the oldest
    // exchanges. Throttled so it isn't a full scan on every write.
    private func pruneIfNeeded() async {
        storeCountSinceLaunch += 1
        guard storeCountSinceLaunch % Self.pruneCheckInterval == 1 else { return }
        guard let count = try? await collectionCount(), count > Self.maxStoredMemories else { return }
        guard let (data, http) = try? await postToCollection(pathSuffix: "get", body: ["include": ["metadatas"]]),
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = json["ids"] as? [String]
        else { return }
        let metas = (json["metadatas"] as? [[String: Any]]) ?? []
        // Never prune pinned facts — they're deliberately remembered.
        let prunable = ids.enumerated().compactMap { (idx, id) -> (id: String, timestamp: String)? in
            let meta = idx < metas.count ? metas[idx] : [:]
            if (meta["pinned"] as? String) == "true" { return nil }
            return (id: id, timestamp: meta["timestamp"] as? String ?? "")
        }
        let overflow = count - Self.maxStoredMemories
        let oldest = prunable.sorted { $0.timestamp < $1.timestamp }.prefix(overflow).map { $0.id }
        guard !oldest.isEmpty else { return }
        _ = try? await postToCollection(pathSuffix: "delete", body: ["ids": oldest])
    }

    // Returns the cosine distance to the closest stored document, or nil if the
    // collection is empty (in which case the caller should always store). When
    // `appBundleID` is supplied, dedup is scoped to that app so an identical
    // phrase said in a different app is still kept as its own memory.
    private func nearestDistance(embedding: [Double], appBundleID: String?) async throws -> Double? {
        var body: [String: Any] = [
            "query_embeddings": [embedding],
            "n_results": 1,
            "include": ["distances"]
        ]
        if let appBundleID, !appBundleID.isEmpty {
            body["where"] = ["app_bundle_id": appBundleID]
        }
        let (data, http) = try await postToCollection(pathSuffix: "query", body: body)
        guard (200...299).contains(http.statusCode) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outer = json["distances"] as? [[Double]],
              let first = outer.first?.first
        else { return nil }
        return first
    }

    private func ensureCollection() async throws -> String {
        if let id = collectionID { return id }

        let base = apiURL.appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections")

        // Try to fetch existing collection first.
        let getURL = base.appendingPathComponent(collectionName)
        if let (data, resp) = try? await URLSession.shared.data(from: getURL),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            storedEmbeddingModel = (json["metadata"] as? [String: Any])?["embedding_model"] as? String
            collectionID = id
            return id
        }

        // Create it. get_or_create makes this idempotent: if two calls race
        // here before collectionID is cached (e.g. a query and a store on a
        // fresh ~/blink-memory), both get the same collection back instead of
        // one winning and the other throwing on a 409 "already exists". Tag the
        // collection with the embedding model that produced its vectors so a
        // later provider switch (different dimension) can be detected.
        var createMetadata: [String: Any] = ["hnsw:space": "cosine"]
        if let model = currentEmbeddingModel() {
            createMetadata["embedding_model"] = model
        }
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": collectionName,
            "get_or_create": true,
            "metadata": createMetadata
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw ChromaError.invalidResponse }
        storedEmbeddingModel = (json["metadata"] as? [String: Any])?["embedding_model"] as? String
        collectionID = id
        return id
    }

    // POSTs to a collection sub-endpoint ("add"/"query"), resolving the
    // collection id via ensureCollection(). If the cached id is stale — the
    // collection was deleted/recreated out from under us, which ChromaDB
    // answers with 404 — the cache is cleared and the call retried once against
    // a freshly-resolved collection.
    private func postToCollection(pathSuffix: String, body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var result = try await sendToCollection(pathSuffix: pathSuffix, bodyData: bodyData)
        if result.1.statusCode == 404 {
            collectionID = nil
            result = try await sendToCollection(pathSuffix: pathSuffix, bodyData: bodyData)
        }
        return result
    }

    private func sendToCollection(pathSuffix: String, bodyData: Data) async throws -> (Data, HTTPURLResponse) {
        let colID = try await ensureCollection()
        let url = apiURL
            .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/\(pathSuffix)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw ChromaError.invalidResponse }
        return (data, http)
    }

    // MARK: - Embedding

    // Embeds a single string client-side. ChromaDB's REST API stores/queries
    // vectors only, so Blink must produce them. Prefers OpenAI (reliable, and
    // the key is already configured for the brain router); falls back to the
    // HuggingFace router when no OpenAI key is present.
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

    /// True when the collection was built with a different embedding model than
    /// the one in use now — its vectors have the wrong dimension, so add/query
    /// silently fail until the store is reset.
    var providerMismatch: Bool {
        guard let stored = storedModel, let current = currentModel else { return false }
        return stored != current
    }
}
