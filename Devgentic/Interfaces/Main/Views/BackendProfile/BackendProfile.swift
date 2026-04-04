//
//  BackendProfile.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored to a unified model on 26/08/25.
//  Migrated to SwiftData on 26/03/26:
//    - ProfileDetails cases now carry single config structs (BotConfig, AgentConfig, etc.)
//    - BackendProfileModel is a typealias for BackendProfileSnapshot (value-type mirror)
//    - Workflow switched from embedded copies to UUID references
//

import Foundation

// MARK: - Compatibility Typealias
//
// The execution layer, ChatOps bridges, and many views still reference `BackendProfileModel`.
// Rather than renaming 40+ files in one pass, we alias to the Sendable snapshot struct
// defined in BackendProfileSD.swift. This is functionally identical to the old struct.
typealias BackendProfileModel = BackendProfileSnapshot

// MARK: - Type-Specific Config Structs

/// Configuration for a simple Bot profile (LLM chat, no tools).
struct BotConfig: Codable, Hashable, Sendable {
    var llmConfig: ProviderConfig
    var instructions: String?
    var knowledgeSources: [KnowledgeSource]?
}

/// Configuration for an Agent profile (tool-using, capability-composed).
struct AgentConfig: Codable, Hashable, Sendable {
    var llmConfig: ProviderConfig
    var tools: [Tool]
    var description: String?
    var instructions: String?
    var knowledgeSources: [KnowledgeSource]?

    // Resilience
    var maxIterations: Int?
    var executionTimeout: TimeInterval?
    var retryPolicy: RetryPolicy?
    var errorRecovery: ErrorRecovery?

    // Capabilities
    var capabilities: AgentCapabilities

    init(llmConfig: ProviderConfig,
         tools: [Tool] = [],
         description: String? = nil,
         instructions: String? = nil,
         knowledgeSources: [KnowledgeSource]? = nil,
         maxIterations: Int? = nil,
         executionTimeout: TimeInterval? = nil,
         retryPolicy: RetryPolicy? = nil,
         errorRecovery: ErrorRecovery? = nil,
         capabilities: AgentCapabilities = AgentCapabilities()) {
        self.llmConfig = llmConfig
        self.tools = tools
        self.description = description
        self.instructions = instructions
        self.knowledgeSources = knowledgeSources
        self.maxIterations = maxIterations
        self.executionTimeout = executionTimeout
        self.retryPolicy = retryPolicy
        self.errorRecovery = errorRecovery
        self.capabilities = capabilities
    }
}

// MARK: - Agent Resilience Types

struct RetryPolicy: Codable, Hashable, Sendable {
    var maxRetries: Int
    var backoffStrategy: BackoffStrategy
    var retryableErrors: Set<RetryableError>

    init(maxRetries: Int = 3,
         backoffStrategy: BackoffStrategy = .exponential,
         retryableErrors: Set<RetryableError> = [.parseFailure, .rateLimit, .networkTimeout]) {
        self.maxRetries = maxRetries
        self.backoffStrategy = backoffStrategy
        self.retryableErrors = retryableErrors
    }
}

enum BackoffStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    case fixed
    case exponential
}

enum RetryableError: String, Codable, Hashable, Sendable {
    case parseFailure
    case rateLimit
    case networkTimeout
    case toolTimeout
}

struct ErrorRecovery: Codable, Hashable, Sendable {
    var onToolFailure: ToolFailurePolicy
    var onIterationExhaustion: ExhaustionPolicy

    init(onToolFailure: ToolFailurePolicy = .abort,
         onIterationExhaustion: ExhaustionPolicy = .synthesizeBestEffort) {
        self.onToolFailure = onToolFailure
        self.onIterationExhaustion = onIterationExhaustion
    }
}

enum ToolFailurePolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case abort
    case skipAndContinue
    case fallbackPrompt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .abort: "Abort"
        case .skipAndContinue: "Skip & Continue"
        case .fallbackPrompt: "Fallback Prompt"
        }
    }
}

enum ExhaustionPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case synthesizeBestEffort
    case failHard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .synthesizeBestEffort: "Best-effort Response"
        case .failHard: "Fail Hard"
        }
    }
}

// MARK: - Agent Capability Types

struct AgentCapabilities: Codable, Hashable, Sendable {
    var planning: PlanningCapabilityConfig?
    var selfReflection: SelfReflectionConfig?
    var agentDelegation: AgentDelegationConfig?

