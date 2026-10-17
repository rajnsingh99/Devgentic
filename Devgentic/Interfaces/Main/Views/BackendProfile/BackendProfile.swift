// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
import os

private let logger = DGLogger(category: "BackendProfile")

// MARK: - Compatibility Typealias
//
// The execution layer, ChatOps bridges, and many views still reference `BackendProfileModel`.
// Rather than renaming 40+ files in one pass, we alias to the Sendable snapshot struct
// defined in BackendProfileSD.swift. This is functionally identical to the old struct.
typealias BackendProfileModel = BackendProfileSnapshot

extension BackendProfileSnapshot {
    /// The single-model LLM config that drives a chat / agent / code run, if this profile has one.
    /// `nil` for `.workflow` (each node resolves its own model) and `.imageGen`. Used to stamp the
    /// run's model identity (provider / model / dialect) onto the produced message (G1 Piece 1).
    var resolvedLLMConfig: ProviderConfig? {
        switch details {
        case .bot(let config): return config.llmConfig
        case .agent(let config): return config.llmConfig
        case .code(let config): return config.llmConfig
        case .workflow, .imageGen: return nil
        }
    }

    /// Names of the tools this profile actually has switched on. Empty for types that
    /// carry no tools (bot/workflow/imageGen) — the `.stateless` file strategy is only
    /// meaningful when something can act on the paths it hands over.
    var enabledToolNames: Set<String> {
        switch details {
        case .agent(let config), .code(let config):
            return Set(config.tools.filter(\.isEnabled).map(\.name))
        default:
            return []
        }
    }
}

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
    /// Per-tier resilience cap overrides (nil/all-Auto = inherit resolved defaults).
    /// Decouples the parse / tool-failure / repetitive caps the legacy `retryPolicy`
    /// conflated. Transport-tier budgets stay auto-derived from provider class.
    var resilienceOverrides: ResilienceOverrides?

    // Capabilities
    var capabilities: AgentCapabilities

    // History
    var historyStrategy: HistoryStrategy?

    // Skills
    /// Library references — see `SkillSelection` for why a reference rather than a copy. `nil`
    /// and an empty array both mean "links nothing".
    var skillSelections: [SkillSelection]?

    // Code mode metadata (not persisted for agent profiles — only set on ephemeral Code profiles)
    var projectPath: String?

    init(llmConfig: ProviderConfig,
         tools: [Tool] = [],
         description: String? = nil,
         instructions: String? = nil,
         knowledgeSources: [KnowledgeSource]? = nil,
         maxIterations: Int? = nil,
         executionTimeout: TimeInterval? = nil,
         retryPolicy: RetryPolicy? = nil,
         errorRecovery: ErrorRecovery? = nil,
         resilienceOverrides: ResilienceOverrides? = nil,
         capabilities: AgentCapabilities = AgentCapabilities(),
         historyStrategy: HistoryStrategy? = nil,
         skillSelections: [SkillSelection]? = nil,
         projectPath: String? = nil) {
        self.llmConfig = llmConfig
        self.tools = tools
        self.description = description
        self.instructions = instructions
        self.knowledgeSources = knowledgeSources
        self.maxIterations = maxIterations
        self.executionTimeout = executionTimeout
        self.retryPolicy = retryPolicy
        self.errorRecovery = errorRecovery
        self.resilienceOverrides = resilienceOverrides
        self.capabilities = capabilities
        self.historyStrategy = historyStrategy
        self.skillSelections = skillSelections
        self.projectPath = projectPath
    }
}

// MARK: - Agent Resilience Types

struct RetryPolicy: Codable, Hashable, Sendable {
    var maxRetries: Int
    var backoffStrategy: BackoffStrategy

    init(maxRetries: Int = 3,
         backoffStrategy: BackoffStrategy = .exponential) {
        self.maxRetries = maxRetries
        self.backoffStrategy = backoffStrategy
    }

    // Tolerant per-field: a missing or unreadable key falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxRetries = (try? container.decode(Int.self, forKey: .maxRetries)) ?? 3
        self.backoffStrategy = (try? container.decode(BackoffStrategy.self, forKey: .backoffStrategy)) ?? .exponential
    }

    private enum CodingKeys: String, CodingKey {
        case maxRetries, backoffStrategy
    }
}

enum BackoffStrategy: String, Codable, Hashable, Sendable, CaseIterable {
    case fixed
    case exponential
}

struct ErrorRecovery: Codable, Hashable, Sendable {
    var onToolFailure: ToolFailurePolicy
    var onIterationExhaustion: ExhaustionPolicy
    /// Custom message injected into working memory when `.fallbackPrompt` is active.
    /// `nil` uses the default system message.
    var fallbackMessage: String?

