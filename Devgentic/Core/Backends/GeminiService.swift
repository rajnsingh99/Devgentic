// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "GeminiService")

class GeminiService {

    // This type is a stateless fetcher and must not persist anything; provider keys live in `ProviderKeyStore` (Keychain).

    // Codable struct for parsing the models list from the Gemini API
    private struct GoogleModelsResponse: Codable {
        struct Model: Codable {
            let name: String
            let supportedGenerationMethods: [String]
        }
        let models: [Model]
    }
    
    // Custom Error for API Key Validation
    enum ApiError: Error, LocalizedError {
        case invalidApiKey
        case networkError(String)
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .invalidApiKey:
                return "The provided Google API Key is invalid."
            case .networkError(let message):
                return message
            case .invalidResponse:
                return "The server returned an invalid response."
            }
        }
    }

    // Verify the API key and fetch models from the Gemini API
    // Why: always honour the profile's endpoint, or a gateway-scoped key is sent to the public API.
    /// - Parameter baseURL: the profile's configured API endpoint; falls back to the vendor default when nil.
    func verifyAndFetchModels(apiKey: String, baseURL: URL? = nil) async throws -> [String] {
        logger.info("Validating Google API Key and fetching models...")

        guard let components = URLComponents(url: (baseURL ?? ProviderDefaults.geminiBaseURL).appendingPathComponent("models"), resolvingAgainstBaseURL: false) else {
            throw ApiError.networkError("Invalid URL")
        }

        guard let url = components.url else {
            throw ApiError.networkError("Could not construct URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // The key goes in the `x-goog-api-key` header, never the query string, which URLSession caches on disk
        // and proxy and provider logs record by full URL.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        // Authenticated listing responses are never worth caching, and caching them is how the
        // credential reached disk in the first place.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.invalidResponse
        }
        
        if httpResponse.statusCode == 400 {
            throw ApiError.invalidApiKey
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ApiError.networkError("Failed to connect to Google. Status: \(httpResponse.statusCode)")
        }
        
        do {
            let modelsResponse = try JSONDecoder().decode(GoogleModelsResponse.self, from: data)
            // Filter for models that can generate content and return just the name
            let modelNames = modelsResponse.models
                .filter { $0.supportedGenerationMethods.contains("generateContent") }
                .map { $0.name.replacingOccurrences(of: "models/", with: "") }
            
            logger.info("Successfully fetched \(modelNames.count) models from Google.")
            return modelNames
        } catch {
            throw ApiError.invalidResponse
        }
    }
}
