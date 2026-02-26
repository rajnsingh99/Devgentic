//
//  ScratchpadTool.swift
//  Devgentic
//
//  Created by Raj Singh on 22/02/26.
//

import Foundation

/// Intrinsic system tool definition for memory hydration.
/// Note: This tool is intercepted natively by the ReActAgentExecutor because it mutates internal cognitive state,
/// rather than being executed as a standard `DevgenticTool`.
struct ScratchpadTool {
    
    // MARK: - Constants
    
    static let name = "scratchpad_tool"
    
    static let description = "Retrieves the full content of past observations using their Step ID. Use this when you see a pointer like [ scratchpad_tool $X ]."
    
    static let schemaString = "{\"step_ids\":{\"items\":{\"type\":\"integer\"},\"type\":\"array\"}}"
    
    // MARK: - Helpers
    
    /// Extracts an array of integer step IDs from the LLM's raw JSON parameters.
    static func extractStepIDs(from parameters: [String: AnyCodable]) -> [Int] {
        if let idsParam = parameters["step_ids"],
           let data = try? JSONEncoder().encode(idsParam),
           let ids = try? JSONDecoder().decode([Int].self, from: data) {
            return ids
        }
        return []
    }
}
