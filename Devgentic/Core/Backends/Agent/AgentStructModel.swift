//
//  AgentStructModel.swift
//  Devgentic
//
//  Created by Raj Singh on 02/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - Plan Definitions (The Architect's Output)

/// Represents a single, atomic unit of work in the agent's plan.
@Generable
struct PlanStep: Sendable, Codable {
    
    @Guide(description: "A unique numeric identifier for this step, starting at 1.")
    let id: Int
    
    @Guide(description: "A clear, executable goal for this step. Must be concise (e.g., 'Check system temperature' or 'List files in Downloads').")
    let goal: String
    
    @Guide(description: "The specific tool that should handle this step, if known (e.g., 'fs_smart_search', 'execute_shell'). If unsure, leave null.")
    let suggestedTool: String?
    
    @Guide(description: "Flag potential risks such as 'Requires SIP', 'Deletes files', 'Network usage', or 'Privacy access'. If safe, leave null.")
    let potentialRisk: String?
    
    @Guide(description: "Set to TRUE if the user's request is vague, ambiguous, or could be interpreted in multiple ways for this specific step.")
    let isAmbiguous: Bool
    
    @Guide(description: "If 'isAmbiguous' is true, provide a specific question to ask the user to clarify their intent (e.g., 'Do you mean the CPU temperature or the GPU temperature?').")
    let clarificationQuestion: String?
}

/// The Master Plan returned by the Manager Agent.
@Generable
struct ExecutionPlan: Sendable, Codable {
    
    @Guide(description: "A high-level summary of the user's intent based on the analysis.")
    let userIntent: String
    
    @Guide(description: "A distilled summary of RELEVANT facts from the chat history needed for this specific plan. Include file paths, PIDs, previous errors, or user preferences. Exclude irrelevant history.")
    let contextBrief: String
    
    @Guide(description: "The ordered checklist of steps required to fulfill the intent.")
    let steps: [PlanStep]
    
    @Guide(description: "Set to TRUE if ANY step in the plan is marked as 'isAmbiguous' OR if the plan involves high-risk actions (like file deletion) that require explicit user approval.")
    let requiresUserConfirmation: Bool
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
}

/// Represents a single cognitive cycle (Think -> Decide -> Act).
/// The Agent MUST generate this structure for every step of the loop.
@Generable
struct CognitiveStep: Sendable, Codable {
    
    @Guide(description: "Analyze the previous step. Was it a 'Success' or 'Failure'? Be honest.")
    let previousStepOutcome: String
    
    @Guide(description: "Your internal reasoning process...")
    let internalMonologue: String
    
    @Guide(description: "A short, 3-5 word status headline...")
    let displayHeadline: String
    
    @Guide(description: "The specific tool you want to execute...")
    let action: ToolAction?
    
    @Guide(description: "If you have made progress or completed the task, provide the MARKDOWN content to update the Session Context (Project Brief). REQUIRED when providing a 'finalAnswer'.")
    let memoryUpdate: String?
    
    @Guide(description: "If the task is complete, provide the final response...")
    let finalAnswer: String?
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