    init(planning: PlanningCapabilityConfig? = nil,
         selfReflection: SelfReflectionConfig? = nil,
         agentDelegation: AgentDelegationConfig? = nil) {
        self.planning = planning
        self.selfReflection = selfReflection
        self.agentDelegation = agentDelegation
    }
}

extension AgentCapabilities {
    /// Derives the legacy architecture for ExecutorFactory routing during the transition period.
    @available(*, deprecated, message: "Temporary bridge — Phase 1 removes architecture-based routing.")
    var derivedArchitecture: AgentArchitecture {
        if agentDelegation != nil { return .supervisor }
        if selfReflection != nil { return .reflexion }
        if planning != nil { return .planAndExecute }
        return .reAct
    }
}

struct PlanningCapabilityConfig: Codable, Hashable, Sendable {
    var maxSubtasks: Int
    var parallelSubtasks: Bool
    var subtaskToolFiltering: Bool
    var requiresPlanApproval: Bool

    init(maxSubtasks: Int = 5, parallelSubtasks: Bool = true, subtaskToolFiltering: Bool = true, requiresPlanApproval: Bool = false) {
        self.maxSubtasks = maxSubtasks
        self.parallelSubtasks = parallelSubtasks
        self.subtaskToolFiltering = subtaskToolFiltering
        self.requiresPlanApproval = requiresPlanApproval
    }
}

struct SelfReflectionConfig: Codable, Hashable, Sendable {
    var maxTrials: Int
    var evaluatorProfileID: UUID?

    init(maxTrials: Int = 3, evaluatorProfileID: UUID? = nil) {
        self.maxTrials = maxTrials
        self.evaluatorProfileID = evaluatorProfileID
    }
}

struct AgentDelegationConfig: Codable, Hashable, Sendable {
    /// Inline sub-agent definitions. Each sub-agent is a leaf-node specialist
    /// that runs plain ReAct with no capabilities and no `call_agent` tool.
    var subAgents: [SubAgentConfig]

    init(subAgents: [SubAgentConfig] = []) {
        self.subAgents = subAgents
    }

    // Backward-compat: decode old maxDelegationDepth/allowedAgentIDs as empty subAgents
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let agents = try? container.decode([SubAgentConfig].self, forKey: .subAgents) {
            self.subAgents = agents
        } else {
            // Legacy format — old fields present, no sub-agents to migrate automatically
            self.subAgents = []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case subAgents
    }
}

/// A lightweight, inline specialist agent defined within a parent agent's config.
/// Sub-agents are leaf nodes: they run plain ReAct with their own model/tools/instructions,
/// but have NO capabilities and NO `call_agent` tool — they cannot delegate further.
struct SubAgentConfig: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var name: String                    // Used in call_agent(agent_name: "...")
    var purpose: String                 // Tool description shown to parent LLM
    var instructions: String            // System prompt when sub-agent runs
    var llmConfig: ProviderConfig       // Model & provider (can differ from parent)
    var tools: [Tool]                   // Selected tools from tool library
    var maxIterations: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        purpose: String = "",
        instructions: String = "",
        llmConfig: ProviderConfig = ProviderConfig(apiProvider: .ollama, modelName: ""),
        tools: [Tool] = [],
        maxIterations: Int = 15
    ) {
        self.id = id
        self.name = name
        self.purpose = purpose
        self.instructions = instructions
        self.llmConfig = llmConfig
        self.tools = tools
        self.maxIterations = maxIterations
    }
}

// MARK: - Legacy Migration Helper

extension AgentConfig {
    /// Migrate from architecture-based to capability-based config.
    static func migrate(fromArchitecture architecture: AgentArchitecture,
                        llmConfig: ProviderConfig,
                        tools: [Tool],
                        description: String?,
                        instructions: String?,
                        knowledgeSources: [KnowledgeSource]?) -> AgentConfig {
        var capabilities = AgentCapabilities()

        switch architecture {
        case .reAct:
            break
        case .planAndExecute:
            capabilities.planning = PlanningCapabilityConfig()
        case .reflexion:
            capabilities.selfReflection = SelfReflectionConfig()
        case .supervisor:
            capabilities.agentDelegation = AgentDelegationConfig()
        case .workflow:
            break
        }

        return AgentConfig(
            llmConfig: llmConfig,
            tools: tools,
            description: description,
            instructions: instructions,
            knowledgeSources: knowledgeSources,
            capabilities: capabilities
        )
    }
}

