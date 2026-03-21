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
        case .imageGen:
            return .imageGen
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
    case imageGen(llmConfig: ProviderConfig, negativePrompt: String?, defaultAspectRatio: ImageAspectRatio?, advancedSettings: [String: JSONValue]?)

    // MARK: - Manual Codable Implementation
    
    private enum CodingKeys: String, CodingKey {
        case profileType, llmConfig, architecture, tools, agents, description, instructions, knowledgeSources
        case negativePrompt, defaultAspectRatio, advancedSettings
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
        case .imageGen:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let negativePrompt = try container.decodeIfPresent(String.self, forKey: .negativePrompt)
            let defaultAspectRatio = try container.decodeIfPresent(ImageAspectRatio.self, forKey: .defaultAspectRatio)
            let advancedSettings = try container.decodeIfPresent([String: JSONValue].self, forKey: .advancedSettings)
            self = .imageGen(llmConfig: llmConfig, negativePrompt: negativePrompt, defaultAspectRatio: defaultAspectRatio, advancedSettings: advancedSettings)
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
        case .imageGen(let llmConfig, let negativePrompt, let defaultAspectRatio, let advancedSettings):
            try container.encode(ProfileType.imageGen, forKey: .profileType)
            try container.encode(llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(negativePrompt, forKey: .negativePrompt)
            try container.encodeIfPresent(defaultAspectRatio, forKey: .defaultAspectRatio)
            try container.encodeIfPresent(advancedSettings, forKey: .advancedSettings)
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
    case workflow = "Workflow"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .reAct: return "Reason & Action loop."
        case .planAndExecute: return "formulates a plan first, then executes it."
        case .reflexion: return "Self-reflects on past actions to improve."
        case .supervisor: return "Delegates tasks to sub-workers."
        case .workflow: return "DAG-based multi-node pipeline orchestration."
        }
    }
}

// MARK: - Supporting Structures (Largely Unchanged)

/// An enum to identify the type of backend configuration.
enum ProfileType: String, Codable, CaseIterable, Identifiable {
    case bot = "Bot"
    case agent = "Agent"
    case workflow = "Workflow"
    case imageGen = "Image Generator"

    var id: String { self.rawValue }
}

// MARK: - Image Generation Supporting Types

/// Aspect ratio options for image generation.
enum ImageAspectRatio: String, Codable, CaseIterable, Identifiable, Hashable {
    case square     = "1:1"
    case landscape  = "16:9"
    case portrait   = "9:16"
    case wide       = "21:9"
    case photo      = "4:3"
    case photoPort  = "3:4"

    var id: String { rawValue }

    /// Returns pixel dimensions for a given base resolution.
    func dimensions(baseSize: Int = 1024) -> (width: Int, height: Int) {
        switch self {
        case .square:    return (baseSize, baseSize)
        case .landscape: return (baseSize, Int(Double(baseSize) * 9.0 / 16.0))
        case .portrait:  return (Int(Double(baseSize) * 9.0 / 16.0), baseSize)
        case .wide:      return (baseSize, Int(Double(baseSize) * 9.0 / 21.0))
        case .photo:     return (baseSize, Int(Double(baseSize) * 3.0 / 4.0))
        case .photoPort: return (Int(Double(baseSize) * 3.0 / 4.0), baseSize)
        }
    }
}

/// Quality setting for image generation.
enum ImageQuality: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard = "standard"
    case hd = "hd"

    var id: String { rawValue }
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


/// Represents the detected structural capability of the local LLM model.
enum ModelCognitiveCapability: String, Codable, CaseIterable, Identifiable, Hashable {
    /// No tool support. Must use standard conversational text.
    case none = "None"
    
    /// Supports basic tool calling, but struggles with complex arrays. Needs flat JSON.
    case singleAction = "Single Action"
    
    /// Natively supports complex arrays and multiple parallel tool calls.
    case parallelActions = "Parallel Actions"
    
    var id: String { rawValue }
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
    var advancedConfiguration: [String: JSONValue]?
    
    /// Represents the cognitive capability of the model (e.g. tool calling support).
    /// This state drives the routing decision in AgentConnect.
    var cognitiveCapability: ModelCognitiveCapability = .none

    /// The exact output dialect this model uses for tool calls.
    /// Paired with cognitiveCapability to form a CognitiveProfile at runtime.
    /// Defaults to .nativeJSON for cloud providers; set by analyzers for local models.
    var modelDialect: ModelDialect = .nativeJSON

