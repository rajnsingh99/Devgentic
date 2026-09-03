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
    var skillConfig: SkillFolderConfig?

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
         skillConfig: SkillFolderConfig? = nil,
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
        self.skillConfig = skillConfig
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

    // Backward-compat: silently ignore the removed retryableErrors field on decode
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

    // Backward-compat: tolerate missing/renamed keys per-field (same idiom as
    // RetryPolicy above). With the synthesized decoder, one absent key here
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

/// Configuration for a Workflow profile (DAG of agent references + execution defaults).
struct WorkflowConfig: Codable, Hashable, Sendable {
    /// RETIRED 2026-08-29 — no longer recomputed, and read by nothing that matters.
    ///
    /// ⚠️ It was a parallel list of the profile ids a workflow's nodes referenced, resynced from the
    /// layout on every canvas save. Two things ended it: a workflow's nodes now OWN their
    /// configuration, so there is no shared profile to list; and the layout was always the real
    /// record — `ProfileReferenceIndex` and `WorkflowExecutor` both deliberately read it instead,
    /// because this list "is not kept in step".
    ///
    /// ⚠️ THE PROPERTY AND ITS CODING KEY STAY — but NOT to protect user data. Devgentic is
    /// pre-release and the pre-ownership workflows this once guarded were deleted by the owner on
    /// 2026-08-29, so there are no stale lists left to preserve. It stays because removing a key
    /// from `ProfileDetails` means touching its 7-step migration ladder and the newer-build refusal,
    /// which is more risk than an inert `[UUID]` costs. Any value still present is dead weight.
    ///
    /// ⚠️ Do NOT reintroduce a blocking validation rule on it. One existed ("Workflow must reference
    /// at least one agent profile") and register B36 records why it was dangerous even while the
    /// field WAS maintained: `BackendProfileStore` validates `strict: isUpdate`, so an empty list
    /// makes every update of that workflow throw — including a rename. With nothing maintaining the
    /// field, such a rule would make every workflow permanently unsaveable.
    var agentProfileIDs: [UUID]

    // MARK: - Execution Defaults (nil = use hardcoded system defaults)

    /// The config a NEWLY CREATED workflow profile gets.
    ///
    /// ⚠️ Exists so this decision is unit-testable. It used to live inline in `AddBackendProfileView`
    /// as `WorkflowConfig(agentProfileIDs: [], nodeTimeoutEnabled: false)` — new workflows were
    /// created UNBOUNDED — and a mutation flipping it back passed every test, because the tests
    /// constructed `WorkflowConfig` directly and never went through the view.
    ///
    /// ⚠️ Bounded by default since 2026-08-13. Unbounded was defensible while the Workflow Settings
    /// sheet let you turn the timeout back on; that sheet is gone, so a profile created unbounded
    /// could never be bounded through any UI. A genuinely long-running node overrides with its own
    /// `hardTimeout`, or its bound profile's `executionTimeout`.
    static func forNewProfile() -> WorkflowConfig {
        WorkflowConfig(agentProfileIDs: [])
    }

    /// ⚠️ RETIRED FROM THE UI 2026-08-13 — decode/encode-only, and the whole Workflow Settings sheet
    /// is gone with it. STILL HONOURED at runtime when non-nil, so an existing workflow keeps the
    /// number it chose.
    ///
    /// The timeout itself is not optional — every node kind is bounded, and the clock excludes time
    /// parked awaiting a human. What was removed is the per-workflow dial: a node that genuinely
    /// needs longer sets its own `hardTimeout`, or its bound profile sets `executionTimeout`, and
    /// both win over this.
    var defaultNodeTimeout: TimeInterval?

    /// ⚠️ RETIRED FROM THE UI 2026-08-13 — decode/encode-only. STILL HONOURED when explicitly
    /// `false`, so a workflow that deliberately ran unbounded keeps doing so.
    ///
    /// ⚠️ New workflows no longer set it (`AddBackendProfileView`), so they are bounded by default.
    /// Creating profiles that are unbounded AND have no UI to change it would strand them.
    var nodeTimeoutEnabled: Bool?

