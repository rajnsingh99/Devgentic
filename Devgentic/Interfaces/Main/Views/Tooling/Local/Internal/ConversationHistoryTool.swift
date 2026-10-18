// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationHistoryTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ConversationHistoryTool")

/// Returns a conversation turn by chronological index: the user query, the full agent response and each tool
/// execution. Tool results are not served; a write's effect (file diff) is. Index 0 is the oldest turn, matching
/// the episodic skeleton.
struct ConversationHistoryTool: DevgenticTool {

    // MARK: - Snapshot Record

    /// A Sendable snapshot of a single conversation turn.
    struct TurnRecord: Sendable {
        let index: Int
        let userQuery: String
        let agentResponse: String
        let toolExecutions: String
    }

    /// Ceiling for the agent response in one retrieval: half of `maxPersistedOutputLength`.
    /// The response prints before the tool rows, so an unbounded answer would push the effect diffs past the output cap.
    static let maxResponseChars = ToolExecutionData.maxPersistedOutputLength / 2

    let turnRecords: [TurnRecord]
    /// `conv:… trace:…`, matching `NativeHistoryConverter` and `[EPISODIC]`, so a retrieval
    /// can be lined up with the prompt whose skeleton pointed at it.
    let correlation: String

    var name: String { "get_conversation_history" }

    /// Never surfaced in the Tool Library: injected by `AgentConnect` with the run's own chat history, so it cannot be
    /// built from a registry.
    var category: String { "Internal" }

    var description: String {
        "Retrieves a specific conversation turn by index. Use when the history skeleton says 'Call get_conversation_history(N) for details.', when an <effect> is marked diff=\"on_demand\" and you need the actual change, or when you need more of an earlier answer than the 200-character <outcome> in your history shows. Returns the user query, your COMPLETE earlier response, every tool execution with its arguments and status, and the diff of each file that was modified — call this before offering to undo or revise an earlier edit you cannot see. Tool RESULTS are not stored; re-run the tool with the arguments shown if you need its output again."
    }

    // MARK: - Arguments

    struct Arguments: Decodable, Sendable {
        let index: Int

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            self.index = try container.decode(Int.self, forKey: DynamicKey(stringValue: "index")!)
        }
    }

    // MARK: - Schema

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("index", "integer", "The turn index (0 = oldest). Use the index shown in the history skeleton.")
            ],
            required: ["index"]
        )
    }

    // MARK: - Initialization

    /// Captures a read-only snapshot of the conversation history at construction time.
    /// Indexes the turns after the latest checkpoint (`EpisodicHistoryFormatter.retrievableTurns`), so N matches the
    /// skeleton's label.
    init(chatHistory: [ChatMessage], correlation: String = "") {
        self.correlation = correlation
        // The same turns the skeleton numbered (post-checkpoint, unreadable rows skipped), via the one shared definition.
        let pairs = EpisodicHistoryFormatter.retrievableTurns(from: chatHistory)
        self.turnRecords = pairs.enumerated().map { (index, pair) in
            // The diff budget for one response: stopping at a diff boundary and counting omissions beats the outer cap cutting
            // mid-hunk.
            var diffBudget = ActionEffect.diffCharacterLimit * 2
            var omittedDiffs: [String] = []

            let toolLines = pair.actions.map { action -> String in
                let status = action.status
                let params = action.params.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                let paramsStr = params.isEmpty ? "" : "(\(params))"
                let errorStr = action.errorReason.map { " — \($0)" } ?? ""
                var line = "  - \(action.toolName)\(paramsStr) → \(status)\(errorStr)"

                // Serves the diff that the skeleton's `<effect diff="on_demand"/>` points to, costing context once on request.
                if let effect = action.effect {
                    line += "\n    changed \(effect.fileName) +\(effect.linesAdded) −\(effect.linesRemoved)"
                    if let diff = effect.diff {
                        if diff.count <= diffBudget {
                            diffBudget -= diff.count
                            line += "\n\(diff)"
                            if effect.isTruncated { line += "\n    (diff truncated at capture)" }
                        } else {
                            omittedDiffs.append(effect.fileName)
                            line += "\n    (diff omitted — this turn's changes exceed one response)"
                        }
                    } else {
                        line += "\n    (no pre-write snapshot — the change itself was never captured)"
                    }
                }
                return line
            }.joined(separator: "\n")

            if !omittedDiffs.isEmpty {
                logger.info("[HISTORY_TOOL] \(correlation) Turn \(index): omitted \(omittedDiffs.count) diff(s) over the \(ActionEffect.diffCharacterLimit * 2)-char per-response budget (\(omittedDiffs.joined(separator: ", "))) — the model sees their counts and the omission note, not the change; ask for a narrower turn or read the file.")
            }

            // The untruncated response, not the 200-char outcome the prompt already carries.
            var response = pair.fullResponse
            if response.count > ConversationHistoryTool.maxResponseChars {
                let dropped = response.count - ConversationHistoryTool.maxResponseChars
                logger.info("[HISTORY_TOOL] \(correlation) Turn \(index): agent response clipped at \(ConversationHistoryTool.maxResponseChars) chars (\(dropped) dropped) so the tool rows and their diffs survive this response's own 32 KB ceiling — the model sees the head plus a marker, not a mid-sentence cut.")
                response = String(response.prefix(ConversationHistoryTool.maxResponseChars))
                    + "\n… [truncated \(dropped) characters of the agent's response]"
            }

            return TurnRecord(
                index: index,
                userQuery: pair.userQuery,
                agentResponse: response.isEmpty ? "(No response recorded)" : response,
                toolExecutions: toolLines.isEmpty ? "  (No tools used)" : toolLines
            )
        }
        let count = turnRecords.count
        let withEffects = turnRecords.filter { $0.toolExecutions.contains("changed ") }.count
        logger.info("[HISTORY_TOOL] \(correlation) Captured \(count) turn record(s), \(withEffects) carrying file changes — these are what the pointer skeleton's get_conversation_history(N) indices resolve against.")
    }

    // MARK: - Execution

    func call(arguments: Arguments) async throws -> String {
        let idx = arguments.index

        guard idx >= 0, idx < turnRecords.count else {
            // An out-of-range index means the skeleton and this snapshot disagree, a drift signal, so it is logged.
            logger.warning("[HISTORY_TOOL] \(correlation) Rejected get_conversation_history(\(idx)) — out of range for \(turnRecords.count) captured turn(s). The model asked for a turn the skeleton advertised but this snapshot does not hold, so it gets no detail for it; check for index drift between pairTurns at render and at tool construction.")
            return "Error: Index \(idx) is out of range. Valid range: 0–\(turnRecords.count - 1) (\(turnRecords.count) turns available)."
        }

        let record = turnRecords[idx]

        return """
        [Turn \(idx)]
        User: \(record.userQuery)
        Agent: \(record.agentResponse)
        Tools:
        \(record.toolExecutions)
        """
    }
}
