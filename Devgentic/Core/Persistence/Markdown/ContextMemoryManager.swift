//
//  ContextMemoryManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  Updated: Memory Architecture Migration - Step 3 (Deprecated DB Logic)
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContextMemoryManager")

/// Manages the persistence of high-level context using a Hierarchical JSON Graph.
/// Shifted from "Core Data JSON Graph Mutator" to an "Ephemeral In-Memory Cache"
/// as part of the SSOT Architecture Migration.
class ContextMemoryManager {
    
    static let shared = ContextMemoryManager()
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // Ephemeral in-memory storage to replace Core Data persistence
    private var ephemeralGraphs: [UUID: SessionGraph] = [:]
    
    // MARK: - Initialization
    
    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    
    // MARK: - Core API: State Management (Ephemeral Memory)
    
    /// Loads the SessionGraph (JSON State) directly from Ephemeral Memory
    func getActiveState(for conversationID: UUID) -> SessionGraph {
        if let state = ephemeralGraphs[conversationID] {
            return state
        }
        logger.debug("No existing ephemeral SessionGraph found for \(conversationID.uuidString). Creating new.")
        return SessionGraph(sessionID: conversationID.uuidString)
    }
    
    /// Persists the SessionGraph directly to Ephemeral Memory
    func updateActiveState(conversationID: UUID, state: SessionGraph) {
        ephemeralGraphs[conversationID] = state
        logger.debug("Updated and saved SessionGraph to Ephemeral Memory for \(conversationID.uuidString)")
    }
    
    // MARK: - Legacy / Compatibility Shims
    
    func appendToHistory(conversationID: UUID, content: String) {
        logger.debug("Legacy appendToHistory ignored. Handled by graph mutator. Content: \(content)")
    }
    
    func getRecentHistory(for conversationID: UUID, lines limit: Int) -> String {
        let graph = getActiveState(for: conversationID)
        let recentLogs = graph.episodes
            .flatMap { $0.actions }
            .flatMap { $0.logs }
            .suffix(limit)
        
        if recentLogs.isEmpty { return "(No recent history)" }
        return "... (Previous history compressed) ...\n" + recentLogs.joined(separator: "\n")
    }
    
    func listRecentSessions() -> [URL] {
        // Deprecated: No longer using file-based or DB-based session list
        return []
    }
}
