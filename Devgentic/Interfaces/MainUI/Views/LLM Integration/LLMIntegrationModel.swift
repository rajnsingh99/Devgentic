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
    
    var id: String { self.rawValue }
}

/// A unified model to represent a single LLM provider configuration.
struct LLMIntegrationModel: Codable, Identifiable, Hashable {
    
    let id: UUID
    var displayName: String
    var providerType: ProviderType
    var lastSelected: Date?
    
    var ollamaConfig: OllamaConfigModel?
    var remoteConfig: RemoteConfigModel?

    /// Creates a new, empty integration model, defaulting to Ollama.
    static func new() -> LLMIntegrationModel {
        LLMIntegrationModel(
            id: UUID(),
            displayName: "New Integration",
            providerType: .ollama,
            ollamaConfig: OllamaConfigModel(baseURL: "http://localhost:11434", modelName: ""),
            remoteConfig: nil
        )
    }
    
    /// Creates a default, fully configured local Ollama integration.
    static func defaultOllama() -> LLMIntegrationModel {
        LLMIntegrationModel(
            id: UUID(),
            displayName: "Local Ollama",
            providerType: .ollama,
            lastSelected: Date(),
            ollamaConfig: OllamaConfigModel(
                baseURL: "http://localhost:11434",
                modelName: "llama3:latest",
                temperature: 0.8,
                contextWindowSize: 4096
            ),
            remoteConfig: nil
        )
    }
}


/// A model to hold configuration specific to an Ollama provider.
struct OllamaConfigModel: Codable, Hashable {
    /// The base URL of the Ollama server (e.g., "http://localhost:11434").
    var baseURL: String
    
    /// The name of the model to be used (e.g., "llama3:latest").
    var modelName: String
    
    /// The temperature setting for the model's responses.
    var temperature: Double?
    
    /// The context window size for the model.
    var contextWindowSize: Int?
}

/// A model to hold configuration specific to a remote API provider.
struct RemoteConfigModel: Codable, Hashable {
    /// The specific remote provider (e.g., OpenAI, Anthropic).
    var provider: RemoteProvider
    
    /// The API key for authenticating with the remote service.
    var apiKey: String
    
    /// The name of the remote model to be used (e.g., "gpt-4o").
    var modelName: String
    
    /// The temperature setting for the model's responses.
    var temperature: Double?
    
    /// The context window size for the model.
    var contextWindowSize: Int?
}


