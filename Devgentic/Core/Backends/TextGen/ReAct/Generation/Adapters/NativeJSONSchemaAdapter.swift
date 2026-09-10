// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  NativeJSONSchemaAdapter.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//

import Foundation
import OSLog

private let logToolExecution = DGLogger(category: "ToolExecution")

/// Adapter for modern models (OpenAI, Anthropic, Llama 3.1+) that support native tool execution payloads.
struct NativeJSONSchemaAdapter: ToolSchemaAdapter {
    func formatForSystemPrompt(_ tools: [AgentTool]) -> String {
        if tools.isEmpty { return "No tools available." }
        return tools.map { "- **\($0.name)**: \($0.description)" }.joined(separator: "\n")
    }
    
    func formatForNativeAPI(_ tools: [AgentTool]) -> [[String: Any]]? {
        guard !tools.isEmpty else { return nil }
        
        var nativeTools: [[String: Any]] = []
        for tool in tools {
            var functionDict: [String: Any] = [
                "name": tool.name,
                "description": tool.description
            ]
            
            if let data = try? JSONEncoder().encode(tool.parameters),
               let paramsDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                functionDict["parameters"] = paramsDict
            } else {
                functionDict["parameters"] = [
                    "type": "object",
                    "properties": [String: Any](),
                    "required": [String]()
                ]
            }
            
            let toolDict: [String: Any] = [
                "type": "function",
                "function": functionDict
            ]
            
            nativeTools.append(toolDict)
        }
        
        return nativeTools
    }
}
