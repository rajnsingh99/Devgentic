//
//  ReadActionLogTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  MIGRATION: Updated to native DevgenticTool protocol & Standardized Description.
//

import Foundation

/// A tool that allows the Agent to retrieve the full details (JSON manifest) of a specific past action.
struct ReadActionLogTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name = "read_action_log"
    let description = "Retrieves the full technical details (JSON manifest) of a past system action using its ID."
    
    // MARK: - Type Definitions
    
    struct Arguments: Decodable, Sendable {
        let actionID: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundID: String? = nil
            let keys = ["actionID", "actionId", "action_id", "id", "logID"]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundID = val
                    break
                }
            }
            
            guard let validID = foundID else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'actionID'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.actionID = validID
        }
    }
    
    // MARK: - Schema
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("actionID", "string", "The unique ID of the action to retrieve (e.g., 'ACT-8821').")
            ],
            required: ["actionID"]
        )
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
