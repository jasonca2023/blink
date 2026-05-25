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

    private static let openAIEmbeddingModel = "text-embedding-3-small"
    private static let hfEmbeddingModel = "sentence-transformers/all-MiniLM-L6-v2"

    /// Persist a conversation turn, tagged with the app that was focused when it
    /// happened. Skips storage if a semantically identical exchange already
    /// exists in the same app (cosine distance < 0.1). Fire-and-forget.
    func store(transcript: String, response: String, appBundleID: String? = nil, appName: String? = nil) async {
        print("🧠 ChromaDB: store called for: \(transcript.prefix(40))")
        do {
            let colID = try await ensureCollection()

            // Embed the full exchange once; reuse it for the dedup check and the add.
            let document = "User: \(transcript)\nBlink: \(response)"
            let embedding = try await embed(document)

            if let nearest = try await nearestDistance(embedding: embedding, collectionID: colID, appBundleID: appBundleID),
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

            let url = apiURL
                .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/add")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "ids": [UUID().uuidString],
                "embeddings": [embedding],
                "documents": [document],
                "metadatas": [metadata]
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw ChromaError.storeFailed("HTTP \(http.statusCode): \(body.prefix(200))")
            }
        } catch {
            print("⚠️ ChromaDB store error: \(error)")
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
            let colID = try await ensureCollection()
            let url = apiURL
                .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/query")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // With an app in focus, pull a wider candidate set so same-app
            // memories can be promoted without dropping strong cross-app matches.
            let candidateCount = appBundleID == nil ? maxResults : maxResults + 3
            let queryEmbedding = try await embed(transcript)
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "query_embeddings": [queryEmbedding],
                "n_results": candidateCount,
                "include": ["metadatas", "distances"]
            ])
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
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
                var score = idx < distGroup.count ? distGroup[idx] : Double(idx)
                if let appBundleID, meta["app_bundle_id"] as? String == appBundleID {
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

    // MARK: - Private

    // Returns the cosine distance to the closest stored document, or nil if the
    // collection is empty (in which case the caller should always store). When
    // `appBundleID` is supplied, dedup is scoped to that app so an identical
    // phrase said in a different app is still kept as its own memory.
    private func nearestDistance(embedding: [Double], collectionID: String, appBundleID: String?) async throws -> Double? {
        let url = apiURL
            .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(collectionID)/query")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "query_embeddings": [embedding],
            "n_results": 1,
            "include": ["distances"]
        ]
        if let appBundleID, !appBundleID.isEmpty {
            body["where"] = ["app_bundle_id": appBundleID]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }
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
            collectionID = id
            return id
        }

        // Create it.
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": collectionName,
            "metadata": ["hnsw:space": "cosine"]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String
        else { throw ChromaError.invalidResponse }
        collectionID = id
        return id
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
