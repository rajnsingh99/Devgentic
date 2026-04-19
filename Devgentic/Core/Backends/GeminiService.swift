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
    
    private let userDefaults = UserDefaults.standard
    private let apiKeykey = "gemini_api_key"
    
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
    func verifyAndFetchModels(apiKey: String) async throws -> [String] {
        logger.info("Validating Google API Key and fetching models...")
        
        guard var components = URLComponents(url: ProviderDefaults.geminiBaseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false) else {
            throw ApiError.networkError("Invalid URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        
        guard let url = components.url else {
            throw ApiError.networkError("Could not construct URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
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
            self.saveApiKey(apiKey: apiKey) // Persist the key on success
            return modelNames
        } catch {
            throw ApiError.invalidResponse
        }
    }
    
    // Save the API key to UserDefaults
    func saveApiKey(apiKey: String) {
        userDefaults.set(apiKey, forKey: apiKeykey)
    }
    
    // Retrieve the API key from UserDefaults
    func getApiKey() -> String? {
        return userDefaults.string(forKey: apiKeykey)
    }
    
    // Clear the API key from UserDefaults
    func clearApiKey() {
        userDefaults.removeObject(forKey: apiKeykey)
    }
}
