//
//  AgentProfileModel.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI


struct AgentProfileModel: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var role: String
    var baseURL: String
    var linkedIntegrationID: UUID?
    var tools: [SelectedTool]

    static func defaultAgent() -> AgentProfileModel {
        AgentProfileModel(
            id: UUID(),
            name: "DevAgent",
            role: "Your personal development assistant.",
            baseURL: "http://localhost:8000",
            linkedIntegrationID: nil,
            tools: []
        )
    }
}

struct SelectedTool: Codable, Identifiable, Hashable {
    var id: String { toolName }
    let toolName: String
    let displayName: String
}