    /// ⚠️ RETIRED 2026-08-12 — decoded and re-encoded so stored profiles round-trip unchanged, but
    /// NEVER read at run time. It never was: the executor only ever consulted per-node
    /// `WorkflowNodeConfig.onFailure` (register WF15), and that per-node policy is itself gone —
    /// failure routing is now the `error` port on the canvas.
    var defaultFailurePolicy: NodeFailurePolicy?

    /// ⚠️ RETIRED FROM THE UI 2026-08-13 — the workflow-level "Default Max Retries" stepper is gone.
    /// Retries are a per-node decision because retry SAFETY differs by node kind: re-running a Code
    /// node is pointless (deterministic — same input, same failure), re-running an Action node can
    /// double-submit a side effect, and re-running a Loop or sub-workflow re-runs everything inside
    /// it. Only Profile and Action nodes ever retried, and that is where the control lives.
    ///
    /// ⚠️ STILL HONOURED AT RUNTIME when non-nil, so a workflow that set it keeps its resilience.
    /// Dropping it outright would silently stop retrying for anyone who had opted in, and a flaky
    /// provider would start failing runs that used to succeed. Logged once per run with the
    /// node-level equivalent.
    var defaultMaxRetries: Int?

    // MARK: - Context Pipeline

    /// ⚠️ RETIRED 2026-08-13 — decode/encode-only, never read. A workflow no longer truncates
    /// upstream output at all (user decision): fitting a node's input is a function of which model
    /// that node runs, which is the author's choice, and a workflow-level character count could not
    /// know it. The old defaults quietly cut a three-paragraph answer on every run.
    ///
    /// ⚠️ Deliberately NOT deleted, same reasoning as `onFailure`, `joinMode` and
    /// `passthroughContent`: the layout blob has no per-element resilience (WF24), so dropping a
    /// Codable key is not free.
    var contextBudgetPerNode: Int?

    /// Maximum total characters for all upstream context combined. nil = 6000.
    var totalContextBudget: Int?

    // MARK: - Advanced

    /// ⚠️ RETIRED 2026-08-13 — decode/encode-only, never read. The "Max Nesting Depth" stepper is
    /// gone, and with it the whole Workflow Settings sheet.
    ///
    /// It could only ever make the limit STRICTER: a hard `WorkflowDepth.maxDepth` is checked first,
    /// so the stepper's 6–10 range did nothing at all, and there is no sensible reason to want
    /// "fail at 2 levels" instead of the engine's limit. Over-deep nesting and sub-workflow cycles
    /// are now reported by `WorkflowValidator` at design time — in the issues panel, as errors that
    /// block the run — rather than as a failure five levels into execution.
    ///
    /// ⚠️ Deliberately NOT deleted, same reasoning as the other retirements: the layout blob has no
    /// per-element resilience (WF24), so dropping a Codable key is not free.
    var maxNestingDepth: Int?

    // MARK: - Resolved Defaults

    var resolvedNodeTimeout: TimeInterval { defaultNodeTimeout ?? 120 }
    /// The workflow-default timeout to actually enforce on nodes that don't set their
    /// own `hardTimeout`, or `nil` when the timeout is disabled (`nodeTimeoutEnabled == false`).
    var effectiveNodeTimeout: TimeInterval? { (nodeTimeoutEnabled ?? true) ? resolvedNodeTimeout : nil }
    /// ⚠️ LEGACY fallback only — see `defaultMaxRetries`. New workflows leave it nil, so a node
    /// without its own `maxNodeRetries` does not retry.
    var resolvedMaxRetries: Int { defaultMaxRetries ?? 0 }
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
    case v4 = 4  // Auto-spawn delegation (subAgents → maxConcurrentAgents + maxIterationsPerAgent)
    case v5 = 5  // Skills support (SkillFolderConfig on AgentConfig)
    case v6 = 6  // Workflow execution config (WorkflowConfig expansion)
    case v7 = 7  // Repairs execute_shell tools stamped with a random sourceId

