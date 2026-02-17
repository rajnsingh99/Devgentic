//
//  MutableActiveState.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - Sub-Task Definition

/// Represents a granular step in the execution plan.
/// The Agent must update these statuses as it progresses.
@Generable
struct SubTask: Sendable, Codable {
    
    @Guide(description: "Unique numeric identifier for the step (1, 2, 3...).")
    let id: Int
    
    @Guide(description: "A concise description of the task (e.g. 'Locate the Q3 Report').")
    let description: String
    
    @Guide(description: "Current status. STRICT VALUES: 'pending', 'active', 'completed', 'failed', 'skipped'.")
    let status: String
    
    @Guide(description: "How many times this specific step has been attempted. Increment this on failure.")
    let retryCount: Int
    
    // MARK: - Manual Initializer & Codable Support
    
    private enum CodingKeys: String, CodingKey {
        case id, description, status, retryCount
    }
    
    // Manual Init: Required because @Generable suppresses default init, and we must init _rawGeneratedContent
    init(id: Int, description: String, status: String, retryCount: Int) {
        self.id = id
        self.description = description
        self.status = status
        self.retryCount = retryCount
        // Initialize the macro property with an empty placeholder
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }
    
    // Custom Decodable: Required to ignore _rawGeneratedContent during JSON decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.description = try container.decode(String.self, forKey: .description)
        self.status = try container.decode(String.self, forKey: .status)
        self.retryCount = try container.decode(Int.self, forKey: .retryCount)
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }
    
    // Custom Encodable: Required to exclude _rawGeneratedContent from JSON
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
@Generable
struct MutableActiveState: Sendable, Codable {
    
    @Guide(description: "The ID of the session. Do not change this.")
    let sessionID: String
    
    @Guide(description: "The high-level user objective (e.g. 'Organize the Desktop and summarize PDFs').")
    let primaryGoal: String
    
    @Guide(description: "The list of granular steps required to achieve the primary goal.")
    let subTasks: [SubTask]
    
    @Guide(description: "A list of paths or actions that have FAILED and must NOT be retried (e.g. '/System/Library/Private').")
    let negativeConstraints: [String]
    
    @Guide(description: "Key-Value pairs of confirmed facts gathered during execution (e.g. 'user_name': 'Raj', 'target_file': '/tmp/doc.pdf').")
    let workingMemory: [String: String]
    
    // MARK: - Manual Initializer & Codable Support
    
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
        // Initialize the macro property with an empty placeholder
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.primaryGoal = try container.decode(String.self, forKey: .primaryGoal)
        self.subTasks = try container.decode([SubTask].self, forKey: .subTasks)
        self.negativeConstraints = try container.decode([String].self, forKey: .negativeConstraints)
        self.workingMemory = try container.decode([String: String].self, forKey: .workingMemory)
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
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
@Generable
struct MemoryUpdate: Sendable, Codable {

    @Guide(description: "The status of the current goal. STRICT VALUES: 'ACTIVE', 'COMPLETED', 'FAILED', 'ABANDONED'.")
    let goalStatus: String

    @Guide(description: "A concise 1-sentence summary of what you are currently trying to achieve (e.g. 'Searching for folder X').")
    let goalSummary: String

    @Guide(description: "The markdown log entry to append to the session history. Must include timestamp.")
    let logEntry: String

    // MARK: - Manual Initializer & Codable Support

    private enum CodingKeys: String, CodingKey {
        case goalStatus, goalSummary, logEntry
    }

    // Manual Init: Required because @Generable suppresses default init, and we must init _rawGeneratedContent
    init(goalStatus: String, goalSummary: String, logEntry: String) {
        self.goalStatus = goalStatus
        self.goalSummary = goalSummary
        self.logEntry = logEntry
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Decodable: Required to ignore _rawGeneratedContent during JSON decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.goalStatus = try container.decode(String.self, forKey: .goalStatus)
        self.goalSummary = try container.decode(String.self, forKey: .goalSummary)
        self.logEntry = try container.decode(String.self, forKey: .logEntry)
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Encodable: Required to exclude _rawGeneratedContent from JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(goalStatus, forKey: .goalStatus)
        try container.encode(goalSummary, forKey: .goalSummary)
        try container.encode(logEntry, forKey: .logEntry)
    }
}

// MARK: - Cognitive Definitions (The Executor's Loop)

/// Represents a specific tool execution request within a cognitive step.
@Generable
struct ToolAction: Sendable, Codable {

    @Guide(description: "The exact name of the tool to execute (e.g., 'execute_shell', 'read_file').")
    let toolName: String

    // UPDATED: Now uses AnyCodable for robust Native JSON support
    // The model will generate a real JSON object here, not a string.
    @Guide(description: "The parameters for the tool as a standard JSON object. Example: { \"path\": \"/tmp/file\", \"recursive\": true }")
    let parameters: [String: AnyCodable]

