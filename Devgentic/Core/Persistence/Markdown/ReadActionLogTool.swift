//
//  ReadActionLogTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

/// A tool that allows the Agent to retrieve the full details (JSON manifest) of a specific past action.
struct ReadActionLogTool: OpenFoundationModels.Tool {
    
    // MARK: - Type Definitions
    
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let actionID: String
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            
            guard let idValue = properties["actionID"] else {
                throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("actionID")
            }
            
            self.actionID = try String(idValue)
        }
    }
    
    typealias Output = String
    
    // MARK: - Properties
    
    let name = "read_action_log"
    let description = "Retrieves the full technical details of a past system action using its ID (e.g., 'ACT-8821'). Returns the JSON manifest."
    
    // MARK: - Schema
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        let idSchema = OpenFoundationModelsCore.DynamicGenerationSchema(
            type: String.self
        )
        
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                    name: "actionID",
                    description: "The unique ID of the action to retrieve (e.g., 'ACT-8821').",
                    schema: idSchema,
                    isOptional: false
                )
            ]
        )
        
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("Failed to construct GenerationSchema for ReadActionLogTool: \(error)")
        }
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        guard let manifest = LogManager.shared.getLogDetails(actionID: arguments.actionID) else {
            return "Error: No log found for ID '\(arguments.actionID)'."
        }
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        if let data = try? encoder.encode(manifest), let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        } else {
            return "Error: Failed to encode log details."
        }
    }
}
