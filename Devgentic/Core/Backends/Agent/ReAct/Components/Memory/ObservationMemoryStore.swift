//
//  ObservationMemoryStore.swift
//  Devgentic
//
//  Created for ReAct Executor Modularization.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "State")

/// A concrete implementation of `ObservationMemoryManaging` using value semantics.
/// Manages the agent's short-term scratchpad and prevents context window overflows.
struct ObservationMemoryStore: ObservationMemoryManaging {
    
    private(set) var activeObservations: [CognitiveObservation] = []
    private var observationIdCounter = 1
    
    // MARK: - Managing Observations
    
    mutating func addSystemAlert(_ msg: String, currentIteration: Int) {
        let alert = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: "system",
            shortObservation: "System Alert (Step \(currentIteration)): \(msg)",
            heavyContent: nil,
            isRequired: true,
            metadata: nil
        )
        activeObservations.append(alert)
        
        // Capture local ID to avoid escaping 'self' in OSLog autoclosure
        let currentId = observationIdCounter
        logState.debug("📝 SCRATCHPAD ADD: [\(currentId)] 'system' alert: \(msg)")
        
        observationIdCounter += 1
    }
    
    mutating func addObservation(toolName: String, shortObservation: String, heavyContent: String?, isRequired: Bool) {
        let observation = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: toolName,
            shortObservation: shortObservation,
            heavyContent: heavyContent,
            isRequired: isRequired,
            metadata: nil
        )
        activeObservations.append(observation)
        observationIdCounter += 1
    }
    
    mutating func addObservations(_ observations: [CognitiveObservation]) {
        for obs in observations {
            let newObs = CognitiveObservation(
                stepId: observationIdCounter,
                toolName: obs.toolName,
                shortObservation: obs.shortObservation,
                heavyContent: obs.heavyContent,
                isRequired: obs.isRequired,
                metadata: obs.metadata
            )
            activeObservations.append(newObs)
            observationIdCounter += 1
        }
    }
    
    // MARK: - Eviction & Hydration
    
    mutating func resetObservationFlags() {
        let latestSuccessIdx = activeObservations.lastIndex(where: {
            $0.toolName != "system" && $0.isRequired
        })

        var evictedCount = 0
        for i in activeObservations.indices {
            if activeObservations[i].isRequired && i != latestSuccessIdx {
                activeObservations[i].isRequired = false
                evictedCount += 1
            }
        }
        if evictedCount > 0 {
            // Safe: evictedCount is a local variable
            logState.debug("🧹 SCRATCHPAD EVICTION: Evicted \(evictedCount) observations. Retained latest successful observation.")
        }
    }
    
    mutating func hydrateObservations(targetIds: [Int], currentIteration: Int) -> (msg: String, hydratedCount: Int) {
        var hydratedCount = 0
        for id in targetIds {
            if let idx = activeObservations.firstIndex(where: { $0.stepId == id }) {
                activeObservations[idx].isRequired = true
                hydratedCount += 1
            }
        }
        
        let msg = "System: Hydrated data for IDs \(targetIds). Review them in the updated SCRATCHPAD above."
        
        let hydrationRecord = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: "scratchpad", // Usually mapped to ScratchpadTool.name
            shortObservation: "Observation (Step \(currentIteration)): \(msg)",
            heavyContent: nil,
            isRequired: true,
            metadata: nil
        )
        
        activeObservations.append(hydrationRecord)
        
        // Safe: hydratedCount is a local variable
        logState.debug("💧 SCRATCHPAD HYDRATION: Restored \(hydratedCount) observations to active context.")
        observationIdCounter += 1
        
        return (msg, hydratedCount)
    }
}
