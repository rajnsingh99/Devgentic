//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Memory Architecture Migration - Phase 3 (XML Episodic Memory)
//

import Foundation

// MARK: - Status Vocabularies

/// Lifecycle of a `MemoryEpisode`. Mirrors `ExecutionOutcome` for terminal states
/// and adds `.active` for in-progress episodes that haven't been closed yet.
///
/// Decoupled from `ExecutionOutcome` so the `.active` lifecycle case lives outside
/// the executor's terminal vocabulary. Bridge from executor outcomes via
/// `EpisodeLifecycle(_:)` — there is no inverse because `.active` has no terminal
/// equivalent.
enum EpisodeLifecycle: String, Codable, Sendable {
    case active
    case completed
    case failed
    case cancelled

    /// Maps an executor terminal outcome into the corresponding terminal lifecycle.
    /// Use at every callsite where the executor's `ExecutionOutcome` needs to be
    /// committed back into a SessionGraph episode.
    init(_ outcome: ExecutionOutcome) {
        switch outcome {
        case .completed: self = .completed
        // Degraded success: the run shipped a best-effort answer but did NOT achieve its
        // goal cleanly — episodic memory keeps the failure signal (the executor also
        // passes `.failed` for episodes explicitly; this mapping is the safety net).
        case .completedWithWarnings: self = .failed
        case .failed:    self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

/// Status of a `MemoryAction` within an episode. Mirrors `ToolFailureCategory`'s
/// failure shapes plus `.success` for clean completion and `.active` for
/// in-progress actions. Renders to lowercase via `xmlValue` for `<action status>`
/// emission in the prompt-injected episodic memory.
enum ActionStatus: String, Codable, Sendable {
    case active
    case success
    case denied
    case permissionDenied
    case failed
    case timeout
    case invalidArgs
    case notFound
    case cancelled

    /// Lowercase value used in `<action status="...">` XML attributes.
    /// Multi-word cases use snake_case so the LLM can distinguish them from the
    /// simpler forms; this also matches existing pre-training conventions for
    /// failure-category names in API documentation and chat templates.
    var xmlValue: String {
        switch self {
        case .active:           return "active"
        case .success:          return "success"
        case .denied:           return "denied"
        case .permissionDenied: return "permission_denied"
        case .failed:           return "failed"
        case .timeout:          return "timeout"
        case .invalidArgs:      return "invalid_args"
        case .notFound:         return "not_found"
        case .cancelled:        return "cancelled"
        }
    }

    /// True when this status indicates a non-success terminal state. Used by
    /// the turn-status derivation in pointer/hybrid emitters: any failure
    /// category (not just `failed`/`denied`) marks the parent turn as failed.
    var isFailure: Bool {
        switch self {
        case .active, .success: return false
        default:                return true
        }
    }
}

// MARK: - Hierarchical Memory Models

/// Represents a specific action or sub-task the agent took.
/// Maps to the LLM's `goalSummary`. Replaces the old `SubTask` model.
/// Decoupled from database identity constraints.
struct MemoryAction: Sendable, Codable, Identifiable {
    let id: UUID
    let toolName: String
    let intent: String
    var status: ActionStatus
    var params: [String: String]
    var errorReason: String?
    var logs: [String]
    var artifacts: [MediaArtifact]

    init(id: UUID = UUID(), toolName: String = "", intent: String, status: ActionStatus = .active, params: [String: String] = [:], errorReason: String? = nil, logs: [String] = [], artifacts: [MediaArtifact] = []) {
        self.id = id
        self.toolName = toolName
        self.intent = intent
        self.status = status
        self.params = params
        self.errorReason = errorReason
        self.logs = logs
        self.artifacts = artifacts
    }
}

/// Represents a single overarching interaction turn (User Query -> Agent Response).
/// Ephemeralized: Decoupled from persistent Core Data stores.
struct MemoryEpisode: Sendable, Codable, Identifiable {
    let id: UUID

    /// Holds the User's query for this turn.
    let primaryGoal: String

    var status: EpisodeLifecycle

    /// Holds the Agent's final synthesized response.
    var finalOutcome: String?

    /// NEW: A brief description or intent of the turn for pointer-based memory.
    var summary: String?

    var actions: [MemoryAction]

    /// Captures user correction/denial signal for this turn.
    var userCorrection: String?

    init(id: UUID = UUID(), primaryGoal: String, status: EpisodeLifecycle = .active, finalOutcome: String? = nil, summary: String? = nil, actions: [MemoryAction] = [], userCorrection: String? = nil) {
        self.id = id
        self.primaryGoal = primaryGoal
        self.status = status
        self.finalOutcome = finalOutcome
        self.summary = summary
        self.actions = actions
        self.userCorrection = userCorrection
    }

    /// Returns the currently active action, if any.
    var activeAction: MemoryAction? {
        return actions.first { $0.status == .active }
    }
}

/// The root object for the agent's active cognitive state.
/// Ephemeralized: This is no longer persisted to a database. It represents a computed
/// state dynamically generated from the Single Source of Truth (`ChatMessage` history).
struct SessionGraph: Sendable, Codable {
    let sessionID: String
    var episodes: [MemoryEpisode]
    var negativeConstraints: [String]
    
    /// A simple key-value store that starts fresh on every new user request.
    var workingMemory: [String: String]
    
    init(
        sessionID: String,
        episodes: [MemoryEpisode] = [],
        negativeConstraints: [String] = [],
        workingMemory: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.episodes = episodes
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }
    
    // MARK: - Episode Lifecycle Operations

    /// Closes the active episode using the executor's typed `ExecutionOutcome`.
    /// The lifecycle stamp on the episode and the matching status on the last
    /// action are derived from the same source of truth — no scattered string
    /// literals, no risk of mismatched casing or typos.
    ///
    /// Parameter rename (`status:` → `outcome:`, `outcome:` → `message:`) is
    /// intentional: the new signature is incompatible with the old one so the
    /// compiler flags every callsite during migration.
    mutating func closeActiveEpisode(outcome: ExecutionOutcome, message: String? = nil) {
        let lifecycle = EpisodeLifecycle(outcome)
        if let idx = episodes.lastIndex(where: { $0.status == .active }) {
            episodes[idx].status = lifecycle
            if let message {
                episodes[idx].finalOutcome = message
            }
            // Mirror the new lifecycle onto the last action so `activeAction`
            // doesn't keep returning what is now a terminal-state action.
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = Self.actionStatus(for: lifecycle)
            }
        }
    }

    mutating func cancelActiveEpisode() {
        if let idx = episodes.lastIndex(where: { $0.status == .active }) {
            episodes[idx].status = .cancelled
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = .cancelled
            }
        }
    }

    /// Maps an episode's lifecycle stamp into the action-status vocabulary so the
    /// last action mirrors its parent episode's terminal state. Episode
    /// `.completed` collapses to action `.success`; the other terminals map 1:1.
    private static func actionStatus(for lifecycle: EpisodeLifecycle) -> ActionStatus {
        switch lifecycle {
        case .active:    return .active
        case .completed: return .success
        case .failed:    return .failed
        case .cancelled: return .cancelled
        }
    }
}

// MARK: - Session Graph Store

/// In-memory cache for active SessionGraph instances, keyed by conversation ID.
/// Replaces the legacy ContextMemoryManager.
actor SessionGraphStore {
    static let shared = SessionGraphStore()
    private var graphs: [UUID: SessionGraph] = [:]

    func getActiveState(for conversationID: UUID) -> SessionGraph {
        return graphs[conversationID] ?? SessionGraph(sessionID: conversationID.uuidString)
    }

    func updateActiveState(conversationID: UUID, state: SessionGraph) {
        graphs[conversationID] = state
    }
}
