//
//  BackendProfile.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored to a unified model on 26/08/25.
//  Fixed on 27/08/25 to correct AnyCodable decoding order.
//  Fixed on 27/08/25 to correct AnyCodable encoding order to prevent precision loss.
//  Updated on 05/09/25 to expand Agent configuration.
//  Updated on 17/09/25 to add executable tool protocols.
//  Updated on 28/01/26 to add AgentArchitecture.
//  Updated to add supportsNativeTools to ProviderConfig for dynamic capability routing.
//

import Foundation

// MARK: - Unified Backend Profile Model

/// A single, unified model to represent any backend configuration: a bot, an agent, or a workflow.
/// This struct replaces the previous protocol-based approach with a more concrete and type-safe design.
struct BackendProfileModel: Codable, Identifiable, Hashable {
    // MARK: Core Properties (Common to all types)
    let id: UUID
    var displayName: String
    var lastSelected: Date?

    var details: ProfileDetails

    var profileType: ProfileType {
        switch details {
        case .bot:
            return .bot
        case .agent:
            return .agent
        case .workflow:
            return .workflow
        }
    }

    // MARK: Initializers
    init(id: UUID = UUID(), displayName: String, lastSelected: Date? = nil, details: ProfileDetails) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.details = details
    }
}

// MARK: - Profile Details Enum

enum ProfileDetails: Codable, Hashable {
    case bot(llmConfig: ProviderConfig, instructions: String?)
    // Updated to include architecture
    case agent(llmConfig: ProviderConfig, architecture: AgentArchitecture, tools: [Tool], description: String?, instructions: String?, knowledgeSources: [KnowledgeSource]?)
    case workflow(agents: [BackendProfileModel])

    // MARK: - Manual Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case profileType, llmConfig, architecture, tools, agents, description, instructions, knowledgeSources
    }

    // Custom decoder to handle the different cases based on the `profileType` key.
    // This allows us to parse a single JSON object into the correct enum case.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProfileType.self, forKey: .profileType)

        switch type {
        case .bot:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            self = .bot(llmConfig: llmConfig, instructions: instructions)
        case .agent:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            // Decode architecture, default to .reAct for backward compatibility
            let architecture = try container.decodeIfPresent(AgentArchitecture.self, forKey: .architecture) ?? .reAct
            let tools = try container.decode([Tool].self, forKey: .tools)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            let knowledgeSources = try container.decodeIfPresent([KnowledgeSource].self, forKey: .knowledgeSources)
            self = .agent(llmConfig: llmConfig, architecture: architecture, tools: tools, description: description, instructions: instructions, knowledgeSources: knowledgeSources)
        case .workflow:
            let agents = try container.decode([BackendProfileModel].self, forKey: .agents)
            self = .workflow(agents: agents)
        }
    }

    // Custom encoder to write the correct data based on the enum's case.
    // This ensures the serialized output (e.g., JSON) has a clear type identifier.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .bot(let llmConfig, let instructions):
            try container.encode(ProfileType.bot, forKey: .profileType)
            try container.encode(llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(instructions, forKey: .instructions)
        case .agent(let llmConfig, let architecture, let tools, let description, let instructions, let knowledgeSources):
            try container.encode(ProfileType.agent, forKey: .profileType)
            try container.encode(llmConfig, forKey: .llmConfig)
            try container.encode(architecture, forKey: .architecture) // Encode architecture
            try container.encode(tools, forKey: .tools)
            try container.encodeIfPresent(description, forKey: .description)
            try container.encodeIfPresent(instructions, forKey: .instructions)
            try container.encodeIfPresent(knowledgeSources, forKey: .knowledgeSources)
        case .workflow(let agents):
            try container.encode(ProfileType.workflow, forKey: .profileType)
            try container.encode(agents, forKey: .agents)
        }
    }
}

// MARK: - Agent Architecture Enum

/// Defines the cognitive architecture used by the agent to process tasks.
enum AgentArchitecture: String, Codable, CaseIterable, Identifiable, Hashable {
    case reAct = "ReAct"
    case planAndExecute = "Plan & Execute"
    case reflexion = "Reflexion"
    case supervisor = "Supervisor"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .reAct: return "Reason & Action loop."
        case .planAndExecute: return "formulates a plan first, then executes it."
        case .reflexion: return "Self-reflects on past actions to improve."
        case .supervisor: return "Delegates tasks to sub-workers."
        }
    }
}

// MARK: - Supporting Structures (Largely Unchanged)

/// An enum to identify the type of backend configuration.
enum ProfileType: String, Codable, CaseIterable, Identifiable {
    case bot = "Bot"
    case agent = "Agent"
    case workflow = "Workflow"

    var id: String { self.rawValue }
}

/// A simple representation of a tool that an agent can use.
struct Tool: Codable, Hashable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    var isEnabled: Bool = true
    var requiresConfirmation: Bool = true
    
    let sourceId: UUID
    let parameters: ToolParameters
}

/// Represents a source of knowledge for an agent, which can be a local file or a remote URL.
struct KnowledgeSource: Codable, Hashable, Identifiable {
    let id = UUID()
    var type: SourceType
    var location: String

    enum SourceType: String, Codable {
        case file = "File"
        case url = "URL"
    }
}


/// A single, unified list of all supported provider types.
/// A single, unified list of all supported provider types.
enum ApiProvider: String, Codable, CaseIterable, Identifiable {
   case ollama = "Ollama (Local)"
   case mlx = "MLX (Apple Silicon)" // <--- NEW CASE
   case openAI = "OpenAI"
   case anthropic = "Anthropic"
   case google = "Google"
   
   var id: String { self.rawValue }
    
    var providerString: String {
        switch self {
        case .google:
            return "google"
        case .openAI:
            return "openai"
        case .ollama:
            return "ollama"
        case .anthropic:
            return "anthropic"
        case .mlx:
            return "mlx"
        }
    }
}

/// A single, unified configuration model for all LLM providers.
struct ProviderConfig: Codable, Hashable {
    var apiProvider: ApiProvider
    var modelName: String
    var apiKey: String?
    var baseURL: String?
    var advancedConfiguration: [String: AnyCodable]?
    
    /// Indicates if the selected model explicitly supports the native tools API format.
    /// This state drives the routing decision in AgentConnect.
    var supportsNativeTools: Bool = false
    
    // Explicit memberwise initializer to support default value for supportsNativeTools
    init(apiProvider: ApiProvider, modelName: String, apiKey: String? = nil, baseURL: String? = nil, advancedConfiguration: [String: AnyCodable]? = nil, supportsNativeTools: Bool = false) {
        self.apiProvider = apiProvider
        self.modelName = modelName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.advancedConfiguration = advancedConfiguration
        self.supportsNativeTools = supportsNativeTools
    }
    
    // MARK: - Codable Conformance
    
    enum CodingKeys: String, CodingKey {
        case apiProvider, modelName, apiKey, baseURL, advancedConfiguration, supportsNativeTools
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiProvider = try container.decode(ApiProvider.self, forKey: .apiProvider)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.advancedConfiguration = try container.decodeIfPresent([String: AnyCodable].self, forKey: .advancedConfiguration)
        
        // Safely decode the new property, defaulting to false for legacy profiles that lack this key
        self.supportsNativeTools = try container.decodeIfPresent(Bool.self, forKey: .supportsNativeTools) ?? false
    }
}