    init(onToolFailure: ToolFailurePolicy = .abort,
         onIterationExhaustion: ExhaustionPolicy = .synthesizeBestEffort,
         fallbackMessage: String? = nil) {
        self.onToolFailure = onToolFailure
        self.onIterationExhaustion = onIterationExhaustion
        self.fallbackMessage = fallbackMessage
    }

    // Tolerant per-field (same idiom as RetryPolicy above). With the synthesized decoder, one absent key here
    // failed the whole ProfileDetails decode, which destructively collapses the
    // profile to the default-bot fallback in BackendProfileSD.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.onToolFailure = (try? container.decode(ToolFailurePolicy.self, forKey: .onToolFailure)) ?? .abort
        self.onIterationExhaustion = (try? container.decode(ExhaustionPolicy.self, forKey: .onIterationExhaustion)) ?? .synthesizeBestEffort
        self.fallbackMessage = (try? container.decodeIfPresent(String.self, forKey: .fallbackMessage)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case onToolFailure, onIterationExhaustion, fallbackMessage
    }

    static let defaultFallbackMessage = "Try a completely different approach or answer from your own knowledge without using tools."
}

/// Per-tier resilience caps the user may override (Resilience architecture, Phase B).
///
/// Splits what the legacy single `RetryPolicy.maxRetries` knob conflated — it drove
/// the parse-failure cap, the consecutive-tool-failure cap, AND the repetitive-action
/// cap simultaneously. Each field here is optional: `nil` = inherit the resolved
/// default (`ResolvedResiliencePolicy.resolved` falls back to `RetryPolicy.maxRetries`
/// and then the provider-class default, so old profiles behave identically until a
/// field is explicitly set). The transport tier (HTTP retries/backoff) stays
/// auto-derived from provider class and is deliberately NOT exposed here.
struct ResilienceOverrides: Codable, Hashable, Sendable {
    /// Consecutive malformed-output failures tolerated before aborting. nil = Auto.
    var maxParseFailures: Int?
    /// Consecutive failed tool calls tolerated before the circuit breaker aborts. nil = Auto.
    var maxConsecutiveToolFailures: Int?
    /// Identical-iteration repetitions tolerated before aborting a degenerate loop
    /// (also governs the per-tool global repetition cap). nil = Auto.
    var maxRepetitiveActions: Int?
    /// Consecutive user-denied tool calls before the run stops. nil = Auto.
    /// (Clarification loops are handled by RunInteractionMemory replay + the repetition
    /// cap, not a dedicated counter — see CognitiveCircuitBreaker.)
    var maxConsecutiveDenials: Int?

    init(maxParseFailures: Int? = nil,
         maxConsecutiveToolFailures: Int? = nil,
         maxRepetitiveActions: Int? = nil,
         maxConsecutiveDenials: Int? = nil) {
        self.maxParseFailures = maxParseFailures
        self.maxConsecutiveToolFailures = maxConsecutiveToolFailures
        self.maxRepetitiveActions = maxRepetitiveActions
        self.maxConsecutiveDenials = maxConsecutiveDenials
    }

    // Tolerant per-field decoder (same idiom as RetryPolicy/ErrorRecovery) so a
    // future field or a renamed key can never collapse the enclosing profile decode.
    // (Profiles that briefly persisted maxConsecutiveAskUser/maxConsecutiveIdle simply
    // have those keys ignored here.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxParseFailures = (try? container.decodeIfPresent(Int.self, forKey: .maxParseFailures)) ?? nil
        self.maxConsecutiveToolFailures = (try? container.decodeIfPresent(Int.self, forKey: .maxConsecutiveToolFailures)) ?? nil
        self.maxRepetitiveActions = (try? container.decodeIfPresent(Int.self, forKey: .maxRepetitiveActions)) ?? nil
        self.maxConsecutiveDenials = (try? container.decodeIfPresent(Int.self, forKey: .maxConsecutiveDenials)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case maxParseFailures, maxConsecutiveToolFailures, maxRepetitiveActions
        case maxConsecutiveDenials
    }

    /// True when no field is set — used to omit the whole object on encode so an
    /// all-Auto profile stays byte-identical to a pre-Phase-B one.
    var isEmpty: Bool {
        maxParseFailures == nil && maxConsecutiveToolFailures == nil && maxRepetitiveActions == nil
            && maxConsecutiveDenials == nil
    }
}

enum ToolFailurePolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case abort
    case skipAndContinue
    case fallbackPrompt

    var id: String { rawValue }

    // ⚠️ register A63 — the `String` `displayName` that lived here is now
    // `localizedTitle: LocalizedStringKey` in `ProfileEnumLocalizedTitles.swift`. It cannot live
    // beside the enum: this file is Foundation-only by design (these types are Codable and reach
    // SwiftData/JSON) and `LocalizedStringKey` is SwiftUI. `rawValue` is unchanged and remains the
    // persistence/telemetry identifier.
}