    static let current: ProfileSchemaVersion = .v7
}

/// Chains versioned transforms to migrate ProfileDetails JSON from older schemas to current.
/// Each migration step operates on raw JSON dictionaries to avoid coupling to current model types.
enum ProfileMigrator {

    /// The blob shape this build writes and understands.
    ///
    /// ⚠️ DERIVED from `ProfileSchemaVersion.current`, never written as its own literal. These are
    /// the two halves of one fact — `current` is what the ENCODER stamps
    /// (`ProfileDetails.encode`), this is what the REFUSAL compares against — and as separate
    /// literals they could silently disagree. The failure that creates is unusually nasty: bump one
    /// and not the other and the app stamps every save with a version it then refuses to read back,
    /// locking the user out of profiles this very build just wrote. Deriving makes that
    /// unrepresentable rather than merely tested for.
    ///
    /// ⚠️ Add a new case to `ProfileSchemaVersion` ONLY together with a matching `migrateToV<n>` step,
    /// and only for a change to the PERSISTED shape of `ProfileDetails`. This number is independent
    /// of the SwiftData schema version (`DevgenticSchemaV1`) and of `MARKETING_VERSION`: SwiftData
    /// cannot see inside `configData`, so this is the only thing versioning what is actually in there.
    static var currentVersion: Int { ProfileSchemaVersion.current.rawValue }

    /// What `migrateIfNeeded` concluded about a stored blob.
    enum MigrationOutcome {
        /// Ready to decode — either already current, or upgraded in memory.
        case migrated(Data)
        /// Written by a NEWER build than this one. Refuse; do not guess.
        case tooNew(storedVersion: Int)
    }

    /// Migrates raw JSON data from any previous schema version to the current version, or refuses
    /// when the data came from a newer build.
    ///
    /// ⚠️ The refusal is the point (register G18). The migration steps are shaped
    /// `if storedVersion < N`, so a blob stamped ABOVE `currentVersion` matched no step, was passed
    /// through untouched, and was then handed to a decoder that could not read it. The failure
    /// surfaced as "this profile is corrupt" when the truth was "this profile is from the future" —
    /// two situations with opposite remedies. Corrupt invites the user to reconfigure, which
    /// overwrites the blob and makes the loss permanent; from-the-future needs them to update the
    /// app and change NOTHING.
    ///
    /// This is not hypothetical for an unreleased app: the store lives in an unsandboxed shared
    /// directory, so checking out an earlier commit and running it is enough.
    static func migrateIfNeeded(_ data: Data) -> MigrationOutcome {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not a JSON object at all. Nothing to migrate and nothing to conclude about its
            // version — hand it to the decoder, which will report the real error.
            return .migrated(data)
        }

        let storedVersion = (json["schemaVersion"] as? Int) ?? 0

        if storedVersion > currentVersion {
            return .tooNew(storedVersion: storedVersion)
        }

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
        if storedVersion < 4 {
            json = migrateToV4(json)
        }
        if storedVersion < 5 {
            json = migrateToV5(json)
        }
        if storedVersion < 6 {
            json = migrateToV6(json)
        }
        if storedVersion < 7 {
            json = migrateToV7(json)
        }

