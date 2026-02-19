//
//  ReadSessionHistoryTool.swift
//  Devgentic
//
//  Created by Raj Singh on 12/02/26.
//  MIGRATION: Updated to native DevgenticTool protocol & Standardized Description.
//

import Foundation

struct ReadSessionHistoryTool: DevgenticTool {
    let name = "read_session_history"
    let description = """
    [PURPOSE]: Reads the chronological log of all goals, actions, and outcomes performed in the CURRENT session.
    [WHEN TO USE]: Use to answer questions like 'What did I do first?' or to review the exact sequence of your previous actions.
    [INPUT]: {}
    [OUTPUT]: A linear text timeline of session events.
    """
    
    let conversationID: UUID
    
    init(conversationID: UUID) {
        self.conversationID = conversationID
    }
    
    // MARK: - Arguments Definition
    
    struct Arguments: Decodable, Sendable {
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            // ROBUST PARSING: Even for empty arguments, we should validate the content structure.
            _ = try decoder.container(keyedBy: DynamicKey.self)
        }
    }
    
    // MARK: - Schema Definition
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
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
