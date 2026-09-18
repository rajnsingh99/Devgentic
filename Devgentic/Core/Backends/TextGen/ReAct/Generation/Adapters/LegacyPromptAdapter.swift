// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LegacyPromptAdapter.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//

import Foundation
import OSLog

private let logToolExecution = DGLogger(category: "ToolExecution")

struct LegacyPromptAdapter: ToolSchemaAdapter {
    func formatForSystemPrompt(_ tools: [AgentTool]) -> String {
        var context = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        
        for tool in tools {
            let schemaStr = (try? encoder.encode(tool.parameters)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            context += "- **\(tool.name)**: \(tool.description)\n  Schema: \(schemaStr)\n"
        }
        
        logToolExecution.debug("Generated Prompted Tools Payload:\n\(context)")
        return context
    }
    
    func formatForNativeAPI(_ tools: [AgentTool]) -> [[String: Any]]? {
        return nil
    }
}

// MARK: - Legacy Compatibility Mapping
// Preserves compatibility with Phase 2 Generators that still reference the old struct name
typealias PromptedMarkdownAdapter = LegacyPromptAdapter
