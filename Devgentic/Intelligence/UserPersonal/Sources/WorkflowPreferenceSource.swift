// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowPreferenceSource.swift
//  Devgentic
//
//  Created by Devgentic Architect
//

import Foundation
import os

/// Extracts workflow patterns and preference signals from conversation metadata.
///
/// Analyzes: conversation depth distribution, task type patterns,
/// time-of-day usage, and app preferences.
/// Produces fragments for: `.workflowPatterns`, `.preferences`
final class WorkflowPreferenceSource: UserPersonalSource, @unchecked Sendable {

    let id = "workflow_preferences"
    let displayName = "Workflow Preferences"
    var isEnabled: Bool { true }

    private let logger = DGLogger(category: "WorkflowPreferenceSource")

    func gather(from conversations: [UserPersonalConversationData]) async -> [ProfileFragment] {
        guard !conversations.isEmpty else { return [] }

        var fragments: [ProfileFragment] = []

        // --- Workflow Patterns ---
        let workflowObs = analyzeWorkflowPatterns(conversations)
        if !workflowObs.isEmpty {
            fragments.append(ProfileFragment(
                sourceID: id,
                section: .workflowPatterns,
                observations: workflowObs,
                conversationCount: conversations.count
            ))
        }

        // --- Preferences ---
        let prefObs = analyzePreferences(conversations)
        if !prefObs.isEmpty {
            fragments.append(ProfileFragment(
                sourceID: id,
                section: .preferences,
                observations: prefObs,
                conversationCount: conversations.count
            ))
        }

        logger.debug("[WorkflowPreferenceSource] Produced \(fragments.count) fragments from \(conversations.count) conversations.")
        return fragments
    }

    // MARK: - Workflow Patterns

    private func analyzeWorkflowPatterns(_ conversations: [UserPersonalConversationData]) -> String {
        var observations: [String] = []

        // Task type detection from conversation content
        let allContent = conversations.map(\.condensedContent).joined(separator: "\n").lowercased()

        var taskTypes: [String] = []
        let taskSignals: [(type: String, signals: [String])] = [
            ("Coding/Development", ["write code", "implement", "create a function", "build a", "refactor", "fix the bug", "add feature"]),
            ("Research/Analysis", ["explain", "how does", "what is", "compare", "analyze", "research", "find out"]),
            ("Writing/Content", ["write a", "draft", "edit this", "rewrite", "summarize", "documentation"]),
            ("Debugging", ["error", "exception", "crash", "not working", "fix", "debug", "issue"]),
            ("DevOps/Deployment", ["deploy", "docker", "kubernetes", "CI/CD", "pipeline", "server", "cloud"]),
            ("Data Processing", ["parse", "convert", "transform", "extract", "csv", "json", "data"]),
        ]

        for task in taskSignals {
            let hits = task.signals.filter { allContent.contains($0.lowercased()) }.count
            if hits >= 2 {
                taskTypes.append(task.type)
            }
        }

        if !taskTypes.isEmpty {
            observations.append("- Common task types: \(taskTypes.joined(separator: ", "))")
        }

        // Time-of-day patterns
        let hours = conversations.map { Calendar.current.component(.hour, from: $0.timestamp) }
        if !hours.isEmpty {
            let avgHour = hours.reduce(0, +) / hours.count
            let morningCount = hours.filter { $0 >= 6 && $0 < 12 }.count
            let afternoonCount = hours.filter { $0 >= 12 && $0 < 18 }.count
            let eveningCount = hours.filter { $0 >= 18 || $0 < 6 }.count

            let total = Double(hours.count)
            if Double(morningCount) / total > 0.5 {
                observations.append("- Most active in the morning (6 AM – 12 PM)")
            } else if Double(afternoonCount) / total > 0.5 {
                observations.append("- Most active in the afternoon (12 PM – 6 PM)")
            } else if Double(eveningCount) / total > 0.5 {
                observations.append("- Most active in the evening/night (6 PM – 6 AM)")
            }
        }

        // Conversation depth distribution
        let messageCounts = conversations.map(\.messageCount)
        let shortConvs = messageCounts.filter { $0 <= 4 }.count
        let mediumConvs = messageCounts.filter { $0 > 4 && $0 <= 12 }.count
        let longConvs = messageCounts.filter { $0 > 12 }.count

        let total = conversations.count
        if total >= 3 {
            if Double(shortConvs) / Double(total) > 0.6 {
                observations.append("- Favors quick, focused conversations (\(shortConvs)/\(total) are short)")
            } else if Double(longConvs) / Double(total) > 0.4 {
                observations.append("- Frequently engages in deep, extended sessions (\(longConvs)/\(total) are long)")
            } else {
                observations.append("- Mix of conversation lengths — adapts depth to the task")
            }
        }

        return observations.joined(separator: "\n")
    }

    // MARK: - Preferences

    private func analyzePreferences(_ conversations: [UserPersonalConversationData]) -> String {
        var observations: [String] = []

        // Streaming preference (from UserDefaults)
        let usesStreaming = UserDefaults.standard.bool(forKey: AppSettings.useStreamingResponseKey)
        observations.append("- Streaming responses: \(usesStreaming ? "enabled" : "disabled")")

        // File attachment patterns
        let conversationsWithTools = conversations.filter { !$0.toolExecutions.isEmpty }
        if !conversationsWithTools.isEmpty {
            let toolRatio = Double(conversationsWithTools.count) / Double(conversations.count)
            if toolRatio > 0.7 {
                observations.append("- Heavily tool-oriented — most conversations involve tool use")
            } else if toolRatio > 0.3 {
                observations.append("- Moderate tool usage — mixes tool-based and conversational workflows")
            } else {
                observations.append("- Primarily conversational — infrequent tool usage")
            }
        }

        return observations.joined(separator: "\n")
    }
}
