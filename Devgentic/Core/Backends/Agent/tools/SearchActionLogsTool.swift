//
//  SearchActionLogsTool.swift
//  Devgentic
//
//  Created by Raj Singh on 10/02/26.
//  MIGRATION: Updated to native DevgenticTool protocol & Standardized Description.
//

import Foundation

/// A tool that allows the Agent to search the Master Index (CSV) for past actions.
struct SearchActionLogsTool: DevgenticTool {
    
    // MARK: - Properties
    
    let name = "search_action_logs"
    let description = """
    [PURPOSE]: Searches the 'Evidence Locker' (audit logs) for past actions containing a specific keyword.
    [WHEN TO USE]: Use to find out if, when, or how you performed an action previously (e.g. searching for a file you moved).
    [INPUT]: { "keyword": "Budget.pdf" }
    [OUTPUT]: A list of matching past actions with their Reference IDs.
    """
    
    // MARK: - Type Definitions
    
    struct Arguments: Decodable, Sendable {
        let keyword: String
        
        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            
            // ROBUST PARSING: Aliases
            var foundKeyword: String? = nil
            let keys = ["keyword", "query", "term", "search", "search_term"]
            
            for key in keys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundKeyword = val
                    break
                }
            }
            
            guard let validKeyword = foundKeyword else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'keyword'. Checked aliases: \(keys.joined(separator: ", "))"
                    )
                )
            }
            
            self.keyword = validKeyword
        }
    }
    
    // MARK: - Schema
    
    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("keyword", "string", "The keyword to search for (e.g., 'moved', 'desktop', 'Budget.pdf').")
            ],
            required: ["keyword"]
        )
    }
    
    // MARK: - Execution
    
    func call(arguments: Arguments) async throws -> String {
        return LogManager.shared.searchLogs(keyword: arguments.keyword)
    }
}