    /// Rich metadata describing the model's constraints (tier, context, etc).
    var modelMetadata: ModelMetadata?

    /// Describes how to obtain the correct chat template for the model.
    /// Set by MLXTokenizerAnalyzer during model selection; defaults to `.embedded`.
    var chatTemplateSource: ChatTemplateSource = .embedded

    /// Custom stop sequences extracted from the model's tokenizer configuration.
    /// These are turn-boundary tokens that must be detected at the application level
    /// during generation — if the model emits one, generation should stop immediately.
    /// Extracted by `MLXTokenizerAnalyzer` and stored as an intrinsic model property.
    var stopSequences: [String] = []

    /// Convenience: combined profile used for generator + parser routing in AgentConnect.
    var cognitiveProfile: CognitiveProfile {
        CognitiveProfile(capability: cognitiveCapability, dialect: modelDialect, metadata: modelMetadata, chatTemplateSource: chatTemplateSource, stopSequences: stopSequences)
    }

    // Explicit memberwise initializer to support default values
    init(apiProvider: ApiProvider,
         modelName: String,
         apiKey: String? = nil,
         baseURL: String? = nil,
         advancedConfiguration: [String: JSONValue]? = nil,
         cognitiveCapability: ModelCognitiveCapability = .none,
         modelDialect: ModelDialect = .nativeJSON,
         modelMetadata: ModelMetadata? = nil,
         chatTemplateSource: ChatTemplateSource = .embedded,
         stopSequences: [String] = []) {
        self.apiProvider = apiProvider
        self.modelName = modelName
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.advancedConfiguration = advancedConfiguration
        self.cognitiveCapability = cognitiveCapability
        self.modelDialect = modelDialect
        self.modelMetadata = modelMetadata
        self.chatTemplateSource = chatTemplateSource
        self.stopSequences = stopSequences
    }

    // MARK: - Codable Conformance

    enum CodingKeys: String, CodingKey {
        case apiProvider, modelName, apiKey, baseURL, advancedConfiguration, cognitiveCapability, supportsNativeTools, modelDialect, modelMetadata, chatTemplateSource, stopSequences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiProvider = try container.decode(ApiProvider.self, forKey: .apiProvider)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.advancedConfiguration = try container.decodeIfPresent([String: JSONValue].self, forKey: .advancedConfiguration)

        // --- COGNITIVE CAPABILITY MIGRATION LOGIC ---
        // 1. Attempt to decode the new enum directly
        if let capability = try container.decodeIfPresent(ModelCognitiveCapability.self, forKey: .cognitiveCapability) {
            self.cognitiveCapability = capability
        }
        // 2. Fallback: decode legacy boolean and map it
        else if let legacySupported = try container.decodeIfPresent(Bool.self, forKey: .supportsNativeTools) {
            self.cognitiveCapability = legacySupported ? .parallelActions : .singleAction
        }
        // 3. Absolute fallback
        else {
            self.cognitiveCapability = .none
        }

        // Dialect: decode if present, otherwise default to .nativeJSON (safe for cloud providers)
        self.modelDialect = try container.decodeIfPresent(ModelDialect.self, forKey: .modelDialect) ?? .nativeJSON

        // Metadata: decode if present
        self.modelMetadata = try container.decodeIfPresent(ModelMetadata.self, forKey: .modelMetadata)

        // Chat template source: decode if present, otherwise default to .embedded (backward compat)
        self.chatTemplateSource = try container.decodeIfPresent(ChatTemplateSource.self, forKey: .chatTemplateSource) ?? .embedded

        // Stop sequences: decode if present, otherwise empty (backward compat)
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(apiProvider, forKey: .apiProvider)
        try container.encode(modelName, forKey: .modelName)
        try container.encodeIfPresent(apiKey, forKey: .apiKey)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(advancedConfiguration, forKey: .advancedConfiguration)
        try container.encode(cognitiveCapability, forKey: .cognitiveCapability)
        try container.encode(modelDialect, forKey: .modelDialect)
        try container.encodeIfPresent(modelMetadata, forKey: .modelMetadata)
        try container.encode(chatTemplateSource, forKey: .chatTemplateSource)
        if !stopSequences.isEmpty {
            try container.encode(stopSequences, forKey: .stopSequences)
        }
        // We do NOT encode supportsNativeTools anymore, effectively dropping it on next save.
    }
}