        guard let migrated = try? JSONSerialization.data(withJSONObject: json) else {
            // ⚠️ The migration steps ran but the result could not be re-serialized, so what is
            // returned is the ORIGINAL, UN-migrated blob wearing a `.migrated` label. The decoder's
            // own legacy tolerance may still carry it, which is why this is a degradation rather
            // than a failure — but it must not be silent, because the symptom (a profile that
            // decodes with old-shaped fields) looks nothing like the cause.
            logger.error(
                "[PERSISTENCE] Profile blob migration produced JSON that could not be re-serialized "
                + "(\(data.count) bytes). CONSEQUENCE: the ORIGINAL un-migrated bytes are returned "
                + "instead; the decode may still succeed via legacy tolerance, or fail and mark the "
                + "profile unreadable. The stored bytes are not modified either way."
            )
            return .migrated(data)
        }
        return .migrated(migrated)
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
                // #17: match the current default (parallel subtask execution is off — it's
                // illusory under LLM-layer serialization and lacks cross-sibling HITL
                // serialization). Was hardcoded true, an oversight when the default flipped.
                "parallelSubtasks": false,
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

    /// v3 → v4: Converts inline sub-agents to auto-spawn delegation config.
    private static func migrateToV4(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 4

        guard let profileType = result["profileType"] as? String, profileType == "Agent",
              var capabilities = result["capabilities"] as? [String: Any],
              var delegation = capabilities["agentDelegation"] as? [String: Any]
        else {
            return result
        }

        // Extract settings from old subAgents array
        var maxConcurrent = 3
        var maxIterations = 10
        if let subAgents = delegation["subAgents"] as? [[String: Any]], !subAgents.isEmpty {
            maxConcurrent = max(subAgents.count, 1)
            let iterations = subAgents.compactMap { $0["maxIterations"] as? Int }
            if let maxIter = iterations.max() {
                maxIterations = maxIter
            }
        }

        // Replace with new fields
        delegation.removeValue(forKey: "subAgents")
        delegation["maxConcurrentAgents"] = maxConcurrent
        delegation["maxIterationsPerAgent"] = maxIterations

        capabilities["agentDelegation"] = delegation
        result["capabilities"] = capabilities

        return result
    }

    /// v4 → v5: Skills support. No data transformation needed — `skillConfig` is optional
    /// and defaults to nil via `decodeIfPresent`. This migration just stamps the version.
    private static func migrateToV5(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 5
        return result
    }

    /// v5 → v6: Stamp-only. WorkflowConfig new fields are all optional; nil = system defaults.
    private static func migrateToV6(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 6
        return result
    }

