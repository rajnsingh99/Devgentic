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
    case anthropic = "Anthropic"
    case google = "Google"
    // Future providers can be added here
    
    var id: String { self.rawValue }
}

/// A unified model to represent a single LLM provider configuration,
/// which can be either a local Ollama instance or a remote API-based service.
struct LLMIntegrationModel: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var providerType: ProviderType
    var lastSelected: Date? // Used for sorting or defaulting

    // --- Ollama-Specific Properties ---
    var ollamaBaseURL: String?
    var ollamaModelName: String?

    // --- Remote API-Specific Properties ---
    var remoteProvider: RemoteProvider?
    var apiKey: String? // Note: For production, use Keychain for secure storage.
    var remoteModelName: String?
    
    // --- Common Advanced Parameters (Optional) ---
    // These can be expanded later if needed
    var temperature: Double?
    var contextWindowSize: Int?

    // MARK: - Initializers & Defaults

    /// Creates a default, empty model.
    static func new() -> LLMIntegrationModel {
        LLMIntegrationModel(id: UUID(), displayName: "New Integration", providerType: .ollama)
    }
    
    /// Provides a default instance for a local Ollama setup.
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
