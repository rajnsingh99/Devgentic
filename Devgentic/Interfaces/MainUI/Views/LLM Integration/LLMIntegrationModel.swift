//
//  LLMIntegrationModel.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import Foundation

/// Defines the type of LLM provider.
enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case ollama = "Ollama (Local)"
    case remote = "Remote (API)"
    
    var id: String { self.rawValue }
}

/// Specifies the supported remote API providers.
enum RemoteProvider: String, Codable, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    // --- NEW: Added Anthropic and Google ---
    case anthropic = "Anthropic"
    case google = "Google"
    
    var id: String { self.rawValue }
}

/// A unified model to represent a single LLM provider configuration.
struct LLMIntegrationModel: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var providerType: ProviderType
    var lastSelected: Date?

    var ollamaBaseURL: String?
    var ollamaModelName: String?

    var remoteProvider: RemoteProvider?
    var apiKey: String?
    var remoteModelName: String?
    
    var temperature: Double?
    var contextWindowSize: Int?

    static func new() -> LLMIntegrationModel {
        LLMIntegrationModel(id: UUID(), displayName: "New Integration", providerType: .ollama)
    }
    
    static func defaultOllama() -> LLMIntegrationModel {
        LLMIntegrationModel(
            id: UUID(),
            displayName: "Local Ollama",
            providerType: .ollama,
            lastSelected: Date(),
            ollamaBaseURL: "http://localhost:11434",
            ollamaModelName: "llama3:latest",
            contextWindowSize: 4096
        )
    }
}
