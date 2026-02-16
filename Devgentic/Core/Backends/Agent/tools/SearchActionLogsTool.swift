//
//  SearchActionLogsTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

/// A tool that allows the Agent to search the Master Index (CSV) for past actions.
struct SearchActionLogsTool: OpenFoundationModels.Tool {
    
    // MARK: - Type Definitions
    
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let keyword: String
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            
            guard let kwValue = properties["keyword"] else {
                throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("keyword")
            }
            
            self.keyword = try String(kwValue)
        }
    }
    
    typealias Output = String
    
    // MARK: - Properties
    
    let name = "search_action_logs"
    let description = "Searches the 'Evidence Locker' (audit logs) for past actions containing the keyword. Use this to find out what you did previously."
    
    // MARK: - Schema
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        let kwSchema = OpenFoundationModelsCore.DynamicGenerationSchema(
            type: String.self
        )
        
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                    name: "keyword",
                    description: "The keyword to search for (e.g., 'moved', 'desktop', 'Budget.pdf').",
                    schema: kwSchema,
                    isOptional: false
                )
            ]
        )
        
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("Failed to construct GenerationSchema for SearchActionLogsTool: \(error)")
        }
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        return LogManager.shared.searchLogs(keyword: arguments.keyword)
    }
}
