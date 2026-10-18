// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolSchemaAdapterProtocol.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Handles Structural Volatility by formatting tools for either System Prompt injection or Native API payloads.
protocol ToolSchemaAdapter: Sendable {
    /// Formats tools for injection into the System Prompt (typically for legacy or local models).
    func formatForSystemPrompt(_ tools: [AgentTool]) -> String

    /// Formats tools as native API payloads (typically for modern cloud models).
    func formatForNativeAPI(_ tools: [AgentTool]) -> [[String: Any]]?
}
