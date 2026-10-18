// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "AnthropicService")

/// Service for interacting with the Anthropic API.
struct AnthropicService {
    
    private struct ModelsResponse: Codable {
        let data: [ModelData]
    }
    
    private struct ModelData: Codable {
        let id: String
    }
    
    // Why: always honour the profile's endpoint, or a gateway-scoped key is sent to the public API.
    /// Fetches the available models from the Anthropic /v1/models endpoint using the provided API key.
    /// - Parameter baseURL: the profile's configured API endpoint; falls back to the vendor default when nil.
    func verifyAndFetchModels(apiKey: String, baseURL: URL? = nil) async throws -> [String] {
        let url = (baseURL ?? ProviderDefaults.anthropicBaseURL).appendingPathComponent("models")
        
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AnthropicService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to parse Anthropic's specific error payload
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw NSError(domain: "AnthropicService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "AnthropicService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
        }
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(ModelsResponse.self, from: data)
        
        // Extract model IDs (e.g., "claude-3-5-sonnet-20241022", "claude-3-haiku-20240307")
        let modelIDs = decodedResponse.data.map { $0.id }
        
        guard !modelIDs.isEmpty else {
            throw NSError(domain: "AnthropicService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No models found for this API key."])
        }
        
        // Return alphabetically sorted for cleaner UI presentation
        return modelIDs.sorted()
    }
}
