//
//  Agent.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI


struct ProvidedTool: Codable, Identifiable, Hashable {
    
    /// A stable, unique identifier for this tool within its provider.
    /// Should be machine-readable (e.g., "create_github_issue", "web_search").
    let id: String
    
    /// A detailed description of what the tool does, its purpose, and when to use it.
    /// This is critical for the LLM to make correct decisions.
    var description: String
    
    // You can extend this model in the future to include a schema
    // for the tool's input parameters, which would allow the agent
    // to understand how to form its requests.
    // var parameters: [String: Any]?
}

struct ToolConfigModel: Codable, Identifiable, Hashable {
    
    /// A unique identifier for the tool provider.
    let id: UUID
    
    /// The user-friendly name of the provider (e.g., "Web Search Provider", "Code Interpreter").
    var displayName: String
    
    /// The type of the provider, indicating how the backend should interact with it.
    var toolType: ToolType
    
    /// The entity providing the tools (e.g., "Internal", "Azure", "GitHub").
    var provider: String
    
    /// Optional URL for the provider's endpoint, primarily for MCP servers.
    var sourceURL: String?
    
    /// A brief description of the tool provider's overall capabilities.
    var description: String?
    
    /// **[NEW]** The list of actual tools available from this provider.
    var availableTools: [ProvidedTool]
    
    enum ToolType: String, Codable, Hashable {
        case mcp
        case custom
    }
}

struct SelectedTool: Codable, Identifiable, Hashable {
    /// Use the tool's own ID (`ProvidedTool.id`) for identification.
    var id: String
    
    /// The ID of the ToolConfigModel provider this tool belongs to.
    var providerID: UUID
    
    /// The display name of the tool, for easy reference in the UI.
    var displayName: String
}

struct AgentProfileModel: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var isActive: Bool // Whether the agent is currently active/enabled
    var baseURL: String // Agent's base URL
    var linkedOllamaProfileID: UUID? // Optional link to an OllamaProfile
    
    var tools: [SelectedTool]

    static func defaultAgent() -> AgentProfileModel {
        AgentProfileModel(
            id: UUID(),
            name: "DevAgent",
            role: "Your personal development assistant.",
            isActive: true,
            baseURL: "http://localhost:8000",
            linkedOllamaProfileID: nil,
            tools: []
        )
    }
}
