// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiService.swift
//  Devgentic
//
//  Created by Raj Singh on 18/08/25.
//

import Foundation
import os

private let logger = DGLogger(category: "GeminiService")

class GeminiService {

    // ⚠️ register A53. This type used to hold `UserDefaults.standard` and a `gemini_api_key`
    // constant, and `verifyAndFetchModels` wrote the raw key there on every successful fetch.
    // Nothing ever read it back — `saveApiKey`/`getApiKey`/`clearApiKey` had zero callers
    // repo-wide — so it was a pure side effect that deposited a plaintext credential in
    // ~/Library/Preferences/, outlived the profile that owned it, and could not be cleared from
    // any UI. Provider keys live in `ProviderKeyStore` (Keychain, keyed on profile id); this type
    // is a stateless fetcher and must not persist anything.
    // Keys already written by earlier builds are removed by
    // `ProviderKeyStore.purgeLegacyPlaintextKeys()` at container configuration.

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
    /// - Parameter baseURL: the profile's configured API Endpoint. ⚠️ Defaulted, never hardcoded:
    ///   a user on a corporate or self-hosted gateway sets that endpoint and pastes a
    ///   GATEWAY-SCOPED key. This call used to ignore it and transmit that key to the vendor's
    ///   public API on every keystroke-debounced fetch — a host they had deliberately routed
    ///   around, and one their policy may forbid. Same `?? ProviderDefaults.x` shape `AgentConnect`
    ///   already uses, so listing and chat can never disagree about where a profile talks.
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
        // ⚠️ The key goes in the `x-goog-api-key` HEADER, never the query string. As a query
        // parameter it is written to URLSession's shared on-disk cache in
        // ~/Library/Caches/<bundle-id>/ keyed by the FULL URL — a second copy of the secret, in a
        // directory nothing treats as sensitive and no uninstall or reset path clears. It also
        // lands in any TLS-terminating proxy's access log and in the provider's own request logs,
        // where a header-borne credential would not. `GeminiLLMProvider.makeRequest` already does
        // this correctly; these listing calls were missed.
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