enum ExhaustionPolicy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case synthesizeBestEffort
    case failHard

    var id: String { rawValue }

    // ⚠️ register A63 — the `String` `displayName` that lived here is now
    // `localizedTitle: LocalizedStringKey` in `ProfileEnumLocalizedTitles.swift`. It cannot live
    // beside the enum: this file is Foundation-only by design (these types are Codable and reach
    // SwiftData/JSON) and `LocalizedStringKey` is SwiftUI. `rawValue` is unchanged and remains the
    // persistence/telemetry identifier.
}

// MARK: - History Strategy

/// Controls how conversation history is delivered to the LLM.
/// Native providers receive proper user/assistant turn pairs;
/// non-native providers receive XML episodic memory in the system prompt.
enum HistoryStrategy: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    /// Last 10 turns — default for all profiles.
    case recentHistory
    /// Full conversation history, token-capped at 60% of context window.
    case fullHistory
    /// All turns as skeletons (goal, tools, status) with on-demand detail via tool call.
    case pointer
    /// Last 3 turns inline + older turns as pointer skeletons. Best balance of context and tokens.
    case hybrid

    var id: String { rawValue }

    // ⚠️ register A63 — the `String` `displayName` that lived here is now
    // `localizedTitle: LocalizedStringKey` in `ProfileEnumLocalizedTitles.swift`. It cannot live
    // beside the enum: this file is Foundation-only by design (these types are Codable and reach
    // SwiftData/JSON) and `LocalizedStringKey` is SwiftUI. `rawValue` is unchanged and remains the
    // persistence/telemetry identifier.

    // ⚠️ register A63 — `strategyDescription` moved to `HistoryStrategy.localizedDescription`
    // in `ProfileEnumLocalizedTitles.swift`. See the note on the title above.

    var icon: String {
        switch self {
        case .recentHistory: "clock"
        case .fullHistory: "text.book.closed"
        case .pointer: "sparkle.magnifyingglass"
        case .hybrid: "brain"
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
    /// Human-readable summary of enabled capabilities for logging/display.
    var summary: String {
        var parts: [String] = ["ReAct"]
        if planning != nil { parts.append("Planning") }
        if selfReflection != nil { parts.append("Self-Reflection") }
        if agentDelegation != nil { parts.append("Delegation") }
        return parts.joined(separator: " + ")
    }
}

struct PlanningCapabilityConfig: Codable, Hashable, Sendable {
    var maxSubtasks: Int
    var parallelSubtasks: Bool
    var subtaskToolFiltering: Bool
    var requiresPlanApproval: Bool
    /// When true, the planner may ask the user ONE clarifying question before
    /// producing the plan (a vague task otherwise forces it to guess the plan's
    /// shape). Capped at a single round; the answer is recorded into the run's
    /// interaction memory so identical `ask_user` re-asks during execution replay it.
    var clarifyBeforePlanning: Bool

    // parallelSubtasks default changed to false: parallel execution serializes at the
    // LLM layer (single GPU for local, rate-limited for cloud) making it illusory.
    // Field retained for future batch inference / multi-model routing support.
    init(maxSubtasks: Int = 5, parallelSubtasks: Bool = false, subtaskToolFiltering: Bool = true, requiresPlanApproval: Bool = false, clarifyBeforePlanning: Bool = true) {
        self.maxSubtasks = maxSubtasks
        self.parallelSubtasks = parallelSubtasks
        self.subtaskToolFiltering = subtaskToolFiltering
        self.requiresPlanApproval = requiresPlanApproval
        self.clarifyBeforePlanning = clarifyBeforePlanning
    }

    // Backward-compat: persisted configs predating `clarifyBeforePlanning` decode
    // with its default (same tolerant pattern as AgentDelegationConfig).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxSubtasks = (try? container.decode(Int.self, forKey: .maxSubtasks)) ?? 5
        self.parallelSubtasks = (try? container.decode(Bool.self, forKey: .parallelSubtasks)) ?? false
        self.subtaskToolFiltering = (try? container.decode(Bool.self, forKey: .subtaskToolFiltering)) ?? true
        self.requiresPlanApproval = (try? container.decode(Bool.self, forKey: .requiresPlanApproval)) ?? false
        self.clarifyBeforePlanning = (try? container.decode(Bool.self, forKey: .clarifyBeforePlanning)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case maxSubtasks, parallelSubtasks, subtaskToolFiltering, requiresPlanApproval, clarifyBeforePlanning
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
    /// Maximum number of spawned agents that can run in parallel.
    var maxConcurrentAgents: Int
    /// ReAct loop iteration cap for each spawned agent.
    var maxIterationsPerAgent: Int

    init(maxConcurrentAgents: Int = 3, maxIterationsPerAgent: Int = 10) {
        self.maxConcurrentAgents = maxConcurrentAgents
        self.maxIterationsPerAgent = maxIterationsPerAgent
    }

    // Backward-compat: decode old formats gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxConcurrentAgents = (try? container.decode(Int.self, forKey: .maxConcurrentAgents)) ?? 3
        self.maxIterationsPerAgent = (try? container.decode(Int.self, forKey: .maxIterationsPerAgent)) ?? 10
    }

    private enum CodingKeys: String, CodingKey {
        case maxConcurrentAgents, maxIterationsPerAgent
    }
}

/// Configuration for a Workflow profile.
///
/// Holds no stored settings today: the graph lives in the layout (`WorkflowLayoutSD`), and retry,
/// timeout and approval are per node (`WorkflowNodeConfig`). It stays a struct so `.workflow` has a
/// payload to grow into without a format change.
struct WorkflowConfig: Codable, Hashable, Sendable {
    /// The config a NEWLY CREATED workflow profile gets.
    static func forNewProfile() -> WorkflowConfig {
        WorkflowConfig()
    }

    /// The bound on a node that sets no `hardTimeout` and whose profile sets no `executionTimeout`.
    ///
    /// Every node kind is bounded, and the clock excludes time parked awaiting a human. A node that
    /// genuinely needs longer sets its own `hardTimeout`, or its bound profile sets
    /// `executionTimeout`, and both win over this.
    static let nodeTimeout: TimeInterval = 120
}

/// Configuration for an Image Generation profile.
struct ImageGenConfig: Codable, Hashable, Sendable {
    var llmConfig: ProviderConfig
    var negativePrompt: String?
    var defaultAspectRatio: ImageAspectRatio?
    var advancedSettings: [String: JSONValue]?
}

// MARK: - Schema Versioning

/// Version of the persisted `ProfileDetails` shape (`configData`).
///
/// ⚠️ HISTORY RESET 2026-10-03, pre-release with no users: versions 1–9 and every upgrade step
/// between them were deleted, and this shape is the new version 1. A stored blob at any other
/// version is NOT upgraded — it is refused and preserved (see `ProfileBlobGate`).
///
/// ⚠️ This number is independent of the SwiftData schema version (`DevgenticSchemaV1`) and of
/// `MARKETING_VERSION`: SwiftData cannot see inside `configData`, so this is the only thing
/// versioning what is actually in there. Bump it for a change to the PERSISTED shape of
/// `ProfileDetails`, and decide then whether older blobs need an upgrade step.
enum ProfileSchemaVersion: Int, Codable, Sendable {
    case v1 = 1

    static let current: ProfileSchemaVersion = .v1
}

/// Decides whether a stored `ProfileDetails` blob is one this build may decode.
enum ProfileBlobGate {

    /// The blob shape this build writes and understands.
    ///
    /// ⚠️ DERIVED from `ProfileSchemaVersion.current`, never written as its own literal. These are
    /// the two halves of one fact — `current` is what the ENCODER stamps
    /// (`ProfileDetails.encode`), this is what the REFUSAL compares against — and as separate
    /// literals they could silently disagree, locking the user out of profiles this very build
    /// just wrote.
    static var currentVersion: Int { ProfileSchemaVersion.current.rawValue }

    /// What `check` concluded about a stored blob.
    enum Verdict {
        /// The current shape (or not a JSON object at all — the decoder reports the real error).
        case decodable
        /// Written by a NEWER build than this one. Refuse; do not guess.
        case tooNew(storedVersion: Int)
        /// Written before the 2026-10-03 history reset. Nothing upgrades it any more.
        case unsupported(storedVersion: Int)
    }

    /// ⚠️ The newer-build refusal is the point (register G18): a blob from the future reported as
    /// "corrupt" invites the user to reconfigure, which overwrites it and makes the loss permanent;
    /// it needs an app update and NO change. This is not hypothetical for an unreleased app: the
    /// store lives in an unsandboxed shared directory, so running an earlier commit is enough.
    static func check(_ data: Data) -> Verdict {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .decodable
        }
        let storedVersion = (json["schemaVersion"] as? Int) ?? 0
        if storedVersion > currentVersion { return .tooNew(storedVersion: storedVersion) }
        if storedVersion < currentVersion { return .unsupported(storedVersion: storedVersion) }
        return .decodable
    }
}