/// Configuration for a Workflow profile (DAG of agent references).
struct WorkflowConfig: Codable, Hashable, Sendable {
    /// References to agent profiles by UUID — resolved at execution time.
    var agentProfileIDs: [UUID]
}

/// Configuration for an Image Generation profile.
struct ImageGenConfig: Codable, Hashable, Sendable {
    var llmConfig: ProviderConfig
    var negativePrompt: String?
    var defaultAspectRatio: ImageAspectRatio?
    var advancedSettings: [String: JSONValue]?
}

// MARK: - Schema Versioning

/// Current schema version for ProfileDetails serialization.
/// Increment this when the schema changes and add a migration step in `ProfileMigrator`.
enum ProfileSchemaVersion: Int, Codable, Sendable {
    case v1 = 1  // Initial versioned schema (pre-existing data treated as v1)
    case v2 = 2  // Capability-based agents (architecture → capabilities migration)
    case v3 = 3  // Inline sub-agents (delegation maxDelegationDepth/allowedAgentIDs → subAgents)

    static let current: ProfileSchemaVersion = .v3
}

/// Chains versioned transforms to migrate ProfileDetails JSON from older schemas to current.
/// Each migration step operates on raw JSON dictionaries to avoid coupling to current model types.
enum ProfileMigrator {

    /// Migrates raw JSON data from any previous schema version to the current version.
    /// Returns the migrated data ready for decoding, or the original data if already current.
    static func migrateIfNeeded(_ data: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        let storedVersion = (json["schemaVersion"] as? Int) ?? 0

        // Apply migrations in order
        if storedVersion < 1 {
            json = migrateToV1(json)
        }
        if storedVersion < 2 {
            json = migrateToV2(json)
        }
        if storedVersion < 3 {
            json = migrateToV3(json)
        }

        guard let migrated = try? JSONSerialization.data(withJSONObject: json) else {
            return data
        }
        return migrated
    }

    // MARK: - Migration Steps

    /// v0 → v1: Stamps schemaVersion, migrates legacy workflow "agents" array to "agentProfileIDs".
    private static func migrateToV1(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 1

        // Legacy workflow migration: embedded agent snapshots → UUID references
        if let profileType = result["profileType"] as? String, profileType == "Workflow" {
            if result["agentProfileIDs"] == nil, let agents = result["agents"] as? [[String: Any]] {
                let ids = agents.compactMap { $0["id"] as? String }
                result["agentProfileIDs"] = ids
                result.removeValue(forKey: "agents")
            }
        }

        return result
    }

    /// v1 → v2: Converts architecture enum to capabilities struct for Agent profiles.
    private static func migrateToV2(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 2

        guard let profileType = result["profileType"] as? String, profileType == "Agent" else {
            return result
        }

        // Convert architecture → capabilities
        let architecture = result["architecture"] as? String ?? "ReAct"
        var capabilities: [String: Any] = [:]

        switch architecture {
        case "Plan & Execute":
            capabilities["planning"] = [
                "maxSubtasks": 5,
                "parallelSubtasks": true,
                "subtaskToolFiltering": true
            ]
        case "Reflexion":
            capabilities["selfReflection"] = [
                "maxTrials": 3
            ]
        case "Supervisor":
            capabilities["agentDelegation"] = [
                "subAgents": [[String: Any]]()
            ]
        default:
            break // ReAct / Workflow — no capabilities
        }

        result["capabilities"] = capabilities
        result.removeValue(forKey: "architecture")

        return result
    }

    /// v2 → v3: Converts delegation from profile-based (maxDelegationDepth/allowedAgentIDs) to inline sub-agents.
    private static func migrateToV3(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 3

        // Only agent profiles with delegation config need migration
        guard let profileType = result["profileType"] as? String, profileType == "Agent",
              var capabilities = result["capabilities"] as? [String: Any],
              var delegation = capabilities["agentDelegation"] as? [String: Any]
        else {
            return result
        }

        // Replace old fields with empty subAgents array
        delegation.removeValue(forKey: "maxDelegationDepth")
        delegation.removeValue(forKey: "allowedAgentIDs")
        delegation["subAgents"] = [[String: Any]]()

        capabilities["agentDelegation"] = delegation
        result["capabilities"] = capabilities

        return result
    }
}

// MARK: - Profile Details Enum

