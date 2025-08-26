//
//  LLMConnectService.swift
//  Devgentic
//
//  Created by Raj Singh on 01/07/25.
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMConnectService")

struct LLMConnectService {

    
    // MARK: - Ollama Validation (Refactored)

    static func validateOllama(config: OllamaConfigModel) async throws -> [String] {
        logger.info("Validating Ollama server at \(config.baseURL)...")
        
        guard let url = URL(string: config.baseURL) else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Invalid Base URL provided."])
        }
        
        let (_, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Ollama server is not responding at \(config.baseURL)."])
        }
        
        logger.info("Ollama server is reachable. Fetching models...")
        let tagsURL = url.appendingPathComponent("/api/tags")
        let (tagsData, tagsResponse) = try await URLSession.shared.data(from: tagsURL)
        
        guard let tagsHttpResponse = tagsResponse as? HTTPURLResponse, (200..<300).contains(tagsHttpResponse.statusCode) else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Could not fetch model list from Ollama."])
        }
        
        let modelsResponse = try JSONDecoder().decode(OllamaTagsResponse.self, from: tagsData)
        let modelNames = modelsResponse.models.map { $0.name }
        
        logger.info("Successfully fetched \(modelNames.count) models from Ollama.")
        return modelNames
    }

    
    // MARK: - Remote API Validation (Refactored)

    static func validateRemoteAPI(config: RemoteConfigModel) async throws -> [String] {
        logger.info("Validating API key for provider: \(config.provider.rawValue)")
        
        switch config.provider {
        case .openAI:
            return try await validateOpenAI(apiKey: config.apiKey)
        case .anthropic:
            return try await validateAnthropic(apiKey: config.apiKey)
        case .google:
            // For Google, we will just validate the API key and return a dummy array
            try await validateGoogle(apiKey: config.apiKey)
            return [] // The model list is now managed locally in AddLLMIntegrationView
        }
    }
    
    // MARK: - Private Provider-Specific Helpers (No change in logic, just callers)
    
    private static func validateOpenAI(apiKey: String) async throws -> [String] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }
        
        if httpResponse.statusCode == 401 { throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI API Key."]) }
        guard (200..<300).contains(httpResponse.statusCode) else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to OpenAI. Status: \(httpResponse.statusCode)"]) }
        
        let modelsResponse = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        let modelNames = modelsResponse.data.map { $0.id }.filter { $0.lowercased().contains("gpt") }.sorted()
        
        logger.info("Successfully fetched \(modelNames.count) models from OpenAI.")
        return modelNames
    }
    
    private static func validateAnthropic(apiKey: String) async throws -> [String] {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let payload: [String: Any] = ["model": "claude-3-haiku-20240307", "max_tokens": 1, "messages": [["role": "user", "content": "test"]]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }

        if httpResponse.statusCode == 401 { throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Invalid Anthropic API Key."]) }
        
        guard (200..<300).contains(httpResponse.statusCode) || httpResponse.statusCode == 400 else {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Anthropic. Status: \(httpResponse.statusCode)"])
        }
        
        logger.info("Anthropic API Key is valid.")
        return ["claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307"]
    }

    private static func validateGoogle(apiKey: String) async throws {
        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.cannotParseResponse) }
        
        if httpResponse.statusCode == 400 { throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "Invalid Google API Key."]) }
        guard (200..<300).contains(httpResponse.statusCode) else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Google. Status: \(httpResponse.statusCode)"]) }
        
        logger.info("Successfully validated Google API Key.")
    }
}


// MARK: - Codable Helper Structs for Parsing

private struct OllamaTagsResponse: Codable { struct Model: Codable { let name: String }; let models: [Model] }
private struct OpenAIModelsResponse: Codable { struct Model: Codable { let id: String }; let data: [Model] }
private struct GoogleModelsResponse: Codable { struct Model: Codable { let name: String; let supportedGenerationMethods: [String] }; let models: [Model] }
