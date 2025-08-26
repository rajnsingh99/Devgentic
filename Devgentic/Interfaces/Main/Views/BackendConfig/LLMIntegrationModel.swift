import Foundation

enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case ollama = "Ollama (Local)"
    case remote = "Remote (API)"
    
    var id: String { self.rawValue }
}


enum RemoteProvider: String, Codable, CaseIterable, Identifiable {
    case openAI = "OpenAI"
    case anthropic = "Anthropic"
    case google = "Google"
    
    var id: String { self.rawValue }
}


struct LLMIntegrationModel: Codable, Identifiable, Hashable {
    
    let id: UUID
    var displayName: String
    var providerType: ProviderType
    var lastSelected: Date?
    
    var ollamaConfig: OllamaConfigModel?
    var remoteConfig: RemoteConfigModel?

    static func new() -> LLMIntegrationModel {
        LLMIntegrationModel(
            id: UUID(),
            displayName: "New Integration",
            providerType: .ollama,
            ollamaConfig: OllamaConfigModel(baseURL: "http://localhost:11434",
            modelName: "",
            generationType: [.text]),
            remoteConfig: nil
        )
    }
    
    static func defaultOllama() -> LLMIntegrationModel {
        LLMIntegrationModel(
            id: UUID(),
            displayName: "Local Ollama",
            providerType: .ollama,
            lastSelected: Date(),
            ollamaConfig: OllamaConfigModel(
                baseURL: "http://localhost:11434",
                modelName: "llama3:latest",
                generationType: [.text],
                temperature: 0.8,
                contextWindowSize: 4096
            ),
            remoteConfig: nil
        )
    }
}

struct OllamaConfigModel: Codable, Hashable {
    var baseURL: String
    
    var modelName: String
    
    var generationType: [GenerationType]?
    
    var temperature: Double?
    
    var contextWindowSize: Int?
}

struct RemoteConfigModel: Codable, Hashable {
    var provider: RemoteProvider
    
    var apiKey: String
    
    var modelName: String
    
    var generationType: [GenerationType]?
    
    var temperature: Double?
    
    var contextWindowSize: Int?
}

// MARK: - New Enum for Model Types
enum GenerationType: String, Codable, CaseIterable, Identifiable {
    case text
    case imageData
    case videoData
    
    var id: String { self.rawValue }
}
