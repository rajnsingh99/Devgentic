//
//  Agent.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI

// MARK: - Agent Struct (Updated)
struct AgentProfileModel: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var isActive: Bool // Whether the agent is currently active/enabled
    var baseURL: String // MARK: New: Agent's base URL
    var linkedOllamaProfileID: UUID? // MARK: New: Optional link to an OllamaProfile
    var selectedAgentTool: String // MARK: New: Selected tool (e.g., "None", "Code Interpreter")

    static func defaultAgent() -> AgentProfileModel {
        AgentProfileModel(
            id: UUID(),
            name: "DevAgent",
            description: "Your personal development assistant.",
            isActive: true,
            baseURL: "http://localhost:8000", // Default agent URL
            linkedOllamaProfileID: nil, // No Ollama profile linked by default
            selectedAgentTool: "None" // No tool selected by default
        )
    }
}
