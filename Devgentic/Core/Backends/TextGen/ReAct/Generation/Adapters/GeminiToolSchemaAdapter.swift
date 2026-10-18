// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  GeminiToolSchemaAdapter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "GeminiAdapter")

/// Adapter for Google's Gemini models.
/// Translates internal AgentTool representations into the exact `functionDeclarations`
/// array expected by the official Gemini REST API.
struct GeminiToolSchemaAdapter: ToolSchemaAdapter {
    
    /// Formats tools for system prompt injection.
    /// While the Agent flow primarily relies on the Native API array, this provides a safe fallback
    /// if the CognitiveGenerator ever requests a prompt-based tool list.
    func formatForSystemPrompt(_ tools: [AgentTool]) -> String {
        if tools.isEmpty { return "No tools available." }
        return tools.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n")
    }
    
    /// Formats tools as native API payloads specifically for the Gemini API schema.
    func formatForNativeAPI(_ tools: [AgentTool]) -> [[String: Any]]? {
        guard !tools.isEmpty else { return nil }
        
        var functionDeclarations: [[String: Any]] = []
        
        for tool in tools {
            var functionDict: [String: Any] = [
                "name": tool.name,
                "description": tool.description
            ]
            
            // Map the parameter schema
            if let data = try? JSONEncoder().encode(tool.parameters),
               var paramsDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                
                // CRITICAL: Gemini's REST API requires the 'type' field values to be uppercase
                // e.g., "OBJECT" instead of "object", "STRING" instead of "string".
                paramsDict = uppercaseTypes(in: paramsDict)
                functionDict["parameters"] = paramsDict
            } else {
                // Safe fallback for tools with no explicitly mapped parameters
                functionDict["parameters"] = [
                    "type": "OBJECT",
                    "properties": [String: Any]()
                ]
            }
            
            functionDeclarations.append(functionDict)
        }
        
        // Gemini expects the tools array to be an array of objects,
        // where each object can contain a "functionDeclarations" key.
        return [
            [
                "functionDeclarations": functionDeclarations
            ]
        ]
    }
    
    // MARK: - Private Helpers
    
    /// Recursively traverses a JSON dictionary and converts JSON Schema 'type' values to uppercase.
    /// This prevents 400 Bad Request errors from Google's strict Protobuf REST mapping.
    private func uppercaseTypes(in dictionary: [String: Any]) -> [String: Any] {
        var result = dictionary
        
        for (key, value) in dictionary {
            if key == "type", let typeString = value as? String {
                // Convert type values like "object" -> "OBJECT"
                result[key] = typeString.uppercased()
            } else if let nestedDict = value as? [String: Any] {
                // Recurse into nested objects (e.g., inside "properties")
                result[key] = uppercaseTypes(in: nestedDict)
            } else if let nestedArray = value as? [[String: Any]] {
                // Recurse into arrays of objects
                result[key] = nestedArray.map { uppercaseTypes(in: $0) }
            }
        }
        
        return result
    }
}
