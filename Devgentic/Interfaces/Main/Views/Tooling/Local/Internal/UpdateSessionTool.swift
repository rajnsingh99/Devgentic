//
//  UpdateSessionTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  MIGRATION: Updated for Phase 5 Hierarchical Memory
//

import Foundation

/// A tool that allows the Agent to update the persistent "Project Brief" (Session Context)
/// for the current conversation.
struct UpdateSessionTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name = "update_session_context"
    let description = "Updates the persistent 'Project Brief' (markdown) for the current session."
    let conversationID: UUID
    
    // MARK: - Initialization
    
    init(conversationID: UUID) {
        self.conversationID = conversationID
    }
    
    // MARK: - Type Definitions
    
    struct Arguments: Decodable, Sendable {
        let content: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundContent: String? = nil
            let keys = ["content", "text", "body", "data", "markdown", "summary"]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundContent = val
                    break
                }
            }
            
            guard let validContent = foundContent else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'content'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.content = validContent
        }
    }
    
    // MARK: - Schema
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("content", "string", "The full markdown content to write to the session context. This overwrites the existing file, so ensure you include previous relevant info if needed.")
            ],
            required: ["content"]
        )
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        // 1. Fetch the hierarchical session graph
        var state = SessionGraphStore.shared.getActiveState(for: conversationID)
        
        // 2. Store the project brief directly into the working memory dictionary
        state.workingMemory["project_brief"] = arguments.content
        
        // 3. Persist the mutated graph back to storage
        SessionGraphStore.shared.updateActiveState(conversationID: conversationID, state: state)
        
        return "Successfully updated the session context (Project Brief) in your active working memory."
    }
}