/// The discriminated union of profile configurations.
/// Each case now carries a single config struct instead of loose associated values.
enum ProfileDetails: Codable, Hashable, Sendable {
    case bot(BotConfig)
    case agent(AgentConfig)
    case workflow(WorkflowConfig)
    case imageGen(ImageGenConfig)

    // MARK: - Manual Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileType
        // Bot / Agent / ImageGen share llmConfig
        case llmConfig, instructions
        // Agent-specific
        case architecture // legacy — read for migration, never written
        case tools, description, knowledgeSources
        case maxIterations, executionTimeout, retryPolicy, errorRecovery
        case capabilities
        // Workflow-specific
        case agentProfileIDs
        // ImageGen-specific
        case negativePrompt, defaultAspectRatio, advancedSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProfileType.self, forKey: .profileType)

        switch type {
        case .bot:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            let knowledgeSources = try container.decodeIfPresent([KnowledgeSource].self, forKey: .knowledgeSources)
            self = .bot(BotConfig(llmConfig: llmConfig, instructions: instructions, knowledgeSources: knowledgeSources))

        case .agent:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let tools = try container.decode([Tool].self, forKey: .tools)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            let knowledgeSources = try container.decodeIfPresent([KnowledgeSource].self, forKey: .knowledgeSources)
            let maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations)
            let executionTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .executionTimeout)
            let retryPolicy = try container.decodeIfPresent(RetryPolicy.self, forKey: .retryPolicy)
            let errorRecovery = try container.decodeIfPresent(ErrorRecovery.self, forKey: .errorRecovery)

            // Decode capabilities — if missing (legacy v1), migrate from architecture
            let capabilities: AgentCapabilities
            if let decoded = try container.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities) {
                capabilities = decoded
            } else {
                // Legacy migration: architecture → capabilities
                let legacyArch = try container.decodeIfPresent(AgentArchitecture.self, forKey: .architecture) ?? .reAct
                var migrated = AgentCapabilities()
                switch legacyArch {
                case .planAndExecute: migrated.planning = PlanningCapabilityConfig()
                case .reflexion: migrated.selfReflection = SelfReflectionConfig()
                case .supervisor: migrated.agentDelegation = AgentDelegationConfig()
                case .reAct, .workflow: break
                }
                capabilities = migrated
            }

            self = .agent(AgentConfig(
                llmConfig: llmConfig,
                tools: tools,
                description: description,
                instructions: instructions,
                knowledgeSources: knowledgeSources,
                maxIterations: maxIterations,
                executionTimeout: executionTimeout,
                retryPolicy: retryPolicy,
                errorRecovery: errorRecovery,
                capabilities: capabilities
            ))

        case .workflow:
            let ids = try container.decodeIfPresent([UUID].self, forKey: .agentProfileIDs) ?? []
            self = .workflow(WorkflowConfig(agentProfileIDs: ids))

        case .imageGen:
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let negativePrompt = try container.decodeIfPresent(String.self, forKey: .negativePrompt)
            let defaultAspectRatio = try container.decodeIfPresent(ImageAspectRatio.self, forKey: .defaultAspectRatio)
            let advancedSettings = try container.decodeIfPresent([String: JSONValue].self, forKey: .advancedSettings)
            self = .imageGen(ImageGenConfig(
                llmConfig: llmConfig,
                negativePrompt: negativePrompt,
                defaultAspectRatio: defaultAspectRatio,
                advancedSettings: advancedSettings
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        // Always stamp the current schema version
        try container.encode(ProfileSchemaVersion.current, forKey: .schemaVersion)

        switch self {
        case .bot(let config):
            try container.encode(ProfileType.bot, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(config.instructions, forKey: .instructions)
            try container.encodeIfPresent(config.knowledgeSources, forKey: .knowledgeSources)

        case .agent(let config):
            try container.encode(ProfileType.agent, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encode(config.tools, forKey: .tools)
            try container.encodeIfPresent(config.description, forKey: .description)
            try container.encodeIfPresent(config.instructions, forKey: .instructions)
            try container.encodeIfPresent(config.knowledgeSources, forKey: .knowledgeSources)
            try container.encodeIfPresent(config.maxIterations, forKey: .maxIterations)
            try container.encodeIfPresent(config.executionTimeout, forKey: .executionTimeout)
            try container.encodeIfPresent(config.retryPolicy, forKey: .retryPolicy)
            try container.encodeIfPresent(config.errorRecovery, forKey: .errorRecovery)
            try container.encode(config.capabilities, forKey: .capabilities)

        case .workflow(let config):
            try container.encode(ProfileType.workflow, forKey: .profileType)
            try container.encode(config.agentProfileIDs, forKey: .agentProfileIDs)

        case .imageGen(let config):
            try container.encode(ProfileType.imageGen, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(config.negativePrompt, forKey: .negativePrompt)
            try container.encodeIfPresent(config.defaultAspectRatio, forKey: .defaultAspectRatio)
            try container.encodeIfPresent(config.advancedSettings, forKey: .advancedSettings)
        }
    }
}

// MARK: - Agent Architecture Enum (Legacy — removed from AgentConfig in v2, kept for executor routing until Phase 1)

/// Legacy architecture enum. No longer stored in AgentConfig; replaced by AgentCapabilities.
/// Retained temporarily for ExecutorFactory routing and profile migration.
@available(*, deprecated, message: "Use AgentCapabilities instead. Will be removed in Phase 1.")
enum AgentArchitecture: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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

// MARK: - Supporting Structures

/// An enum to identify the type of backend configuration.
enum ProfileType: String, Codable, CaseIterable, Identifiable, Sendable {
    case bot = "Bot"
    case agent = "Agent"
    case workflow = "Workflow"
    case imageGen = "Image Generator"

    var id: String { self.rawValue }
}

// MARK: - Image Generation Supporting Types

/// Aspect ratio options for image generation.
enum ImageAspectRatio: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
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
enum ImageQuality: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case standard = "standard"
    case hd = "hd"

    var id: String { rawValue }
}

/// A simple representation of a tool that an agent can use.
struct Tool: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let description: String
    var isEnabled: Bool = true
    var requiresConfirmation: Bool = true

    let sourceId: UUID
    let parameters: ToolParameters

    // Per-tool settings
    var timeout: TimeInterval? = nil
    var timeoutMessage: String? = nil
    var isFavorite: Bool = false
}

/// Represents a source of knowledge for a profile, currently limited to local files.
/// The SourceType enum is preserved for backward compatibility; only `.file` is implemented.
struct KnowledgeSource: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var type: SourceType
    var location: String

    enum SourceType: String, Codable, Sendable {
        case file = "File"
        case url = "URL"
    }

    var url: URL { URL(fileURLWithPath: location) }
    var fileName: String { url.lastPathComponent }
    var isLocalFile: Bool { type == .file }
    var exists: Bool { type == .file && FileManager.default.fileExists(atPath: location) }
}


