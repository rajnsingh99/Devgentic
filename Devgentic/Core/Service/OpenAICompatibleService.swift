// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenAICompatibleService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "OpenAICompatibleService")

/// Model listing for a user-supplied OpenAI-compatible endpoint (LM Studio, vLLM, llama.cpp, Groq,
/// DeepSeek, Together). The base URL comes from the profile, the API key is optional, and no model-name
/// filter is applied.
struct OpenAICompatibleService {

    private struct ModelsResponse: Codable {
        let data: [ModelData]
    }

    private struct ModelData: Codable {
        let id: String
    }

    /// Fetches `{baseURL}/models` and returns the ids, sorted; the key is sent as a Bearer header only when
    /// present. Throws on a bad URL, transport failure or non-2xx; callers fall back to manual entry.
    func fetchModels(baseURL: String, apiKey: String?) async throws -> [String] {
        guard let root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "OpenAICompatibleService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL."])
        }
        let url = root.appendingPathComponent("models")

        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "OpenAICompatibleService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(from: data, status: httpResponse.statusCode)])
        }

        let ids = try Self.parseModelIDs(data)
        logger.info("OpenAI-compatible endpoint listed \(ids.count) models at \(root.absoluteString)")
        return ids
    }

    // MARK: - Parsing (pure — unit-testable without network)

    /// Extracts `data[].id`, sorted and unfiltered: the endpoint owns its catalog.
    static func parseModelIDs(_ data: Data) throws -> [String] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        return "HTTP Error \(status)"
    }
}
