//
//  ReadSessionHistoryTool.swift
//  Devgentic
//
//  Created by Raj Singh on 12/02/26.
//  New Tool: Allows the agent to recall sequential events from the Twin-Store Diary.
//  FIXED: Conformance to ConvertibleFromGeneratedContent and Schema logic.
//  UPGRADE: Added LogManager instrumentation and robust content validation.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

struct ReadSessionHistoryTool: OpenFoundationModels.Tool {
    let name = "read_session_history"
    let description = "Reads the chronological log of all goals, actions, and outcomes performed in the CURRENT session. Use this to answer questions like 'What did I do first?' or 'Review my previous actions'."
    
    let conversationID: UUID
    
    // MARK: - Arguments Definition
    
    struct Arguments: Codable, ConvertibleFromGeneratedContent {
        // No parameters needed for this tool, but we must handle the input container
        init(_ content: GeneratedContent) throws {
            // ROBUST PARSING: Even for empty arguments, we should validate the content structure.
            // This prevents framework-level decoding errors (GeneratedContentError 5).
            _ = try content.properties()
        }
    }
    
    typealias Output = String
    
    init(conversationID: UUID) {
        self.conversationID = conversationID
    }
    
    // MARK: - Schema Definition
    
    var parameters: GenerationSchema {
        let root = DynamicGenerationSchema(
            name: "Arguments",
            description: "No arguments required.",
            properties: [] // Empty properties list as this tool is context-dependent
        )
        return try! GenerationSchema(root: root, dependencies: [])
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        // Consistent with NativeSystemTools.swift pattern
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Recalled session history timeline",
            operations: [
                ["conversation_id": conversationID.uuidString, "action": "history_retrieval"]
            ]
        )
        // -------------------------------

        // Fetch the full linear history from the Disk Store
        let history = ContextMemoryManager.shared.getFullHistory(for: conversationID)
        
        if history.isEmpty {
            return "Session history is empty. (Audit Ref: \(logID))"
        }
        
        // Return the structured log for the Agent's observation
        return """
        [SYSTEM: SESSION HISTORY LOG]
        The following is the linear timeline of events for this session.
        Use this to understand the exact sequence of actions and goals.
        
        \(history)
        
        (Audit Ref: \(logID))
        """
    }
}