/// Represents the detected structural capability of the local LLM model.
enum ModelCognitiveCapability: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    /// No tool support. Must use standard conversational text.
    case none = "None"

    /// Supports basic tool calling, but struggles with complex arrays. Needs flat JSON.
    case singleAction = "Single Action"

    /// Natively supports complex arrays and multiple parallel tool calls.
    case parallelActions = "Parallel Actions"

    var id: String { rawValue }
}

/// A single, unified list of all supported provider types.
enum ApiProvider: String, Codable, CaseIterable, Identifiable, Sendable {
   case ollama = "Ollama (Local)"
   case mlx = "MLX (Apple Silicon)"
   case openAI = "OpenAI"
   case anthropic = "Anthropic"
   case google = "Google"

   var id: String { self.rawValue }

    var providerString: String {
        switch self {
        case .google:    return "google"
        case .openAI:    return "openai"
        case .ollama:    return "ollama"
        case .anthropic: return "anthropic"
        case .mlx:       return "mlx"
        }
    }
}

/// A single, unified configuration model for all LLM providers.
struct ProviderConfig: Codable, Hashable, Sendable {
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
        if let capability = try container.decodeIfPresent(ModelCognitiveCapability.self, forKey: .cognitiveCapability) {
            self.cognitiveCapability = capability
        } else if let legacySupported = try container.decodeIfPresent(Bool.self, forKey: .supportsNativeTools) {
            self.cognitiveCapability = legacySupported ? .parallelActions : .singleAction
        } else {
            self.cognitiveCapability = .none
        }

        self.modelDialect = try container.decodeIfPresent(ModelDialect.self, forKey: .modelDialect) ?? .nativeJSON
        self.modelMetadata = try container.decodeIfPresent(ModelMetadata.self, forKey: .modelMetadata)
        self.chatTemplateSource = try container.decodeIfPresent(ChatTemplateSource.self, forKey: .chatTemplateSource) ?? .embedded
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
    }
}
