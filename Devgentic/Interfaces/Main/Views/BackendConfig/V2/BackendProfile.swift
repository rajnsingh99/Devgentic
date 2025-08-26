//
//  BackendProfile.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored to a unified model on 26/08/25.
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

    /// The detailed configuration, specific to the profile type, is stored here.
    var details: ProfileDetails

    /// A computed property to easily identify the type of profile based on the details.
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

/// An enum that holds the specific configuration data for each profile type.
/// This uses associated values to ensure that a profile has exactly the data it needs.
enum ProfileDetails: Codable, Hashable {
    /// A foundational bot powered by a single LLM integration.
    case bot(llmConfig: ProviderConfig)

    /// An agent that extends a bot's capabilities with tools.
    case agent(llmConfig: ProviderConfig, tools: [Tool])

    /// A sequence or graph of other profiles working together.
    /// Note: The array holds the unified `BackendProfileModel` to allow for nested, complex workflows.
    case workflow(agents: [BackendProfileModel])

    // MARK: - Manual Codable Implementation
    
    // Defines the keys used for encoding and decoding to and from formats like JSON.
    private enum CodingKeys: String, CodingKey {
        case profileType, llmConfig, tools, agents
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
            let tools = try container.decode([Tool].self, forKey: .tools)
            self = .agent(llmConfig: llmConfig, tools: tools)
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
        case .agent(let llmConfig, let tools):
            try container.encode(ProfileType.agent, forKey: .profileType)
            try container.encode(llmConfig, forKey: .llmConfig)
            try container.encode(tools, forKey: .tools)
        case .workflow(let agents):
            try container.encode(ProfileType.workflow, forKey: .profileType)
            try container.encode(agents, forKey: .agents)
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
}

/// A single, unified list of all supported provider types.
enum ApiProvider: String, Codable, CaseIterable, Identifiable {
   case ollama = "Ollama (Local)"
   case openAI = "OpenAI"
   case anthropic = "Anthropic"
   case google = "Google"
   var id: String { self.rawValue }
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
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
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
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
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
