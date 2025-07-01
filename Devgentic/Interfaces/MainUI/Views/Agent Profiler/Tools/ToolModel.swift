//
//  Tool.swift
//  Devgentic
//
//  Created by Raj Singh on 01/07/25.
//

import Foundation

struct ToolModel: Codable, Identifiable, Hashable {
    var id: String { toolName }

    let displayName: String
    let toolName: String
    let description: String
    let provider: String

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case toolName = "tool_name"
        case description
        case provider
    }
}
