// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationHistoryTool.swift
//  Devgentic
//
//  Index-based conversation history retrieval tool for Pointer and Hybrid memory strategies.
//  Returns a conversation turn by chronological index: the user query, the agent's response
//  IN FULL (the prompt only ever carries a 200-char <outcome>), and every tool execution with
//  its arguments, status, error and file diff.
//
//  Tool RESULTS are deliberately not stored or served. A tool call is reproducible from its
//  name and arguments, both of which are here, so carrying results would spend context on
//  something the agent can simply ask for again. The exception is what a write CHANGED, which
//  is not reproducible — that rides `<effect>` and is served here in full.
//
//  The index matches the skeleton shown in episodic memory:
//    <outcome>Call get_conversation_history(N) for details.</outcome>
//
//  Index 0 = oldest turn. Indices are computed from EpisodicHistoryFormatter.pairTurns()
//  to guarantee stability between the skeleton and this tool's snapshot.
//

import Foundation
import os

private let logger = DGLogger(category: "ConversationHistoryTool")

struct ConversationHistoryTool: DevgenticTool {

    // MARK: - Snapshot Record

    /// A Sendable snapshot of a single conversation turn.
    struct TurnRecord: Sendable {
        let index: Int
        let userQuery: String
        let agentResponse: String
        let toolExecutions: String
    }

    /// Ceiling for the agent response in one retrieval — half of `maxPersistedOutputLength`.
    ///
    /// The response prints BEFORE the tool rows, and this tool's whole return value is itself
    /// capped at 32 KB when persisted. Left unbounded, a pathological answer would push the
    /// `<effect>` diffs past that cut — discarding the part that CANNOT be re-derived in order
    /// to keep the part that can. ~16 KB is far beyond any real answer, so in practice this
    /// never fires; when it does it stops cleanly and names the loss.
    static let maxResponseChars = ToolExecutionData.maxPersistedOutputLength / 2

    let turnRecords: [TurnRecord]
    /// `conv:… trace:…`, matching `NativeHistoryConverter` and `[EPISODIC]`, so a retrieval
    /// can be lined up with the prompt whose skeleton pointed at it.
    let correlation: String

    var name: String { "get_conversation_history" }

    /// Never surfaced in the Tool Library — injected by `AgentConnect` with the run's own chat
    /// history, so it cannot be constructed from a registry. Required by `DevgenticTool` since
    /// 2026-07-31, which is how this tool was found at all: its `var name: String { … }` is
    /// computed, so every `let name = "…"` grep over the tool tree had silently skipped it.
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
    /// Indexes exactly the turns the pointer skeletons number — `EpisodicHistoryFormatter.retrievableTurns`,
    /// i.e. the turns after the latest checkpoint — so `get_conversation_history(N)` returns the turn
    /// the skeleton labelled N.
    init(chatHistory: [ChatMessage], correlation: String = "") {
        self.correlation = correlation
        // ⚠️ THE SAME TURNS THE SKELETON NUMBERED — post-checkpoint, unreadable rows skipped — via
        // the one definition. This filtered out checkpoint ROWS and paired everything else, so after
        // a compaction its index 0 was the oldest compacted turn while the skeleton's 0 was the first
        // turn after the checkpoint (CR-11).
        let pairs = EpisodicHistoryFormatter.retrievableTurns(from: chatHistory)
        self.turnRecords = pairs.enumerated().map { (index, pair) in
            // The diff budget for ONE response. Each diff is already capped at
            // `diffCharacterLimit`, and tool output is hard-capped at
            // `maxPersistedOutputLength` (32 KB) — but that outer cap truncates mid-diff with
            // a generic marker. Stopping at a diff boundary and saying how many were omitted
            // is a more useful answer than a wall of text cut off mid-hunk.
            var diffBudget = ActionEffect.diffCharacterLimit * 2
            var omittedDiffs: [String] = []

            let toolLines = pair.actions.map { action -> String in
                let status = action.status
                let params = action.params.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                let paramsStr = params.isEmpty ? "" : "(\(params))"
                let errorStr = action.errorReason.map { " — \($0)" } ?? ""
                var line = "  - \(action.toolName)\(paramsStr) → \(status)\(errorStr)"

                // This is the detail the pointer skeleton promises and could not deliver:
                // its `<effect diff="on_demand"/>` says a file changed and by how much, and
                // names this call for the change itself. Serving it here costs context ONCE,
                // on request, instead of on every subsequent prompt.
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

            // The UNTRUNCATED response. This tool used to hand back `pair.outcome` — the same
            // 200-char clip the prompt already carried — so a `pointer` agent could never
            // recover more than 200 characters of any answer it had given, and the retrieval
            // its own skeleton told it to make returned nothing it did not already have.
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
            // Silent until now. An out-of-range ask means the skeleton the model read and the
            // snapshot this tool captured disagree on indices — a real drift signal (the
            // snapshot is taken at request build, the skeleton is rendered from the same
            // pairing, so they should never diverge) and the model just lost that retrieval.
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