    /// v6 → v7: Repairs `execute_shell` tools stamped with a random `sourceId`.
    ///
    /// ⚠️ A DATA repair, not a shape change — the only such step in this ladder, and deliberately
    /// so. `AgentSkillsSection` auto-added `execute_shell` with
    /// `UUID(uuidString: "00000000-SKIL-AUTO-SHEL-000000000000") ?? UUID()`; that literal is not
    /// valid hex, so the parse failed on every call and each import minted a fresh random id.
    /// Tool dispatch and the Tool Library both key off `sourceId == ToolSource.builtInSourceID`,
    /// so the affected profiles show the tool as OFF while it is live, append a duplicate when the
    /// user ticks it, and can never remove the auto-added copy from any UI.
    ///
    /// Fixing the write site only helps NEW imports; every profile written before it stays broken
    /// forever, and the damage is precisely that the user cannot repair it by hand. So the stored
    /// bytes have to be normalized, and this ladder is the mechanism this codebase has for that.
    ///
    /// ⚠️ Merges rather than blindly rewrites: a profile can hold BOTH the auto-added copy and a
    /// user-ticked one, which would collide on `(name, sourceId)` after the rewrite. The
    /// built-in-sourced entry wins on `requiresConfirmation` and `isEnabled` because that one
    /// records a deliberate choice the user made in the Tool Library; the auto-added copy records
    /// only that an import happened. Never silently relax `requiresConfirmation` here.
    private static func migrateToV7(_ json: [String: Any]) -> [String: Any] {
        var result = json
        result["schemaVersion"] = 7

        guard var tools = result["tools"] as? [[String: Any]] else { return result }
        let builtIn = ToolSource.builtInSourceID.uuidString

        // Case-insensitive: UUID strings round-trip uppercase, but a hand-edited or legacy blob
        // may hold either casing and a miss here would leave the profile unrepaired.
        let orphans = tools.filter {
            ($0["name"] as? String) == "execute_shell"
                && ($0["sourceId"] as? String)?.caseInsensitiveCompare(builtIn) != .orderedSame
        }
        guard !orphans.isEmpty else { return result }

        let canonical = tools.first {
            ($0["name"] as? String) == "execute_shell"
                && ($0["sourceId"] as? String)?.caseInsensitiveCompare(builtIn) == .orderedSame
        }

        // Drop every execute_shell entry, then reinsert exactly one repaired record.
        tools.removeAll { ($0["name"] as? String) == "execute_shell" }

        var repaired = canonical ?? orphans[0]
        repaired["sourceId"] = builtIn
        // The user's Tool Library choice wins where one exists; otherwise keep the auto-added
        // record's own flags, defaulting `requiresConfirmation` to true for a shell tool whose
        // blob predates that field.
        if canonical == nil {
            repaired["requiresConfirmation"] = (orphans[0]["requiresConfirmation"] as? Bool) ?? true
        }
        tools.append(repaired)
        result["tools"] = tools

        let preserved = canonical == nil ? "" : ", preserving the user's Tool Library settings"
        logger.notice("""
            [PERSISTENCE] Repaired \(orphans.count) execute_shell tool record(s) carrying a random \
            sourceId; collapsed to a single built-in-sourced entry\(preserved). CONSEQUENCE: the \
            Tool Library now shows the tool's real state and it can finally be removed.
            """)

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
    /// Code mode reuses AgentConfig internally. Ephemeral — never persisted to profile store.
    case code(AgentConfig)

    // MARK: - Manual Codable Implementation

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileType
        // Bot / Agent / ImageGen share llmConfig
        case llmConfig, instructions
        // Agent-specific
        case architecture // legacy — read for migration, never written
        case tools, description, knowledgeSources
        case maxIterations, executionTimeout, retryPolicy, errorRecovery, resilienceOverrides
        case capabilities, historyStrategy, skillConfig
        // Workflow-specific
        case agentProfileIDs
        case defaultNodeTimeout, defaultFailurePolicy, defaultMaxRetries
        case contextBudgetPerNode, totalContextBudget
        case maxNestingDepth
        // ⚠️ `nodeTimeoutEnabled` was MISSING from all three of CodingKeys / encode / decode until
        // 2026-08-05, so "disable the node timeout" was silently discarded on every save and came
        // back nil — which `effectiveNodeTimeout` reads as "enabled", timing nodes out at the 120 s
        // default the user had explicitly turned off. This coder hand-writes `WorkflowConfig`'s
        // fields one at a time instead of delegating to its synthesized `Codable`, so nothing
        // checks the list against the struct. If you add a field to `WorkflowConfig`, add it here.
        case nodeTimeoutEnabled
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

            // Decode capabilities — if missing (legacy v1), migrate from architecture string
            let capabilities: AgentCapabilities
            if let decoded = try container.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities) {
                capabilities = decoded
            } else {
                // Legacy migration: raw architecture string → capabilities
                let legacyArch = try container.decodeIfPresent(String.self, forKey: .architecture)
                var migrated = AgentCapabilities()
                switch legacyArch {
                case "Plan & Execute": migrated.planning = PlanningCapabilityConfig()
                case "Reflexion": migrated.selfReflection = SelfReflectionConfig()
                case "Supervisor": migrated.agentDelegation = AgentDelegationConfig()
                default: break // "ReAct", "Workflow", nil → base capabilities
                }
                capabilities = migrated
            }

