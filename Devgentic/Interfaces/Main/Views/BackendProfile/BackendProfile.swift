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
    case bot(llmConfig: ProviderConfig)
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
            self = .bot(llmConfig: llmConfig)
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
        case .bot(let llmConfig):
            try container.encode(ProfileType.bot, forKey: .profileType)
            try container.encode(llmConfig, forKey: .llmConfig)
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
enum ApiProvider: String, Codable, CaseIterable, Identifiable {
   case ollama = "Ollama (Local)"
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
}

/// A type-erased wrapper that allows heterogeneous values [String: Any] to be encoded and decoded.
struct AnyCodable: Codable, Hashable {
    let value: Any
    init<T>(_ value: T?) { self.value = value ?? () }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ()
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let double as Double:
            try container.encode(double)
        case let int as Int:
            try container.encode(int)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded"))
        }
    }
    
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case (is Void, is Void): return true
        case (let l as Bool, let r as Bool): return l == r
        case (let l as Int, let r as Int): return l == r
        case (let l as Double, let r as Double): return l == r
        case (let l as String, let r as String): return l == r
        case (let l as [AnyHashable], let r as [AnyHashable]): return l == r
        case (let l as [String: AnyHashable], let r as [String: AnyHashable]): return l == r
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        if let hashable = value as? AnyHashable {
            hasher.combine(hashable)
        }
    }
}
