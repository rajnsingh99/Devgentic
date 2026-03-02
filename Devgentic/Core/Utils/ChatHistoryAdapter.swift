//
//  ChatHistoryAdapter.swift
//  Devgentic
//
//  Created for Memory Architecture Migration.
//  Acts as the Single Source of Truth (SSOT) translator.
//

import Foundation

/// Adapts the visual UI chat history into the cognitive SessionGraph state.
/// Dynamically computes the agent's memory graph per-request, eliminating database bloat.
struct ChatHistoryAdapter {
    
    /// Builds the ephemeral SessionGraph dynamically from the chat history.
    ///
    /// - Parameters:
    ///   - history: The sanitized array of previous ChatMessages (excluding the current pending query).
    ///   - sessionID: The current conversation UUID string.
    /// - Returns: A fully assembled, ephemeral SessionGraph.
    static func buildGraph(from history: [ChatMessage], sessionID: String) -> SessionGraph {
        var episodes: [MemoryEpisode] = []
        var negativeConstraints: Set<String> = []
        
        var pendingUserText: String? = nil
        
        for message in history {
            let text = message.content.textContent ?? ""
            
            if message.sender == .user {
                // Hold the user's message as the start of a potential episode pair
                pendingUserText = text
                
            } else if message.sender == .agent {
                
                var usedTools: [String] = []
                
                // 1. Build Ghost Protocol (Negative Constraints)
                // Scan the artifacts to see what tools failed in the past so the agent doesn't loop.
                for artifact in message.artifacts {
                    usedTools.append(artifact.toolName)
                    if !artifact.isSuccess {
                        // Insert the failed tool name.
                        // (If your ToolOutput model exposes parameters in the future,
                        // you can parse the JSON here to extract and block specific file paths).
                        negativeConstraints.insert(artifact.toolName)
                    }
                }
                
                // 2. Build Episodes
                // Pair the pending user query with this agent response to form a completed episode.
                if let userText = pendingUserText {
                    
                    // --- Vague Breadcrumb Mitigation (Pointer Summaries) ---
                    // Generate a lightweight, 1-sentence summary of what happened during this turn.
                    // This gives the LLM enough context to decide if it needs to retrieve the full turn.
                    let truncatedUser = userText.count > 50 ? String(userText.prefix(47)) + "..." : userText
                    let summary: String
                    
                    if usedTools.isEmpty {
                        summary = "User query: '\(truncatedUser)' -> Agent provided a direct response."
                    } else {
                        let uniqueTools = Array(Set(usedTools)).joined(separator: ", ")
                        summary = "User query: '\(truncatedUser)' -> Agent executed tools: [\(uniqueTools)]."
                    }
                    // -------------------------------------------------------
                    
                    let episode = MemoryEpisode(
                        id: message.id, // CRITICAL: Link episode to actual ChatMessage UUID for retrieval tool
                        primaryGoal: userText,
                        status: "COMPLETED",
                        finalOutcome: text.isEmpty ? "(Agent returned visual output/tool result)" : text,
                        summary: summary,
                        actions: [] // Actions are omitted as we rely on semantic compression
                    )
                    
                    episodes.append(episode)
                    pendingUserText = nil // Reset state for the next pair
                }
            }
        }
        
        // Construct the ephemeral graph.
        // workingMemory starts fresh [:] for the new ReAct loop.
        return SessionGraph(
            sessionID: sessionID,
            episodes: episodes,
            negativeConstraints: Array(negativeConstraints),
            workingMemory: [:]
        )
    }
    
    /// Builds a semantic string representation of recent history for LLM prompt injection.
    ///
    /// - Parameters:
    ///   - history: The array of previous ChatMessages.
    ///   - limit: The maximum number of recent messages to include (default is 10).
    /// - Returns: A formatted string block of recent interactions.
    static func buildRecentHistoryString(from history: [ChatMessage], limit: Int = 10) -> String {
        let recentMessages = history.suffix(limit)
        
        if recentMessages.isEmpty {
            return "(No recent history)"
        }
        
        var historyLines: [String] = []
        
        for msg in recentMessages {
            guard let text = msg.content.textContent, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            
            let role = (msg.sender == .user) ? "User" : "Agent"
            historyLines.append("\(role): \(text)")
        }
        
        if historyLines.isEmpty {
            return "(No recent history)"
        }
        
        return historyLines.joined(separator: "\n\n")
    }
}
