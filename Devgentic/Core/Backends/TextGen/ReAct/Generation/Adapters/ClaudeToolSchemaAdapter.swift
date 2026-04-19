//
//  ClaudeToolSchemaAdapter.swift
//  Devgentic
//
//  Created by Raj Singh on 27/02/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ClaudeAdapter")

/// Adapter for Anthropic's Claude models.
/// Translates internal AgentTool representations into the exact tool array
/// expected by the official Anthropic Messages API.
struct ClaudeToolSchemaAdapter: ToolSchemaAdapter {
    
    /// Formats tools for system prompt injection.
    /// Used as a fallback if the generator requires a text-based tool list.
    func formatForSystemPrompt(_ tools: [AgentTool]) -> String {
        if tools.isEmpty { return "No tools available." }
        return tools.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n")
    }
    
    /// Formats tools as native API payloads specifically for the Anthropic API schema.
    func formatForNativeAPI(_ tools: [AgentTool]) -> [[String: Any]]? {
        guard !tools.isEmpty else { return nil }
        
        var nativeTools: [[String: Any]] = []
        
        for tool in tools {
            var toolDict: [String: Any] = [
                "name": tool.name,
                "description": tool.description
            ]
            
            // Map the parameter schema to Claude's 'input_schema' key
            if let data = try? JSONEncoder().encode(tool.parameters),
               let paramsDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                toolDict["input_schema"] = paramsDict
            } else {
                // Safe fallback for tools with no explicitly mapped parameters
                toolDict["input_schema"] = [
                    "type": "object",
                    "properties": [String: Any]()
                ]
            }
            
            // Note: Unlike OpenAI, Claude does NOT wrap the tool in a {"type": "function", "function": {...}} block.
            nativeTools.append(toolDict)
        }
        
        return nativeTools
    }
}
