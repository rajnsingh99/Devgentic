//
//  ToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 19/06/25.
//

import SwiftUI

/// Manages the available tool configurations (providers) for the application.
class ToolStore: ObservableObject {
    @Published var providers: [ToolConfigModel]

    init() {
        self.providers = ToolStore.createMockData()
    }

    // Creates mock data for demonstration purposes.
    // In a real application, this data would likely be fetched from a server.
    static func createMockData() -> [ToolConfigModel] {
        return [
            // MCP Provider Example
            ToolConfigModel(
                id: UUID(),
                displayName: "GitHub MCP Server",
                toolType: .mcp,
                provider: "GitHub",
                sourceURL: "http://localhost:3001",
                description: "Provides tools for interacting with GitHub repositories.",
                availableTools: [
                    ProvidedTool(id: "gh_list_issues", description: "Lists all open issues in a given repository."),
                    ProvidedTool(id: "gh_create_issue", description: "Creates a new issue in a repository with a title and body."),
                    ProvidedTool(id: "gh_get_repo_details", description: "Fetches details about a specific repository.")
                ]
            ),
            // Custom Tool Provider Example
            ToolConfigModel(
                id: UUID(),
                displayName: "Web Search",
                toolType: .custom,
                provider: "Internal",
                sourceURL: nil,
                description: "A custom tool for searching the web.",
                availableTools: [
                    ProvidedTool(id: "internal_web_search", description: "Performs a web search with a given query and returns the results.")
                ]
            ),
            // Another Custom Tool
            ToolConfigModel(
                id: UUID(),
                displayName: "Code Interpreter",
                toolType: .custom,
                provider: "Internal",
                description: "A sandboxed environment to execute code.",
                availableTools: [
                    ProvidedTool(id: "internal_code_interpreter", description: "Executes a given Python code snippet in a secure sandbox.")
                ]
            )
        ]
    }
}
