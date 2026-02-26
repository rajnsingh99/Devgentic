//
//  ContextMemoryManager.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  Updated: Phase 8 - Core Data Session Graph Persistence
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ContextMemoryManager")

/// Manages the persistence of high-level context using a Hierarchical JSON Graph.
/// Shifted from a "text file appender" to a "Core Data JSON Graph Mutator" (Phase 8 Migration).
class ContextMemoryManager {
    
    static let shared = ContextMemoryManager()
    
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    // MARK: - Initialization
    
    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }
    
    // MARK: - Core API: State Management (JSON Graph via Core Data)
    
    /// Loads the SessionGraph (JSON State) directly from Core Data
    func getActiveState(for conversationID: UUID) -> SessionGraph {
        if let data = CoreDataPersistenceService.shared.fetchSessionGraph(for: conversationID),
           let state = try? decoder.decode(SessionGraph.self, from: data) {
            return state
        }
        logger.debug("No existing SessionGraph found for \(conversationID.uuidString). Creating new.")
        return SessionGraph(sessionID: conversationID.uuidString)
    }
    
    /// Persists the SessionGraph directly to Core Data
    func updateActiveState(conversationID: UUID, state: SessionGraph) {
        if let data = try? encoder.encode(state) {
            CoreDataPersistenceService.shared.saveSessionGraph(for: conversationID, graphData: data)
            logger.debug("Updated and saved SessionGraph to Core Data for \(conversationID.uuidString)")
        } else {
            logger.error("Failed to encode SessionGraph for \(conversationID.uuidString)")
        }
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
        // Deprecated: No longer using file-based session list
        return []
    }
}
