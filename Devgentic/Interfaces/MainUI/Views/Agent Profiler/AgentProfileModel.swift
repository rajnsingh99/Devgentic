// AgentProfileModel.swift

import SwiftUI

// NOTE: ProvidedTool and ToolConfigModel structs remain the same.

struct ProvidedTool: Codable, Identifiable, Hashable {
    let id: String
    var description: String
}

struct ToolConfigModel: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var toolType: ToolType
    var provider: String
    var sourceURL: String?
    var description: String?
    var availableTools: [ProvidedTool]
    
    enum ToolType: String, Codable, Hashable {
        case mcp
        case custom
    }
}

struct SelectedTool: Codable, Identifiable, Hashable {
    var id: String
    var providerID: UUID
    var displayName: String
}

struct AgentProfileModel: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var baseURL: String
    // --- MODIFIED: This property is now linked to the unified integration model ---
    var linkedIntegrationID: UUID?
    var tools: [SelectedTool]

    static func defaultAgent() -> AgentProfileModel {
        AgentProfileModel(
            id: UUID(),
            name: "DevAgent",
            role: "Your personal development assistant.",
            baseURL: "http://localhost:8000",
            // --- MODIFIED: Changed property name ---
            linkedIntegrationID: nil,
            tools: []
        )
    }
}
