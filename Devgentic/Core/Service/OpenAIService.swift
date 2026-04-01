//
//  OpenAIService.swift
//  Devgentic
//
//  Created by Raj Singh on 28/02/26.
//


import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OpenAIService")

/// Service for interacting with the OpenAI API.
struct OpenAIService {
    
    private struct ModelsResponse: Codable {
        let data: [ModelData]
    }
    
    private struct ModelData: Codable {
        let id: String
    }
    
    /// Fetches the available models from the OpenAI /v1/models endpoint using the provided API key.
    func verifyAndFetchModels(apiKey: String) async throws -> [String] {
        let url = ProviderDefaults.openAIBaseURL.appendingPathComponent("models")
        
        var request = URLRequest(url: url, timeoutInterval: 15.0)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAIService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            // Attempt to parse OpenAI's specific error payload
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let message = errorObj["message"] as? String {
                throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "OpenAIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
        }
        
        let decoder = JSONDecoder()
        let decodedResponse = try decoder.decode(ModelsResponse.self, from: data)
        
        // Extract model IDs
        let modelIDs = decodedResponse.data.map { $0.id }
        
        // OpenAI returns many models (whisper, dall-e, tts, embedding models, etc.).
        // We filter for text generation / chat reasoning models (gpt, o1, o3)
        let chatModels = modelIDs.filter { id in
            let lowercased = id.lowercased()
            return lowercased.contains("gpt") || lowercased.hasPrefix("o1") || lowercased.hasPrefix("o3")
        }
        
        guard !chatModels.isEmpty else {
            throw NSError(domain: "OpenAIService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No compatible chat models found for this API key."])
        }
        
        // Return alphabetically sorted for cleaner UI presentation
        return chatModels.sorted()
    }
}
