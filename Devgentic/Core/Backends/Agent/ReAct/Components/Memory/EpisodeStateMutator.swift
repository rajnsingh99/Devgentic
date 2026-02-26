//
//  EpisodeStateMutator.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "State")

/// A concrete implementation of `EpisodeStateMutating` using value semantics.
/// Encapsulates all persistent state updates and interactions with `ContextMemoryManager`.
struct EpisodeStateMutator: EpisodeStateMutating {
    
    let conversationID: UUID
    private(set) var currentState: SessionGraph
    private(set) var currentConstraints: Set<String>
    
    init(conversationID: UUID, initialState: SessionGraph? = nil) {
        self.conversationID = conversationID
        self.currentState = initialState ?? ContextMemoryManager.shared.getActiveState(for: conversationID)
        self.currentConstraints = Set(self.currentState.negativeConstraints)
    }
    
    // MARK: - Episode Management
    
    mutating func startNewEpisode(goal: String) {
        logState.info("New Top-Level Request Detected: Appending new MemoryEpisode.")
        
        let newEpisode = MemoryEpisode(primaryGoal: goal, status: "ACTIVE", actions: [])
        currentState.episodes.append(newEpisode)
        
        // Clear transient working memory flags
        currentState.workingMemory.removeValue(forKey: "current_focus")
        currentState.workingMemory.removeValue(forKey: "last_status")
        
        saveState()
    }
    
    mutating func forceCloseActiveEpisode(status: String, outcome: String? = nil) {
        if let idx = currentState.episodes.lastIndex(where: { $0.status == "ACTIVE" }) {
            currentState.episodes[idx].status = status
            
            if let outcome = outcome {
                currentState.episodes[idx].finalOutcome = outcome
            }
            
            if let actIdx = currentState.episodes[idx].actions.indices.last {
                 currentState.episodes[idx].actions[actIdx].status = status
            }
            
            currentState.workingMemory["last_status"] = status
            currentState.negativeConstraints = Array(currentConstraints)
            
            saveState()
            logState.info("💾 Auto-Patched Active Episode to: \(status)")
        }
    }
    
    mutating func markAsCancelled() {
        currentState.workingMemory["last_status"] = "CANCELLED"
        if let idx = currentState.episodes.lastIndex(where: { $0.status == "ACTIVE" }) {
            currentState.episodes[idx].status = "CANCELLED"
            if let actIdx = currentState.episodes[idx].actions.indices.last {
                 currentState.episodes[idx].actions[actIdx].status = "CANCELLED"
            }
        }
        saveState()
    }
    
    // MARK: - Constraints Management
    
    mutating func addNegativeConstraint(_ path: String) {
        currentConstraints.insert(path)
        currentState.negativeConstraints = Array(currentConstraints)
        saveState()
    }
    
    // MARK: - Private Persistence
    
    private func saveState() {
        ContextMemoryManager.shared.updateActiveState(conversationID: conversationID, state: currentState)
    }
}
