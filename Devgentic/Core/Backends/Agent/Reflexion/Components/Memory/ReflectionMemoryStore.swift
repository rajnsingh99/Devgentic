//
//  ReflectionMemoryStore.swift
//  Devgentic
//
//  Created for Reflexion Architecture.
//  Manages per-trial volatile observations and cross-trial reflections.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReflectionMemory")

/// Concrete implementation of `ReflectionMemoryManaging`.
/// Manages two layers of memory:
/// 1. Active observations (volatile, cleared between trials)
/// 2. Reflections (persistent across trials, accumulated as learning)
struct ReflectionMemoryStore: ReflectionMemoryManaging {

    private(set) var activeObservations: [CognitiveObservation] = []
    private(set) var reflections: [String] = []
    private var observationIdCounter = 1

    // MARK: - Observation Management

    mutating func addObservation(toolName: String, shortObservation: String, heavyContent: String?, isRequired: Bool) {
        let observation = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: toolName,
            shortObservation: shortObservation,
            heavyContent: heavyContent,
            isRequired: isRequired
        )
        activeObservations.append(observation)
        observationIdCounter += 1
    }

    mutating func addSystemAlert(_ msg: String, currentIteration: Int) {
        let alert = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: "system",
            shortObservation: "System Alert (Iter \(currentIteration)): \(msg)",
            heavyContent: nil,
            isRequired: true
        )
        activeObservations.append(alert)
        let currentId = observationIdCounter
        logState.debug("REFLEXION SCRATCHPAD ADD: [\(currentId)] system alert: \(msg)")
        observationIdCounter += 1
    }

    // MARK: - Eviction

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
            logState.debug("REFLEXION SCRATCHPAD EVICTION: Evicted \(evictedCount) observations.")
        }
    }

    // MARK: - Reflection Management

    mutating func addReflection(_ reflection: String) {
        reflections.append(reflection)
        let count = reflections.count
        logState.info("Reflection #\(count) recorded: \(reflection.prefix(100))")
    }

    // MARK: - Trial Reset

    mutating func clearObservationsForNewTrial() {
        let obsCount = activeObservations.count
        let refCount = reflections.count
        logState.debug("REFLEXION SCRATCHPAD CLEAR: Resetting \(obsCount) observations for new trial. Preserving \(refCount) reflections.")
        activeObservations.removeAll()
        // Note: reflections are preserved across trials
        // Note: observationIdCounter is NOT reset to keep IDs globally unique
    }
}
