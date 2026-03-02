//
//  ConversationHistoryTool.swift
//  Devgentic
//
//  Created for Pointer-Based Memory Architecture Migration.
//

import Foundation

/// A tool that allows the agent to retrieve the full text content of older conversation turns.
/// Used in conjunction with the Pointer-Based Memory Architecture to hydrate archived context.
struct ConversationHistoryTool: DevgenticTool {
    
    /// A lightweight, Sendable representation of a history turn.
    /// This safely decouples the tool from the non-Sendable `ChatMessage` ObservableObject class.
    struct TurnRecord: Sendable {
        let id: UUID
        let content: String
    }
    
    let historyRecords: [TurnRecord]
    
    var name: String { "conversation_history_tool" }
    
    var description: String {
        "Retrieves the full, detailed content of past conversation turns. Use this when you need to read the exact details of an ARCHIVED MEMORY POINTER. Pass the UUID(s) found in the pointer list."
    }
    
    struct Arguments: Decodable, Sendable {
        let uuids: [String]
    }
    
    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("uuids", "array", "An array of UUID strings corresponding to the archived turns you want to retrieve.")
            ],
            required: ["uuids"]
        )
    }
    
    /// Initializes the tool by capturing a safe, read-only snapshot of the chat history.
    init(chatHistory: [ChatMessage]) {
        self.historyRecords = chatHistory.map { message in
            TurnRecord(
                id: message.id,
                content: message.content.textContent ?? "(No text content)"
            )
        }
    }
    
    func call(arguments: Arguments) async throws -> String {
        var results: [String] = []
        
        for uuidString in arguments.uuids {
            guard let targetUUID = UUID(uuidString: uuidString) else {
                results.append("Turn [UUID: \(uuidString)] -> Error: Invalid UUID format.")
                continue
            }
            
            // Look up the historical turn by the UUID provided by the agent
            if let record = historyRecords.first(where: { $0.id == targetUUID }) {
                results.append("Turn [UUID: \(uuidString)]:\n\(record.content)")
            } else {
                results.append("Turn [UUID: \(uuidString)] -> Error: Turn not found in available history.")
            }
        }
        
        if results.isEmpty {
            return "No valid UUIDs provided."
        }
        
        return results.joined(separator: "\n\n-------------------\n\n")
    }
}
