//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Hierarchical JSON Memory (Phase 3 Migration - Semantic Compression)
//

import Foundation

// MARK: - Hierarchical Memory Models

/// Represents a specific action or sub-task the agent took.
/// Maps to the LLM's `goalSummary`. Replaces the old `SubTask` model.
struct MemoryAction: Sendable, Codable, Identifiable {
    let id: UUID
    let intent: String
    var status: String
    var logs: [String]
    
    init(id: UUID = UUID(), intent: String, status: String, logs: [String] = []) {
        self.id = id
        self.intent = intent
        self.status = status
        self.logs = logs
    }
}

/// Represents a single overarching user request (e.g., "Move the files").
struct MemoryEpisode: Sendable, Codable, Identifiable {
    let id: UUID
    let primaryGoal: String
    var status: String
    var finalOutcome: String? // NEW: Persists the final synthesized answer across turns
    var actions: [MemoryAction]
    
    init(id: UUID = UUID(), primaryGoal: String, status: String = "ACTIVE", finalOutcome: String? = nil, actions: [MemoryAction] = []) {
        self.id = id
        self.primaryGoal = primaryGoal
        self.status = status
        self.finalOutcome = finalOutcome
        self.actions = actions
    }
    
    /// Returns the currently active action, if any.
    var activeAction: MemoryAction? {
        return actions.first { $0.status.uppercased() == "ACTIVE" }
    }
}

/// The root object for the entire conversation's state graph.
struct SessionGraph: Sendable, Codable {
    let sessionID: String
    var episodes: [MemoryEpisode]
    var negativeConstraints: [String]
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
    
    
    /// Generates a token-efficient JSON string representation for the LLM prompt.
    /// Strips out raw logs from COMPLETED episodes to save context window space,
    /// while keeping the full diagnostic logs for ACTIVE episodes.
    func compressForPrompt() -> String {
        var compressedGraph = self
        
        // Loop through episodes and strip logs for completed tasks
        for i in compressedGraph.episodes.indices {
            if compressedGraph.episodes[i].status.uppercased() == "COMPLETED" {
                for j in compressedGraph.episodes[i].actions.indices {
                    // Semantic Compression: The LLM only needs the intent/status of past actions,
                    // not the raw heavy text output of the logs.
                    compressedGraph.episodes[i].actions[j].logs = []
                }
            }
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(compressedGraph),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
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
}

