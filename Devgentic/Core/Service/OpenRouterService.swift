// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OpenRouterService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "OpenRouterService")

/// One entry from OpenRouter's catalog, reduced to the fields the app routes on.
/// `toolCapable` and `visionInput` come from OpenRouter's own metadata, so the picker can gate on capability pre-flight.
struct OpenRouterModel: Identifiable, Hashable, Sendable {
    /// Routing id sent as the request `model`, e.g. "anthropic/claude-sonnet-4.5".
    let id: String
    /// Human label, e.g. "Anthropic: Claude Sonnet 4.5".
    let name: String
    let contextLength: Int?
    /// `supported_parameters` contains "tools".
    let toolCapable: Bool
    /// `architecture.input_modalities` contains "image".
    let visionInput: Bool
}

struct OpenRouterService {

    // MARK: - Response Shapes

    private struct ModelsResponse: Codable {
        let data: [ModelData]
    }

    private struct ModelData: Codable {
        let id: String
        let name: String?
        let contextLength: Int?
        let supportedParameters: [String]?
        let architecture: Architecture?

        enum CodingKeys: String, CodingKey {
            case id, name, architecture
            case contextLength = "context_length"
            case supportedParameters = "supported_parameters"
        }
    }

    private struct Architecture: Codable {
        let inputModalities: [String]?

        enum CodingKeys: String, CodingKey {
            case inputModalities = "input_modalities"
        }
    }

    // MARK: - Fetch

    // Why: always honour the profile's endpoint, or a gateway-scoped key is sent to the public API.
    /// Verifies the API key against GET /key, then fetches the public model catalog, sorted alphabetically by id.
    /// - Parameter baseURL: the profile's configured API endpoint; falls back to the vendor default when nil.
    func verifyAndFetchModels(apiKey: String, baseURL: URL? = nil) async throws -> [OpenRouterModel] {
        try await verifyKey(apiKey: apiKey, baseURL: baseURL)

        let url = (baseURL ?? ProviderDefaults.openRouterBaseURL).appendingPathComponent("models")
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "OpenRouterService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(from: data, status: httpResponse.statusCode)])
        }

        let models = try Self.parseModels(data)
        logger.info("OpenRouter catalog fetched: \(models.count) models (\(models.filter(\.toolCapable).count) tool-capable)")
        return models
    }

    /// GET /key — the cheapest authenticated OpenRouter endpoint. A 401 here means
    /// a bad key; anything 2xx means the key exists (credit state surfaces later
    /// as 402 at request time, classified by ProviderErrorClassifier).
    private func verifyKey(apiKey: String, baseURL: URL? = nil) async throws {
        // The key check must hit the SAME host as the catalog fetch — otherwise a gateway-routed
        // profile validates against the public API and lists from the gateway, or vice versa.
        let url = (baseURL ?? ProviderDefaults.openRouterBaseURL).appendingPathComponent("key")
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "OpenRouterService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: Self.errorMessage(from: data, status: httpResponse.statusCode)])
        }
    }

    // MARK: - Parsing (pure — unit-testable without network)

    static func parseModels(_ data: Data) throws -> [OpenRouterModel] {
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data
            .map { model in
                OpenRouterModel(
                    id: model.id,
                    name: model.name ?? model.id,
                    contextLength: model.contextLength,
                    toolCapable: model.supportedParameters?.contains("tools") ?? false,
                    visionInput: model.architecture?.inputModalities?.contains("image") ?? false
                )
            }
            .sorted { $0.id < $1.id }
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
