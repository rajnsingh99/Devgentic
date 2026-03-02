//
//  StepObservationStore.swift
//  Devgentic
//
//  Created for Plan & Execute Architecture.
//  Manages per-step volatile observation memory.
//

import Foundation
import OSLog

private let logState = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "StepObservation")

/// Concrete implementation of `StepObservationManaging`.
/// Manages the agent's short-term scratchpad scoped to the currently executing plan step.
/// Observations are cleared between steps to keep the context window focused.
struct StepObservationStore: StepObservationManaging {

    private(set) var activeObservations: [CognitiveObservation] = []
    private var observationIdCounter = 1

    // MARK: - Managing Observations

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

    mutating func addSystemAlert(_ msg: String, stepIndex: Int) {
        let alert = CognitiveObservation(
            stepId: observationIdCounter,
            toolName: "system",
            shortObservation: "System Alert (Plan Step \(stepIndex)): \(msg)",
            heavyContent: nil,
            isRequired: true
        )
        activeObservations.append(alert)
        let currentId = observationIdCounter
        logState.debug("PLAN SCRATCHPAD ADD: [\(currentId)] system alert: \(msg)")
        observationIdCounter += 1
    }

    mutating func clearForNextStep() {
        let count = activeObservations.count
        logState.debug("PLAN SCRATCHPAD CLEAR: Resetting \(count) observations for next step.")
        activeObservations.removeAll()
        // Note: we do NOT reset observationIdCounter to keep IDs globally unique within the session
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
            logState.debug("PLAN SCRATCHPAD EVICTION: Evicted \(evictedCount) observations.")
        }
    }
}
