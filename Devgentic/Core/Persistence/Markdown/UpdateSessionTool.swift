//
//  UpdateSessionTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

/// A tool that allows the Agent to update the persistent "Project Brief" (Session Context)
/// for the current conversation.
struct UpdateSessionTool: OpenFoundationModels.Tool {
    
    // MARK: - Type Definitions
    
    struct Arguments: Codable, OpenFoundationModelsCore.ConvertibleFromGeneratedContent {
        let content: String
        
        init(_ content: OpenFoundationModelsCore.GeneratedContent) throws {
            let properties = try content.properties()
            
            guard let contentValue = properties["content"] else {
                throw OpenFoundationModelsCore.GeneratedContentError.missingProperty("content")
            }
            
            self.content = try String(contentValue)
        }
    }
    
    typealias Output = String
    
    // MARK: - Properties
    
    let name = "update_session_context"
    let description = "Updates the persistent 'Project Brief' (markdown) for this session. Use this to record completed tasks, goals, or key decisions so you remember them later."
    let conversationID: UUID
    
    // MARK: - Initialization
    
    init(conversationID: UUID) {
        self.conversationID = conversationID
    }
    
    // MARK: - Schema
    
    var parameters: OpenFoundationModelsCore.GenerationSchema {
        let contentSchema = OpenFoundationModelsCore.DynamicGenerationSchema(
            type: String.self
        )
        
        let root = OpenFoundationModelsCore.DynamicGenerationSchema(
            name: "Arguments",
            properties: [
                OpenFoundationModelsCore.DynamicGenerationSchema.Property(
                    name: "content",
                    description: "The full markdown content to write to the session context. This overwrites the existing file, so ensure you include previous relevant info if needed.",
                    schema: contentSchema,
                    isOptional: false
                )
            ]
        )
        
        do {
            return try OpenFoundationModelsCore.GenerationSchema(root: root, dependencies: [])
        } catch {
            fatalError("Failed to construct GenerationSchema for UpdateSessionTool: \(error)")
        }
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        ContextMemoryManager.shared.updateSession(conversationID: conversationID, content: arguments.content)
        return "Successfully updated the session context (Project Brief)."
    }
}