            let historyStrategy = try container.decodeIfPresent(HistoryStrategy.self, forKey: .historyStrategy)
            let skillConfig = try container.decodeIfPresent(SkillFolderConfig.self, forKey: .skillConfig)

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
                skillConfig: skillConfig
            ))

        case .workflow:
            let ids = try container.decodeIfPresent([UUID].self, forKey: .agentProfileIDs) ?? []
            var config = WorkflowConfig(agentProfileIDs: ids)
            config.defaultNodeTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .defaultNodeTimeout)
            config.nodeTimeoutEnabled = try container.decodeIfPresent(Bool.self, forKey: .nodeTimeoutEnabled)
            config.defaultFailurePolicy = try container.decodeIfPresent(NodeFailurePolicy.self, forKey: .defaultFailurePolicy)
            config.defaultMaxRetries = try container.decodeIfPresent(Int.self, forKey: .defaultMaxRetries)
            config.contextBudgetPerNode = try container.decodeIfPresent(Int.self, forKey: .contextBudgetPerNode)
            config.totalContextBudget = try container.decodeIfPresent(Int.self, forKey: .totalContextBudget)
            config.maxNestingDepth = try container.decodeIfPresent(Int.self, forKey: .maxNestingDepth)
            self = .workflow(config)

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
            let skillConfig = try container.decodeIfPresent(SkillFolderConfig.self, forKey: .skillConfig)
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
                skillConfig: skillConfig,
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
            try container.encodeIfPresent(config.skillConfig, forKey: .skillConfig)

        case .workflow(let config):
            try container.encode(ProfileType.workflow, forKey: .profileType)
            try container.encode(config.agentProfileIDs, forKey: .agentProfileIDs)
            try container.encodeIfPresent(config.defaultNodeTimeout, forKey: .defaultNodeTimeout)
            try container.encodeIfPresent(config.nodeTimeoutEnabled, forKey: .nodeTimeoutEnabled)
            try container.encodeIfPresent(config.defaultFailurePolicy, forKey: .defaultFailurePolicy)
            try container.encodeIfPresent(config.defaultMaxRetries, forKey: .defaultMaxRetries)
            try container.encodeIfPresent(config.contextBudgetPerNode, forKey: .contextBudgetPerNode)
            try container.encodeIfPresent(config.totalContextBudget, forKey: .totalContextBudget)
            try container.encodeIfPresent(config.maxNestingDepth, forKey: .maxNestingDepth)

        case .imageGen(let config):
            try container.encode(ProfileType.imageGen, forKey: .profileType)
            try container.encode(config.llmConfig, forKey: .llmConfig)
            try container.encodeIfPresent(config.negativePrompt, forKey: .negativePrompt)
            try container.encodeIfPresent(config.defaultAspectRatio, forKey: .defaultAspectRatio)
            try container.encodeIfPresent(config.advancedSettings, forKey: .advancedSettings)

        case .code(let config):
            // ⚠️ MUST mirror `.agent` field-for-field, plus `projectPath`. It did not until
            // 2026-08-05: it silently dropped description, knowledgeSources, retryPolicy,
            // errorRecovery, resilienceOverrides and skillConfig, even though its own comment on the
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
            try container.encodeIfPresent(config.skillConfig, forKey: .skillConfig)
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
    /// `apiKey` deliberately survives: switching away and back must not destroy a pasted
    /// secret, local providers ignore it, and a key mismatched to the new cloud provider
    /// fails visibly in the model-list fetch. `cognitiveCapability` is reset to `.none`;
    /// profile-type-aware defaults are layered on by the `onProviderChanged` callbacks
    /// via `ProfileCapabilityFilter`.
    mutating func switchProvider(to newProvider: ApiProvider) {
        apiProvider = newProvider
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
        case apiProvider, modelName, apiKey, baseURL, advancedConfiguration, cognitiveCapability, supportsNativeTools, modelDialect, modelMetadata, chatTemplateSource, stopSequences, thinkingEnabled, supportedModalities
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
        self.thinkingEnabled = try container.decodeIfPresent(Bool.self, forKey: .thinkingEnabled) ?? false
        // Backward-compat: old configs have no modalities → text-only.
        self.supportedModalities = try container.decodeIfPresent(SupportedModalities.self, forKey: .supportedModalities) ?? .textOnly
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
