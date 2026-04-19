//
//  ToolUsageSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

/// Extracts tool effectiveness patterns from conversation tool execution data.
///
/// Analyzes: tool frequency, success/failure rates, denied tools,
/// and tool combination patterns.
/// Produces fragments for: `.toolEffectiveness`
final class ToolUsageSource: UserPersonalSource, @unchecked Sendable {

    let id = "tool_usage"
    let displayName = "Tool Usage Patterns"
    var isEnabled: Bool { true }

    private let logger = DGLogger(category: "ToolUsageSource")

    func gather(from conversations: [UserPersonalConversationData]) async -> [ProfileFragment] {
        let allExecutions = conversations.flatMap(\.toolExecutions)
        guard !allExecutions.isEmpty else {
            logger.debug("[ToolUsageSource] No tool executions found.")
            return []
        }

        var observations: [String] = []

        // --- Tool Frequency ---
        var toolCounts: [String: Int] = [:]
        var toolSuccesses: [String: Int] = [:]
        var toolFailures: [String: Int] = [:]
        var toolDenials: [String: Int] = [:]

        for exec in allExecutions {
            toolCounts[exec.toolName, default: 0] += 1
            if exec.isDenied {
                toolDenials[exec.toolName, default: 0] += 1
            } else if exec.isSuccess {
                toolSuccesses[exec.toolName, default: 0] += 1
            } else {
                toolFailures[exec.toolName, default: 0] += 1
            }
        }

        // Top used tools
        let topTools = toolCounts.sorted { $0.value > $1.value }.prefix(5)
        if !topTools.isEmpty {
            let toolList = topTools.map { "\($0.key) (\($0.value)x)" }.joined(separator: ", ")
            observations.append("- Most used tools: \(toolList)")
        }

        // Success rates for tools used more than once
        let frequentTools = toolCounts.filter { $0.value >= 2 }
        for (tool, count) in frequentTools.sorted(by: { $0.value > $1.value }).prefix(3) {
            let successes = toolSuccesses[tool, default: 0]
            let rate = Int(Double(successes) / Double(count) * 100)
            if rate < 70 {
                observations.append("- \(tool) has a lower success rate (\(rate)%) — may need attention")
            } else if rate == 100 {
                observations.append("- \(tool) works reliably (100% success rate across \(count) uses)")
            }
        }

        // Denied tools
        let deniedTools = toolDenials.filter { $0.value >= 1 }
        if !deniedTools.isEmpty {
            let deniedList = deniedTools.sorted { $0.value > $1.value }
                .map { "\($0.key) (\($0.value)x denied)" }
                .joined(separator: ", ")
            observations.append("- User has denied these tools: \(deniedList)")
        }

        // Tools that always fail
        let alwaysFailing = toolCounts.filter { tool, count in
            count >= 2 && (toolSuccesses[tool, default: 0] == 0)
        }
        if !alwaysFailing.isEmpty {
            let failList = alwaysFailing.keys.joined(separator: ", ")
            observations.append("- Consistently failing tools: \(failList)")
        }

        // Overall tool usage intensity
        let avgToolsPerConversation = allExecutions.count / max(conversations.count, 1)
        if avgToolsPerConversation >= 5 {
            observations.append("- Heavy tool user (~\(avgToolsPerConversation) tool calls per conversation)")
        } else if avgToolsPerConversation >= 2 {
            observations.append("- Moderate tool usage (~\(avgToolsPerConversation) tool calls per conversation)")
        } else {
            observations.append("- Light tool usage — primarily conversational interactions")
        }

        guard !observations.isEmpty else { return [] }

        logger.debug("[ToolUsageSource] Produced observations from \(allExecutions.count) executions across \(conversations.count) conversations.")

        return [ProfileFragment(
            sourceID: id,
            section: .toolEffectiveness,
            observations: observations.joined(separator: "\n"),
            conversationCount: conversations.count
        )]
    }
}
