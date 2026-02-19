//
//  MutableActiveState.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation

// MARK: - Sub-Task Definition

/// Represents a granular step in the execution plan.
/// The Agent must update these statuses as it progresses.
struct SubTask: Sendable, Codable {

    let id: Int
    let description: String
    let status: String
    let retryCount: Int

    // MARK: - Codable Support

    private enum CodingKeys: String, CodingKey {
        case id, description, status, retryCount
    }

    init(id: Int, description: String, status: String, retryCount: Int) {
        self.id = id
        self.description = description
        self.status = status
        self.retryCount = retryCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.description = try container.decode(String.self, forKey: .description)
        self.status = try container.decode(String.self, forKey: .status)
        self.retryCount = try container.decode(Int.self, forKey: .retryCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(description, forKey: .description)
        try container.encode(status, forKey: .status)
        try container.encode(retryCount, forKey: .retryCount)
    }
}

// MARK: - Active State Definition

/// The "Mutable Active State" (RAM).
/// This object is injected into EVERY System Prompt.
/// It represents the strictly structured "Now", divorced from the "History".
struct MutableActiveState: Sendable, Codable {

    let sessionID: String
    let primaryGoal: String
    let subTasks: [SubTask]
    let negativeConstraints: [String]
    let workingMemory: [String: String]

    // MARK: - Codable Support

    private enum CodingKeys: String, CodingKey {
        case sessionID, primaryGoal, subTasks, negativeConstraints, workingMemory
    }

    init(
        sessionID: String,
        primaryGoal: String,
        subTasks: [SubTask],
        negativeConstraints: [String],
        workingMemory: [String: String]
    ) {
        self.sessionID = sessionID
        self.primaryGoal = primaryGoal
        self.subTasks = subTasks
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.primaryGoal = try container.decode(String.self, forKey: .primaryGoal)
        self.subTasks = try container.decode([SubTask].self, forKey: .subTasks)
        self.negativeConstraints = try container.decode([String].self, forKey: .negativeConstraints)
        self.workingMemory = try container.decode([String: String].self, forKey: .workingMemory)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(primaryGoal, forKey: .primaryGoal)
        try container.encode(subTasks, forKey: .subTasks)
        try container.encode(negativeConstraints, forKey: .negativeConstraints)
        try container.encode(workingMemory, forKey: .workingMemory)
    }
}

// MARK: - Memory Definitions (Goal-Oriented)

/// Defines the lifecycle state of the current user goal.
/// Used to prevent "Zombie Tasks" by explicitly marking goals as Completed or Abandoned.
struct MemoryUpdate: Sendable, Codable {

    let goalStatus: String
    let goalSummary: String
    let logEntry: String

    // MARK: - Codable Support

    private enum CodingKeys: String, CodingKey {
        case goalStatus, goalSummary, logEntry
    }

    init(goalStatus: String, goalSummary: String, logEntry: String) {
        self.goalStatus = goalStatus
        self.goalSummary = goalSummary
        self.logEntry = logEntry
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.goalStatus = try container.decode(String.self, forKey: .goalStatus)
        self.goalSummary = try container.decode(String.self, forKey: .goalSummary)
        self.logEntry = try container.decode(String.self, forKey: .logEntry)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goalStatus, forKey: .goalStatus)
        try container.encode(goalSummary, forKey: .goalSummary)
        try container.encode(logEntry, forKey: .logEntry)
    }
}

// MARK: - Cognitive Definitions (The Executor's Loop)

/// Represents a specific tool execution request within a cognitive step.
struct ToolAction: Sendable, Codable {

    let toolName: String
    let parameters: [String: AnyCodable]

    // MARK: - Codable Support

    private enum CodingKeys: String, CodingKey {
        case toolName, parameters
    }

    init(toolName: String, parameters: [String: AnyCodable]) {
        self.toolName = toolName
        self.parameters = parameters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.parameters = try container.decode([String: AnyCodable].self, forKey: .parameters)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(parameters, forKey: .parameters)
    }
}

/// Represents a single cognitive cycle (Think -> Decide -> Act).
/// The Agent MUST generate this structure for every step of the loop.
struct CognitiveStep: Sendable, Codable {

    let previousStepOutcome: String?
    let internalMonologue: String
    let displayHeadline: String
    let action: ToolAction?
    let memoryUpdate: MemoryUpdate?
    let finalAnswer: String?

    // MARK: - Codable Support

    private enum CodingKeys: String, CodingKey {
        case previousStepOutcome, internalMonologue, displayHeadline, action, memoryUpdate, finalAnswer
    }

    init(
        previousStepOutcome: String?,
        internalMonologue: String,
        displayHeadline: String,
        action: ToolAction?,
        memoryUpdate: MemoryUpdate?,
        finalAnswer: String?
    ) {
        self.previousStepOutcome = previousStepOutcome
        self.internalMonologue = internalMonologue
        self.displayHeadline = displayHeadline
        self.action = action
        self.memoryUpdate = memoryUpdate
        self.finalAnswer = finalAnswer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.previousStepOutcome = try container.decodeIfPresent(String.self, forKey: .previousStepOutcome)
        self.internalMonologue = try container.decode(String.self, forKey: .internalMonologue)
        self.displayHeadline = try container.decode(String.self, forKey: .displayHeadline)
        self.action = try container.decodeIfPresent(ToolAction.self, forKey: .action)
        self.memoryUpdate = try container.decodeIfPresent(MemoryUpdate.self, forKey: .memoryUpdate)
        self.finalAnswer = try container.decodeIfPresent(String.self, forKey: .finalAnswer)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(previousStepOutcome, forKey: .previousStepOutcome)
        try container.encode(internalMonologue, forKey: .internalMonologue)
        try container.encode(displayHeadline, forKey: .displayHeadline)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(memoryUpdate, forKey: .memoryUpdate)
        try container.encodeIfPresent(finalAnswer, forKey: .finalAnswer)
    }
}

// MARK: - Extensions

extension MutableActiveState {

    /// Returns the active subtask or nil if all are done/pending.
    var currentActiveTask: SubTask? {
        return subTasks.first { $0.status == "active" }
    }

    /// Checks if a path is forbidden.
    func isPathForbidden(_ path: String) -> Bool {
        return negativeConstraints.contains { path.contains($0) }
    }
}
