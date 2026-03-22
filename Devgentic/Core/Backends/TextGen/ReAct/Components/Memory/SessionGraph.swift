//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Memory Architecture Migration - Phase 3 (XML Episodic Memory)
//

import Foundation

// MARK: - Hierarchical Memory Models

/// Represents a specific action or sub-task the agent took.
/// Maps to the LLM's `goalSummary`. Replaces the old `SubTask` model.
/// Decoupled from database identity constraints.
struct MemoryAction: Sendable, Codable, Identifiable {
    let id: UUID
    let toolName: String
    let intent: String
    var status: String
    var params: [String: String]
    var errorReason: String?
    var logs: [String]
    var artifacts: [MediaArtifact]

    init(id: UUID = UUID(), toolName: String = "", intent: String, status: String, params: [String: String] = [:], errorReason: String? = nil, logs: [String] = [], artifacts: [MediaArtifact] = []) {
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
    
    var status: String
    
    /// Holds the Agent's final synthesized response.
    var finalOutcome: String?
    
    /// NEW: A brief description or intent of the turn for pointer-based memory.
    var summary: String?
    
    var actions: [MemoryAction]

    /// Captures user correction/denial signal for this turn.
    var userCorrection: String?

    init(id: UUID = UUID(), primaryGoal: String, status: String = "ACTIVE", finalOutcome: String? = nil, summary: String? = nil, actions: [MemoryAction] = [], userCorrection: String? = nil) {
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
        return actions.first { $0.status.uppercased() == "ACTIVE" }
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
    
    // MARK: - Legacy Compatibility Layer
    // These properties ensure `ReActAgentExecutor` doesn't break during the transition.

    var primaryGoal: String {
        return episodes.last?.primaryGoal ?? "Waiting for user instruction..."
    }

    var subTasks: [MemoryAction] {
        return episodes.last?.actions ?? []
    }

    func isPathForbidden(_ path: String) -> Bool {
        return negativeConstraints.contains { path.contains($0) }
    }

    // MARK: - Episode Lifecycle Operations

    mutating func closeActiveEpisode(status: String, outcome: String? = nil) {
        if let idx = episodes.lastIndex(where: { $0.status == "ACTIVE" }) {
            episodes[idx].status = status
            if let outcome = outcome {
                episodes[idx].finalOutcome = outcome
            }
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = status
            }
            workingMemory["last_status"] = status
        }
    }

    mutating func cancelActiveEpisode() {
        workingMemory["last_status"] = "CANCELLED"
        if let idx = episodes.lastIndex(where: { $0.status == "ACTIVE" }) {
            episodes[idx].status = "CANCELLED"
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = "CANCELLED"
            }
        }
    }
}

// MARK: - Session Graph Store

/// In-memory cache for active SessionGraph instances, keyed by conversation ID.
/// Replaces the legacy ContextMemoryManager.
class SessionGraphStore {
    static let shared = SessionGraphStore()
    private var graphs: [UUID: SessionGraph] = [:]
    private init() {}

    func getActiveState(for conversationID: UUID) -> SessionGraph {
        return graphs[conversationID] ?? SessionGraph(sessionID: conversationID.uuidString)
    }

    func updateActiveState(conversationID: UUID, state: SessionGraph) {
        graphs[conversationID] = state
    }
}