enum ProfileDetails: Codable, Hashable, Sendable {
    case bot(BotConfig)
    case agent(AgentConfig)
    case workflow(WorkflowConfig)
    case imageGen(ImageGenConfig)
    /// Code mode reuses AgentConfig internally. Ephemeral — never persisted to profile store.
    case code(AgentConfig)

    // MARK: - Manual Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileType
        // Bot / Agent / ImageGen share llmConfig
        case llmConfig, instructions
        // Agent-specific
        case tools, description, knowledgeSources
        case maxIterations, executionTimeout, retryPolicy, errorRecovery, resilienceOverrides
        case capabilities, historyStrategy, skillSelections
        // ImageGen-specific
        case negativePrompt, defaultAspectRatio, advancedSettings
        // Code-specific — folder root scoping for code tools (list_directory, glob_files, etc.)
        case projectPath
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
            let resilienceOverrides = try container.decodeIfPresent(ResilienceOverrides.self, forKey: .resilienceOverrides)

            let capabilities = try container.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities)
                ?? AgentCapabilities()
            let historyStrategy = try container.decodeIfPresent(HistoryStrategy.self, forKey: .historyStrategy)
            let skillSelections = try container.decodeIfPresent([SkillSelection].self, forKey: .skillSelections)

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
                resilienceOverrides: resilienceOverrides,
                capabilities: capabilities,
                historyStrategy: historyStrategy,
                skillSelections: skillSelections
            ))

        case .workflow:
            self = .workflow(WorkflowConfig())

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

        case .code:
            // Code mode reuses AgentConfig — decode identically to `.agent` plus `projectPath`.
            // ⚠️ That sentence was ASPIRATIONAL until 2026-08-05: six fields were missing here and
            // in the encode arm, so a code profile's resilience settings never survived a save. See
            // the encode arm for the consequence. Keep the two arms in lockstep — the round-trip
            // test `testCodeProfileRoundTripsEverySettingAgentDoes` fails if they drift.
            let llmConfig = try container.decode(ProviderConfig.self, forKey: .llmConfig)
            let tools = (try? container.decode([Tool].self, forKey: .tools)) ?? []
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            let instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            let knowledgeSources = try container.decodeIfPresent([KnowledgeSource].self, forKey: .knowledgeSources)
            let maxIterations = try container.decodeIfPresent(Int.self, forKey: .maxIterations)
            let executionTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .executionTimeout)
            let retryPolicy = try container.decodeIfPresent(RetryPolicy.self, forKey: .retryPolicy)
            let errorRecovery = try container.decodeIfPresent(ErrorRecovery.self, forKey: .errorRecovery)
            let resilienceOverrides = try container.decodeIfPresent(ResilienceOverrides.self, forKey: .resilienceOverrides)
            let capabilities = (try? container.decode(AgentCapabilities.self, forKey: .capabilities)) ?? AgentCapabilities()
            let historyStrategy = try container.decodeIfPresent(HistoryStrategy.self, forKey: .historyStrategy)
            let skillSelections = try container.decodeIfPresent([SkillSelection].self, forKey: .skillSelections)
            let projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
            self = .code(AgentConfig(
                llmConfig: llmConfig,
                tools: tools,
                description: description,
                instructions: instructions,
                knowledgeSources: knowledgeSources,
                maxIterations: maxIterations,
                executionTimeout: executionTimeout,
                retryPolicy: retryPolicy,
                errorRecovery: errorRecovery,
                resilienceOverrides: resilienceOverrides,
                capabilities: capabilities,
                historyStrategy: historyStrategy,
                skillSelections: skillSelections,
                projectPath: projectPath
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
            // Omit an all-Auto overrides object so unchanged profiles stay byte-identical to pre-Phase-B.
            if let overrides = config.resilienceOverrides, !overrides.isEmpty {
                try container.encode(overrides, forKey: .resilienceOverrides)
            }
            try container.encode(config.capabilities, forKey: .capabilities)
            try container.encodeIfPresent(config.historyStrategy, forKey: .historyStrategy)
            try container.encodeIfPresent(config.skillSelections, forKey: .skillSelections)

        case .workflow:
            try container.encode(ProfileType.workflow, forKey: .profileType)

        case .imageGen(let config):
            try container.encode(ProfileType.imageGen, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(config.negativePrompt, forKey: .negativePrompt)
            try container.encodeIfPresent(config.defaultAspectRatio, forKey: .defaultAspectRatio)
            try container.encodeIfPresent(config.advancedSettings, forKey: .advancedSettings)

        case .code(let config):
            // ⚠️ MUST mirror `.agent` field-for-field, plus `projectPath`. It did not until
            // 2026-08-05: it silently dropped description, knowledgeSources, retryPolicy,
            // errorRecovery, resilienceOverrides and skills, even though its own comment on the
            // decode arm claimed it decoded "identically to .agent plus projectPath".
            //
            // `CodeSessionManager` creates the code profile with
            // `errorRecovery(onToolFailure: .fallbackPrompt)` and `retryPolicy(maxRetries: 3)`, and
            // neither survived a save — they came back nil on the next launch.
            //
            // ⚠️ HONEST SCOPE: this is a LATENT trap, not a live user-visible bug. `AgentConnect`
            // reads resilience under `if case .agent(let agentConfig) = profile.details` (:425), and
            // `.code` falls to the `else` that hardcodes `ErrorRecovery()` anyway — so today the
            // stored value is not consulted for code profiles and the loss is masked. It goes live
            // the moment that guard is widened to include `.code` (a one-line change that would look
            // entirely safe) or a Code-mode settings UI exposes the tool-failure policy. Persisting
            // what the profile actually says is the cheap half of that; the runtime gate is a
            // separate question.
            try container.encode(ProfileType.code, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encode(config.tools, forKey: .tools)
            try container.encodeIfPresent(config.description, forKey: .description)
            try container.encodeIfPresent(config.instructions, forKey: .instructions)
            try container.encodeIfPresent(config.knowledgeSources, forKey: .knowledgeSources)
            try container.encodeIfPresent(config.maxIterations, forKey: .maxIterations)
            try container.encodeIfPresent(config.executionTimeout, forKey: .executionTimeout)
            try container.encodeIfPresent(config.retryPolicy, forKey: .retryPolicy)
            try container.encodeIfPresent(config.errorRecovery, forKey: .errorRecovery)
            // Same all-Auto omission as `.agent`, so unchanged profiles stay byte-identical.
            if let overrides = config.resilienceOverrides, !overrides.isEmpty {
                try container.encode(overrides, forKey: .resilienceOverrides)
            }
            try container.encode(config.capabilities, forKey: .capabilities)
            try container.encodeIfPresent(config.historyStrategy, forKey: .historyStrategy)
            try container.encodeIfPresent(config.skillSelections, forKey: .skillSelections)
            try container.encodeIfPresent(config.projectPath, forKey: .projectPath)
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
    case code = "Code"

    var id: String { self.rawValue }

    /// SF Symbol name for this profile type.
    var iconName: String {
        switch self {
        case .bot:      return "bubble.left.and.text.bubble.right"
        case .agent:    return "cpu"
        case .workflow:  return "point.3.connected.trianglepath.dotted"
        case .imageGen: return "wand.and.sparkles"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// Filled variant for large identity headers (48pt avatars).
    var iconNameFilled: String {
        switch self {
        case .bot:      return "bubble.left.and.text.bubble.right.fill"
        case .agent:    return "cpu.fill"
        case .workflow:  return "point.3.filled.connected.trianglepath.dotted"
        case .imageGen: return "wand.and.sparkles"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        }
    }
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
    /// What to keep when this tool's result is larger than the model's room. Nil = the global
    /// default set in the context gauge. Optional so profiles saved before it decode unchanged.
    var cutStrategy: ContextCutStrategy? = nil
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
   case openRouter = "OpenRouter"
   case openAICompatible = "Custom (OpenAI-Compatible)"

   var id: String { self.rawValue }

    var providerString: String {
        switch self {
        case .google:            return "google"
        case .openAI:            return "openai"
        case .ollama:            return "ollama"
        case .anthropic:         return "anthropic"
        case .mlx:               return "mlx"
        case .openRouter:        return "openrouter"
        case .openAICompatible:  return "openai_compatible"
        }
    }

    /// Whether this provider runs locally on the user's machine.
    /// `.openAICompatible` is HTTP-based (it may point at a localhost server like
    /// LM Studio, but architecturally it's a remote endpoint that flows through
    /// CloudRequestPipeline, not the in-process/Ollama-managed local class).
    /// Whether requests to this provider carry an API key at all. Ollama and MLX never do, so for
    /// them there is nothing to store and every Keychain lookup is wasted — and, if a stray item
    /// ever existed under a changed signature, a needless access prompt.
    ///
    /// ⚠️ Not the same as `!isLocal`: an OpenAI-compatible endpoint may be local and still take a key.
    var usesAPIKey: Bool {
        switch self {
        case .ollama, .mlx: return false
        case .openAI, .anthropic, .google, .openRouter, .openAICompatible: return true
        }
    }

    var isLocal: Bool {
        switch self {
        case .mlx, .ollama: return true
        case .openAI, .anthropic, .google, .openRouter, .openAICompatible: return false
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

    /// Whether extended thinking is active for this model.
    ///
    /// ⚠️ This is a USER PREFERENCE with a detected default — not a detected value. Three things
    /// write it, and only in this order of authority:
    ///   1. **The user**, via the Extended Thinking switch in Advanced Configuration. Always wins
    ///      over detection.
    ///   2. **Detection**, seeding a default *at model-selection time* — when the user picks a
    ///      DIFFERENT model, whose defaults they have not expressed an opinion about yet.
    ///   3. **The runtime**, auto-disabling on a 400 "does not support thinking"
    ///      (`[THINKING_AUTO_HEAL]` in `BackendOrchestrationService`). This outranks the user
    ///      because it is not a guess — the server refused.
    ///
    /// ⚠️ Rule 2 used to run on every REFRESH rather than on selection (register G98).
    /// `ModelPickerView.updateCapabilityLevel` assigned it unconditionally and is called at the end
    /// of every `fetchModels()`, which fires on `.onAppear` — so turning the switch off, saving, and
    /// reopening the editor silently turned it back on. The setting survived exactly until the user
    /// next looked at it. `updateCapabilityLevel` now takes a `seedUserPreferences` flag with NO
    /// default value, so every call site has to decide which of the three writers it is.
    ///
    /// Do not add a fourth writer without deciding where it sits in that order.
    var thinkingEnabled: Bool = false

    /// The model's input/output modalities (e.g. `.visionInput`), seeded by detection
    /// (`MLXTokenizerAnalyzer` / `OllamaShowResponse`) at model-selection time. STORED
    /// (not derived) so the detected capability survives persistence — read by the
    /// vision-input gate. Defaults `.textOnly` (backward-compat for old configs).
    var supportedModalities: SupportedModalities = .textOnly

    /// Context window (tokens) to run Ollama under, set by Code's per-project "Context size"
    /// (2026-09-24). Wins over the Advanced settings, the preset and the auto-default — see
    /// `OllamaRequestOptions.resolve`. Nil everywhere else. Ollama only; other providers ignore it.
    var numCtxOverride: Int?

    /// Convenience: combined profile used for generator + parser routing in AgentConnect.
    var cognitiveProfile: CognitiveProfile {
        CognitiveProfile(capability: cognitiveCapability, dialect: modelDialect, metadata: modelMetadata, modalities: supportedModalities, chatTemplateSource: chatTemplateSource, stopSequences: stopSequences)
    }

    /// Re-baselines the config for a different provider. Everything scoped to the old
    /// provider — endpoint, model, analyzer artifacts, advanced generation params — is
    /// reset to its fresh-config default so a stale value can never leak into requests
    /// against the new provider (e.g. an Ollama `localhost:11434` baseURL sent to OpenAI,
    /// or a tuned local `temperature` silently applied to a cloud model).
    ///
    /// `apiKey` is cleared too (changed 2026-09-27). It used to survive on the theory that "a key
    /// mismatched to the new cloud provider fails visibly in the model-list fetch" — but that fetch
    /// is itself a request to the NEW vendor carrying the OLD vendor's credential, so the "visible
    /// failure" was the leak. Nothing needs restoring on switch-back: since 2026-10-03 the key for
    /// OpenAI, Anthropic, Google and OpenRouter lives once per PROVIDER (`AppProviderKeyStore`) and
    /// `BackendProfile.details` injects the new provider's own key. `.openAICompatible` keys stay per
    /// profile, so switching to it starts empty. `ProviderKeyShape` still refuses at send time any key
    /// that plainly belongs to another vendor.
    /// `cognitiveCapability` is reset to `.none`;
    /// profile-type-aware defaults are layered on by the `onProviderChanged` callbacks
    /// via `ProfileCapabilityFilter`.
    mutating func switchProvider(to newProvider: ApiProvider) {
        apiProvider = newProvider
        apiKey = nil
        modelName = ""
        baseURL = nil
        advancedConfiguration = nil
        cognitiveCapability = .none
        modelDialect = .nativeJSON
        modelMetadata = nil
        chatTemplateSource = .embedded
        stopSequences = []
        thinkingEnabled = false
        supportedModalities = .textOnly
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
         stopSequences: [String] = [],
         thinkingEnabled: Bool = false,
         supportedModalities: SupportedModalities = .textOnly) {
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
        self.thinkingEnabled = thinkingEnabled
        self.supportedModalities = supportedModalities
    }

    // MARK: - Codable Conformance

    enum CodingKeys: String, CodingKey {
        case apiProvider, modelName, apiKey, baseURL, advancedConfiguration, cognitiveCapability, modelDialect, modelMetadata, chatTemplateSource, stopSequences, thinkingEnabled, supportedModalities, numCtxOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.apiProvider = try container.decode(ApiProvider.self, forKey: .apiProvider)
        self.modelName = try container.decode(String.self, forKey: .modelName)
        self.apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey)
        self.baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        self.advancedConfiguration = try container.decodeIfPresent([String: JSONValue].self, forKey: .advancedConfiguration)

        self.cognitiveCapability = try container.decodeIfPresent(ModelCognitiveCapability.self, forKey: .cognitiveCapability) ?? .none

        self.modelDialect = try container.decodeIfPresent(ModelDialect.self, forKey: .modelDialect) ?? .nativeJSON
        self.modelMetadata = try container.decodeIfPresent(ModelMetadata.self, forKey: .modelMetadata)
        self.chatTemplateSource = try container.decodeIfPresent(ChatTemplateSource.self, forKey: .chatTemplateSource) ?? .embedded
        self.stopSequences = try container.decodeIfPresent([String].self, forKey: .stopSequences) ?? []
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        // Backward-compat: old configs have no modalities → text-only.
        self.supportedModalities = try container.decodeIfPresent(SupportedModalities.self, forKey: .supportedModalities) ?? .textOnly
        // ⚠️ Hand-written decoder: a field missing here is encoded and then silently dropped.
        self.numCtxOverride = try container.decodeIfPresent(Int.self, forKey: .numCtxOverride)
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
        try container.encode(thinkingEnabled, forKey: .thinkingEnabled)
        if supportedModalities != .textOnly {
            try container.encode(supportedModalities, forKey: .supportedModalities)
        }
        try container.encodeIfPresent(numCtxOverride, forKey: .numCtxOverride)
    }
}

// MARK: - Tolerant Decoders for Blob-Persisted Types
//
// ⚠️ WHY THESE EXIST — read before deleting one as "redundant".
//
// Everything reachable from `ProfileDetails` is persisted as an opaque JSON blob inside
// `BackendProfile.configData`. SwiftData's schema does not see inside that blob, so adding a
// field to any type below is NOT a schema change: lightweight migration reports nothing, the
// container opens perfectly, and the failure lands at READ time instead.
//
// Swift's SYNTHESIZED `init(from:)` calls `decode(_:forKey:)` for every non-optional stored
// property and does NOT fall back to the property's default value — it throws `keyNotFound`.
// So `var maxOutputBytes: Int = 4096` on `Tool`, which looks entirely routine and compiles
// clean, would make every previously-saved profile undecodable.
//
// Policy below: fields that carry a DEFAULT decode tolerantly (a missing key uses the default);
// fields that genuinely identify the value stay REQUIRED, so a truly corrupt blob still fails
// loudly instead of silently becoming junk.
//
// ⚠️ Each `init(from:)` lives in an EXTENSION, not the struct body — declaring it inline would
// suppress the synthesized memberwise initializer that call sites rely on.
//
// See SWIFTDATA_GAP_REGISTER.md G13/G14 and the invariant in architecture_readme.md §7.

extension Tool {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required: a tool with no name is not addressable, and one with no sourceId or
        // parameters cannot be dispatched. A blob missing these is corrupt, not merely old.
        name = try container.decode(String.self, forKey: .name)
        sourceId = try container.decode(UUID.self, forKey: .sourceId)
        parameters = try container.decode(ToolParameters.self, forKey: .parameters)

        // Tolerant: every field below has a default, so a blob written before it existed is
        // still perfectly usable.
        description = (try? container.decode(String.self, forKey: .description)) ?? ""
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        requiresConfirmation = (try? container.decode(Bool.self, forKey: .requiresConfirmation)) ?? true
        timeout = (try? container.decodeIfPresent(TimeInterval.self, forKey: .timeout)) ?? nil
        timeoutMessage = (try? container.decodeIfPresent(String.self, forKey: .timeoutMessage)) ?? nil
        isFavorite = (try? container.decode(Bool.self, forKey: .isFavorite)) ?? false
        // ⚠️ Every field on `Tool` needs a line HERE — this decoder is hand-written, so a new field
        // is ENCODED by the synthesized encoder and silently DROPPED on the way back. `cutStrategy`
        // shipped exactly like that for a day: the Tool Library's choice saved, and every profile
        // read returned nil (caught 2026-09-24 by `CodeProjectSessionTests`).
        cutStrategy = (try? container.decodeIfPresent(ContextCutStrategy.self, forKey: .cutStrategy)) ?? nil
    }
}

extension SelfReflectionConfig {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Both fields have defaults; neither identifies the value. Fully tolerant.
        maxTrials = (try? container.decode(Int.self, forKey: .maxTrials)) ?? 3
        evaluatorProfileID = (try? container.decodeIfPresent(UUID.self, forKey: .evaluatorProfileID)) ?? nil
    }
}

extension KnowledgeSource {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required: a knowledge source with no location points at nothing.
        location = try container.decode(String.self, forKey: .location)

        // Tolerant: `id` is generated, and `.file` is the only implemented SourceType, so an
        // unknown or missing type degrades to it rather than discarding the whole profile.
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        type = (try? container.decode(SourceType.self, forKey: .type)) ?? .file
    }
}
