//
//  ToolStore.swift
//  Devgentic
//
//  Created by Raj Singh on 19/06/25.
//

import SwiftUI
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ToolStore")

/// Manages the available tool configurations (providers) for the application by fetching them from Core Data.
class ToolStore: ObservableObject {
    @Published var providers: [ToolConfigModel] = []
    
    private let persistenceService: CoreDataServiceProtocol

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        // Since API calls will populate this, we will call loadProviders
        // whenever the data is expected to change. For now, init is a good place.
        loadProviders()
    }

    /// Fetches tool configurations from Core Data and updates the published `providers` array.
    func loadProviders() {
        let configEntities = persistenceService.fetchToolConfigs()
        
        DispatchQueue.main.async {
            self.providers = configEntities.map { $0.toToolConfigModel() }
            logger.info("Successfully loaded \(self.providers.count) tool providers from Core Data.")
        }
    }

    // This static function can be kept for creating mock data for previews or future testing.
    static func createMockData() -> [ToolConfigModel] {
        return [
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
            )
        ]
    }
}
