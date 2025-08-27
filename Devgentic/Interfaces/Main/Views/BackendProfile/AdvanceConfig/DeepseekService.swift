//
//  DeepseekService.swift
//  Devgentic
//
//  Created by Raj Singh on 25/08/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "DeepseekService")

class DeepseekService {
    
    private let userDefaults = UserDefaults.standard
    private let apiKeykey = "deepseek_api_key"
    
    // MARK: - Codable Structs for API Response
    
    private struct DeepseekModelsResponse: Codable {
        let data: [Model]
        
        struct Model: Codable {
            let id: String
        }
    }
    
    // MARK: - Custom Error Types
    
    enum ApiError: Error, LocalizedError {
        case invalidApiKey
        case networkError(String)
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .invalidApiKey:
                return "The provided Deepseek API Key is invalid or lacks permissions."
            case .networkError(let message):
                return message
            case .invalidResponse:
                return "The server returned an invalid or unexpected response."
            }
        }
    }

    // MARK: - Public API Methods
    
    /// Verifies the API key by fetching the list of available models from the Deepseek API.
    func verifyAndFetchModels(apiKey: String) async throws -> [String] {
        logger.info("Validating Deepseek API Key and fetching models...")
        
        guard let url = URL(string: "https://api.deepseek.com/v1/models") else {
            throw ApiError.networkError("Invalid URL for Deepseek models endpoint.")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApiError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw ApiError.invalidApiKey
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ApiError.networkError("Failed to connect to Deepseek. Status: \(httpResponse.statusCode)")
        }
        
        do {
            let modelsResponse = try JSONDecoder().decode(DeepseekModelsResponse.self, from: data)
            let modelNames = modelsResponse.data.map { $0.id }
            
            logger.info("Successfully fetched \(modelNames.count) models from Deepseek.")
            self.saveApiKey(apiKey: apiKey) // Persist the key only on success
            return modelNames
        } catch {
            logger.error("Failed to decode Deepseek models response: \(error.localizedDescription)")
            throw ApiError.invalidResponse
        }
    }
    
    // MARK: - UserDefaults Management
    
    func saveApiKey(apiKey: String) {
        userDefaults.set(apiKey, forKey: apiKeykey)
    }
    
    func getApiKey() -> String? {
        return userDefaults.string(forKey: apiKeykey)
    }
    
    func clearApiKey() {
        userDefaults.removeObject(forKey: apiKeykey)
    }
}
