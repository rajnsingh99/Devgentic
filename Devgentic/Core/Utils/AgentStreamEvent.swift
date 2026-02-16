//
//  AgentStreamEvent.swift
//  Devgentic
//
//  Created by Raj Singh on [Date].
//

import Foundation

/// Represents the distinct types of events emitted during an Agent's execution loop.
/// This structured stream allows the UI to render "Thinking", "Artifacts", and "Text" separately.
enum AgentStreamEvent: Sendable {
    
    /// The agent is reasoning. Use this to update a "Thinking..." UI component.
    /// Example: "Internal Monologue: Checking file system permissions..."
    case thought(String)
    
    /// The agent is about to execute a tool.
    /// - name: The tool name (e.g., "list_directory")
    /// - params: The raw JSON parameters being passed (for debugging/visibility)
    case toolCall(name: String, params: String)
    
    /// The tool has finished. Use this to render "Glass Box" artifacts (tables, lists, JSON).
    /// This is the "Observation" phase.
    case toolOutput(ToolOutput)
    
    /// A chunk of the final text response (streaming token).
    /// This is what populates the main chat bubble.
    case content(String)
    
    /// A non-fatal warning or error message to display in the trace/debug log.
    case error(String)
}

/// Structured output from a tool execution.
/// Used to render "Artifacts" in the UI (e.g., a file list card).
///
/// Updates:
/// - Added `Codable` to support persistence in `ChatMessage`.
/// - Added `Equatable` to support `==` comparison in `ChatMessage`.
struct ToolOutput: Sendable, Identifiable, Codable, Equatable {
    let id: UUID
    let toolName: String
    let output: String
    let isSuccess: Bool
    
    init(id: UUID = UUID(), toolName: String, output: String, isSuccess: Bool) {
        self.id = id
        self.toolName = toolName
        self.output = output
        self.isSuccess = isSuccess
    }
}
