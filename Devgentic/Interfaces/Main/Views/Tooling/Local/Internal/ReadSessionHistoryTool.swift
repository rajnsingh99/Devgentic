//
//  ReadSessionHistoryTool.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Phase 5 - Hierarchical Memory Migration
//

import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "ReadSessionHistoryTool")

/// A system tool that allows the agent to retrieve the full, uncompressed SessionGraph.
/// Used to recover deep logs from completed episodes that were stripped by Semantic Compression.
struct ReadSessionHistoryTool: DevgenticTool {
    let name = "read_session_history"
    let description = "Retrieves the full, uncompressed hierarchical memory graph of the current session."
    
    let conversationID: UUID
    
    struct Arguments: Codable {
        // No arguments required; implicitly scoped to the active conversation.
    }
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.empty()
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        // --- LOGGING INSTRUMENTATION ---
        let logID = LogManager.shared.logAction(
            toolName: self.name,
            summary: "Recalled uncompressed session history graph",
            operations: [
                ["conversation_id": conversationID.uuidString, "action": "history_retrieval"]
            ]
        )
        // -------------------------------

        // 1. Fetch the raw, uncompressed state from the Twin-Store / Graph Manager
        let uncompressedState = SessionGraphStore.shared.getActiveState(for: conversationID)
        
        // 2. Format as pretty-printed JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(uncompressedState)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                return "System Error: Failed to convert session graph to string. (Audit Ref: \(logID))"
            }
            
            return """
            [SYSTEM: UNCOMPRESSED SESSION GRAPH]
            The following JSON contains the full history of this session, including raw logs for COMPLETED tasks:
            
            ```json
            \(jsonString)
            ```
            
            (Audit Ref: \(logID))
            """
        } catch {
            return "System Error: Failed to encode session history. Error: \(error.localizedDescription) (Audit Ref: \(logID))"
        }
    }
}
