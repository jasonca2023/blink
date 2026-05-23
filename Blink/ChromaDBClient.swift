//
//  ChromaDBClient.swift
//  Blink
//
//  Local ChromaDB HTTP client. Stores/retrieves conversation memory.
//  ChromaDB auto-embeds documents server-side (sentence-transformers),
//  so no embedding API is needed here — just send plain text.
//
//  Requires a running ChromaDB server:
//    pip install chromadb sentence-transformers
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

    /// Persist a conversation turn. Skips storage if a semantically identical
    /// exchange already exists (cosine distance < 0.1). Fire-and-forget.
    func store(transcript: String, response: String) async {
        do {
            let colID = try await ensureCollection()

            if let nearest = try await nearestDistance(for: transcript, collectionID: colID),
               nearest < 0.1 {
                print("🧠 ChromaDB: skipping duplicate (distance \(String(format: "%.3f", nearest)))")
                return
            }

            let url = apiURL
                .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/add")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "ids": [UUID().uuidString],
                "documents": ["User: \(transcript)\nBlink: \(response)"],
                "metadatas": [[
                    "transcript": transcript,
                    "response": response,
                    "timestamp": ISO8601DateFormatter().string(from: Date())
                ]]
            ])
            _ = try await URLSession.shared.data(for: req)
        } catch {
            print("⚠️ ChromaDB store error: \(error)")
        }
    }

    /// Semantic search for past exchanges relevant to the current transcript.
    /// Returns empty if ChromaDB is unreachable or has no stored data yet.
    func queryRelevant(for transcript: String, maxResults: Int = 3) async -> [(transcript: String, response: String)] {
        do {
            let colID = try await ensureCollection()
            let url = apiURL
                .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(colID)/query")
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "query_texts": [transcript],
                "n_results": maxResults,
                "include": ["metadatas"]
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outer = json["metadatas"] as? [[[String: Any]]],
                  let group = outer.first
            else { return [] }
            return group.compactMap { meta in
                guard let t = meta["transcript"] as? String,
                      let r = meta["response"] as? String
                else { return nil }
                return (transcript: t, response: r)
            }
        } catch {
            print("⚠️ ChromaDB query error: \(error)")
            return []
        }
    }

    // MARK: - Private

    // Returns the cosine distance to the closest stored document, or nil if the
    // collection is empty (in which case the caller should always store).
    private func nearestDistance(for transcript: String, collectionID: String) async throws -> Double? {
        let url = apiURL
            .appendingPathComponent("tenants/\(tenant)/databases/\(database)/collections/\(collectionID)/query")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query_texts": [transcript],
            "n_results": 1,
            "include": ["distances"]
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
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
}

enum ChromaError: Error {
    case invalidResponse
}
