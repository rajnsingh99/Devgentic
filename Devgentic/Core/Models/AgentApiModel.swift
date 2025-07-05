//
//  AgentApiModel.swift
//  Devgentic
//
//  Created by Raj Singh on 09/06/25.
//
//  MODIFIED: This file has been completely updated to match the new
//  backend AgentOrchestrationRequest Pydantic model.
//

import Foundation

// MARK: - Root Payload: AgentOrchestrationRequest

struct AgentOrchestrationRequest: Codable {
    let conversationId: String
    let files: [FileObject]
    let agentConfigs: [AgentConfig]

    enum CodingKeys: String, CodingKey {
        case conversationId = "conversationId"
        case files
        case agentConfigs = "agentConfigs"
    }
}

// MARK: - FileObject

struct FileObject: Codable {
    let uri: String
    let name: String?
}

// MARK: - AgentConfig

struct AgentConfig: Codable {
    let agentId: String
    let parentId: String?
    let roleObjective: String
    let tools: [String]
    let llmSettings: LLMSettings

    enum CodingKeys: String, CodingKey {
        case agentId = "agentId"
        case parentId = "parentId"
        case roleObjective = "roleObjective"
        case tools
        case llmSettings = "llmSettings"
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentId, forKey: .agentId)
        
        if let parentId = self.parentId {
            try container.encode(parentId, forKey: .parentId)
        } else {
            try container.encodeNil(forKey: .parentId)
        }
        
        try container.encode(roleObjective, forKey: .roleObjective)
        try container.encode(tools, forKey: .tools)
        try container.encode(llmSettings, forKey: .llmSettings)
    }
}

// MARK: - LLMSettings (Handles multiple providers)
enum LLMSettings: Codable {
    case ollama(OllamaLLMSettings)
    case remote(RemoteLLMSettings)

    // Custom Codable implementation to handle the discriminated union
    // based on the 'provider' field.
    
    private enum CodingKeys: String, CodingKey {
        case provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(String.self, forKey: .provider)
        
        let singleValueContainer = try decoder.singleValueContainer()
        switch provider {
        case "ollama":
            self = .ollama(try singleValueContainer.decode(OllamaLLMSettings.self))
        case "openai", "google", "anthropic":
            self = .remote(try singleValueContainer.decode(RemoteLLMSettings.self))
        default:
            throw DecodingError.dataCorruptedError(in: singleValueContainer, debugDescription: "Unknown LLM provider: \(provider)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ollama(let settings):
            try container.encode(settings)
        case .remote(let settings):
            try container.encode(settings)
        }
    }
}

// MARK: - Provider-Specific LLMSettings

struct OllamaLLMSettings: Codable {
    let provider: String = "ollama"
    let baseUrl: String
    let modelName: String
    let contextWindowSize: Int?

    enum CodingKeys: String, CodingKey {
        case provider
        case baseUrl = "base_url"
        case modelName = "model_name"
        case contextWindowSize = "context_window_size"
    }
}

struct RemoteLLMSettings: Codable {
    let provider: String // "openai", "google", or "anthropic"
    let modelName: String
    let apiKey: String
    let contextWindowSize: Int?
    
    enum CodingKeys: String, CodingKey {
        case provider
        case modelName = "modelName"
        case apiKey = "apiKey"
        case contextWindowSize = "contextWindowSize"
    }
}
