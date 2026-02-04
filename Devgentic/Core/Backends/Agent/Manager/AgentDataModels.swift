//
//  AgentDataModels.swift
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
    
    @Guide(description: "The parameters required by the tool, represented as a valid JSON string (e.g., '{\"path\": \"/tmp\", \"recursive\": true}').")
    let parameters: String
}

/// Represents a single cognitive cycle (Think -> Decide -> Act).
/// The Agent MUST generate this structure for every step of the loop.
@Generable
struct CognitiveStep: Sendable, Codable {
    
    @Guide(description: "Your internal reasoning process. Analyze the situation, previous observations, and decide what to do next. Be detailed but concise. This replaces 'Thought:'.")
    let internalMonologue: String
    
    @Guide(description: "A short, 3-5 word status headline for the user UI (e.g., 'Scanning database...', 'Calculating metrics...', 'Reading file metadata...').")
    let displayHeadline: String
    
    @Guide(description: "The specific tool you want to execute. Set to null if you are just thinking or ready to provide the final answer.")
    let action: ToolAction?
    
    @Guide(description: "If the task is complete, provide the final response to the user here. Set to null if you are still working.")
    let finalAnswer: String?
}