    // MARK: - Manual Initializer & Codable Support

    private enum CodingKeys: String, CodingKey {
        case toolName, parameters
    }

    // Manual Init: Required because @Generable suppresses default init, and we must init _rawGeneratedContent
    init(toolName: String, parameters: [String: AnyCodable]) {
        self.toolName = toolName
        self.parameters = parameters
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Decodable: Required to ignore _rawGeneratedContent during JSON decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.toolName = try container.decode(String.self, forKey: .toolName)
        self.parameters = try container.decode([String: AnyCodable].self, forKey: .parameters)
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Encodable: Required to exclude _rawGeneratedContent from JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(parameters, forKey: .parameters)
    }
}

/// Represents a single cognitive cycle (Think -> Decide -> Act).
/// The Agent MUST generate this structure for every step of the loop.
@Generable
struct CognitiveStep: Sendable, Codable {

    // ARCHITECTURAL FIX: Made Optional for First-Step Safety
    // Gemini Flash often omits this on Step 1, causing decoding errors if Mandatory.
    @Guide(description: "Analyze the previous step. Was it a 'Success' or 'Failure'? Be honest.")
    let previousStepOutcome: String?

    @Guide(description: "Your internal reasoning process...")
    let internalMonologue: String

    @Guide(description: "A short, 3-5 word status headline...")
    let displayHeadline: String

    @Guide(description: "The specific tool you want to execute...")
    let action: ToolAction?

    @Guide(description: "Required when changing state or finishing a task. Structured update for the memory file.")
    let memoryUpdate: MemoryUpdate?

    @Guide(description: "If the task is complete, provide the final response...")
    let finalAnswer: String?

    // MARK: - Manual Initializer & Codable Support

    private enum CodingKeys: String, CodingKey {
        case previousStepOutcome, internalMonologue, displayHeadline, action, memoryUpdate, finalAnswer
    }

    // Manual Init: Required because @Generable suppresses default init, and we must init _rawGeneratedContent
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
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Decodable: Required to ignore _rawGeneratedContent during JSON decoding
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.previousStepOutcome = try container.decodeIfPresent(String.self, forKey: .previousStepOutcome)
        self.internalMonologue = try container.decode(String.self, forKey: .internalMonologue)
        self.displayHeadline = try container.decode(String.self, forKey: .displayHeadline)
        self.action = try container.decodeIfPresent(ToolAction.self, forKey: .action)
        self.memoryUpdate = try container.decodeIfPresent(MemoryUpdate.self, forKey: .memoryUpdate)
        self.finalAnswer = try container.decodeIfPresent(String.self, forKey: .finalAnswer)
        self._rawGeneratedContent = GeneratedContent(kind: .structure(properties: [:], orderedKeys: []))
    }

    // Custom Encodable: Required to exclude _rawGeneratedContent from JSON
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

// We extend AnyCodable to conform to all protocols required by the @Generable macro.
// This allows automatic parsing (decoding), serializing (encoding), and schema generation
// for the AnyCodable type used in the tool parameters.
extension AnyCodable: Generable, ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
    
    // 1. Decoder: GeneratedContent -> AnyCodable
    public init(_ content: GeneratedContent) throws {
        // We leverage the fact that GeneratedContent is Encodable (representing the JSON subtree).
        let encoder = JSONEncoder()
        let data = try encoder.encode(content)
        
        // Decode that JSON data using AnyCodable's robust decoding logic.
        let decoder = JSONDecoder()
        self = try decoder.decode(AnyCodable.self, from: data)
    }
    
    // 2. Encoder: AnyCodable -> GeneratedContent
    public var generatedContent: GeneratedContent {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        
        // Encode self to JSON string, then create GeneratedContent from it.
        // If encoding fails (unlikely for AnyCodable), fallback to empty object.
        guard let data = try? encoder.encode(self),
              let jsonString = String(data: data, encoding: .utf8) else {
            return try! GeneratedContent(json: "{}")
        }
        
        // GeneratedContent(json:) throws, but since we just encoded valid JSON, force try is acceptable here
        // or we could catch and return empty.
        return try! GeneratedContent(json: jsonString)
    }
    
    // 3. Schema: Describes "Any Value" to the LLM
    public static var generationSchema: GenerationSchema {
        // Define a schema that represents a generic JSON value.
        // Since we want to allow any JSON structure (string, number, object, array),
        // we create a broad schema definition.
        let root = DynamicGenerationSchema(
            name: "AnyValue",
            description: "A dynamic JSON value (string, number, boolean, array, or object).",
            properties: [] // No specific properties enforced
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
}

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
