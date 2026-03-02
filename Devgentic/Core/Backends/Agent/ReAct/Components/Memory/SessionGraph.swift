//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Memory Architecture Migration - Phase 2 (Pointer-Based Memory)
//

import Foundation

// MARK: - Hierarchical Memory Models

/// Represents a specific action or sub-task the agent took.
/// Maps to the LLM's `goalSummary`. Replaces the old `SubTask` model.
/// Decoupled from database identity constraints.
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
    
    init(id: UUID = UUID(), primaryGoal: String, status: String = "ACTIVE", finalOutcome: String? = nil, summary: String? = nil, actions: [MemoryAction] = []) {
        self.id = id
        self.primaryGoal = primaryGoal
        self.status = status
        self.finalOutcome = finalOutcome
        self.summary = summary
        self.actions = actions
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
    
    /// Generates a pointer-based string representation for the LLM prompt.
    /// It separates older history into lightweight pointers (UUIDs + summaries)
    /// and retains full JSON context only for the recent sliding window.
    func compressWithPointers(windowSize: Int = 5) -> String {
        let totalEpisodes = episodes.count
        
        if totalEpisodes <= windowSize {
            return """
            [RECENT MEMORY - LAST \(totalEpisodes) TURNS]
            \(self.compressForPrompt())
            """
        }
        
        let splitIndex = totalEpisodes - windowSize
        let archivedEpisodes = episodes.prefix(splitIndex)
        let recentEpisodes = episodes.suffix(windowSize)
        
        // Build the pointers string
        var pointersBlock = "[ARCHIVED MEMORY POINTERS]\n"
        for (index, ep) in archivedEpisodes.enumerated() {
            let turnNum = index + 1
            let summaryText = ep.summary ?? ep.primaryGoal
            pointersBlock += "- Turn \(turnNum) [UUID: \(ep.id.uuidString)]: \(summaryText)\n"
        }
        pointersBlock += "(Use conversation_history_tool to retrieve full details if needed)\n"
        
        // Build the recent JSON string by masking older episodes
        var recentGraph = self
        recentGraph.episodes = Array(recentEpisodes)
        let recentJson = recentGraph.compressForPrompt()
        
        return """
        \(pointersBlock)
        [RECENT MEMORY - LAST \(windowSize) TURNS]
        \(recentJson)
        """
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
