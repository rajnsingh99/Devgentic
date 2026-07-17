//
//  EpisodicHistoryFormatter.swift
//  Devgentic
//
//  Converts UI chat history (ChatMessage[]) into cognitive state for the agent loop.
//
//  Two outputs:
//  1. SessionGraph — ephemeral state object with episodes, negative constraints, and working memory.
//     Built fresh per agent invocation from ChatMessage history (never persisted).
//
//  2. XML episodic memory string — injected as a user-tier message in the LLM prompt.
//     Encodes 4 signals per turn:
//       • recency    — "N turns ago" attribute for temporal weighting
//       • outcome    — truncated agent response (200 chars) so follow-ups have referent context
//       • errors     — <error> on failed/denied tool actions
//       • corrections — <user_correction> when user denied a tool
//
//  XML schema:
//    <episodic_memory>
//      <recent>
//        <turn status="completed|failed|cancelled" goal="..." recency="1 turn ago">
//          <outcome>Truncated agent response</outcome>
//          <termination>Reason for forced termination (e.g. circuit-breaker abort)</termination>
//          <action tool="tool_name" status="success|failed|denied">
//            <params key="value" .../>
//            <error>Error reason (150 char max)</error>
//          </action>
//          <user_correction>User denied: tool_name</user_correction>
//        </turn>
//      </recent>
//    </episodic_memory>
//
//  Status authority: when `ChatMessage.terminalOutcome` is set (modern rows), it
//  overrides action-derived turn status. This catches the case where every tool
//  call technically succeeded but the executor force-terminated the run via
//  circuit breaker or iteration exhaustion. Without the override, those turns
//  appear as `status="completed"` in the next turn's prompt, falsely teaching
//  the model that the looping pattern was acceptable.
//
//  Ghost Protocol: Failed tool names are collected in SessionGraph.negativeConstraints
//  and injected into the system prompt to prevent retry within the session.
//

import Foundation

/// Converts UI chat history into cognitive SessionGraph state and XML episodic memory
/// for LLM prompt injection. See file header for schema and signal documentation.
struct EpisodicHistoryFormatter {

    // MARK: - XML Escape Helper

    /// Escapes special characters for safe use in XML attribute values and text content.
    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Truncates a string to a maximum length, appending "..." if truncated.
    private static func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength - 3)) + "..."
    }

    // MARK: - Params Parsing

    /// Parses a serialized JSON params string into a flat [String: String] dictionary.
    /// Nested values are serialized back to compact JSON strings.
    private static func parseParams(_ jsonString: String) -> [String: String] {
        guard !jsonString.isEmpty,
              let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var result: [String: String] = [:]
        for (key, value) in obj {
            switch value {
            case let str as String:
                result[key] = truncate(str, maxLength: 200)
            case let num as NSNumber:
                result[key] = "\(num)"
            case is NSNull:
                continue
            default:
                // Arrays/objects: serialize to compact JSON
                if let nested = try? JSONSerialization.data(withJSONObject: value),
                   let str = String(data: nested, encoding: .utf8) {
                    result[key] = truncate(str, maxLength: 200)
                }
            }
        }
        return result
    }

    // MARK: - Tool Action Classification

    /// Structured classification of a single tool execution, derived from
    /// `ToolExecutionData.failureCategory` (modern) with a conservative fallback
    /// for legacy persisted data that pre-dates the category field. Shared
    /// between `buildGraph` (SessionGraph) and `pairTurns` (XML emitters) so
    /// both paths classify the same tool failure identically — no more string
    /// matching on output text in one path and structured enums in the other.
    private struct ActionClassification {
        let status: ActionStatus
        let errorReason: String?
        let userCorrection: String?
        let producesHardConstraint: Bool
    }

    private static func classify(_ data: ToolExecutionData) -> ActionClassification {
        let success = data.isSuccess ?? false
        if success {
            return ActionClassification(
                status: .success,
                errorReason: nil,
                userCorrection: nil,
                producesHardConstraint: false
            )
        }

        let truncatedOutput = data.output.map { truncate($0, maxLength: 150) }

        if let category = data.failureCategory {
            return ActionClassification(
                status: category.actionStatus,
                errorReason: truncatedOutput,
                userCorrection: category == .userDenied ? "User denied: \(data.name)" : nil,
                producesHardConstraint: category.producesHardConstraint
            )
        }

        // Legacy persisted data without a category — conservative fallback:
        // treat as a generic failure, record detail, but do NOT ban the tool.
        return ActionClassification(
            status: .failed,
            errorReason: truncatedOutput,
            userCorrection: nil,
            producesHardConstraint: false
        )
    }

    // MARK: - Turn Status Authority

    /// Returns an authoritative turn status when `terminalOutcome` provides one.
    /// `.failed` and `.cancelled` override action-derived status (those cases lose
    /// signal otherwise — e.g. a circuit-breaker abort where every tool call
    /// technically succeeded). `.completed` returns nil so action-level logic can
    /// still classify partial successes correctly. Nil terminal outcome (legacy
    /// rows) also returns nil and the caller falls back to action-level derivation.
    private static func authoritativeStatus(from terminalOutcome: ExecutionOutcome?) -> String? {
        guard let outcome = terminalOutcome else { return nil }
        switch outcome {
        case .failed:    return "failed"
        // Degraded success — the run stopped early but shipped a best-effort answer.
        // "partial" tells the model the prior turn's answer may be incomplete without
        // overstating it as a failure.
        case .completedWithWarnings: return "partial"
        case .cancelled: return "cancelled"
        case .completed: return nil
        }
    }

    /// Maps an executor `ExecutionOutcome` to the typed `EpisodeLifecycle` used by
    /// `MemoryEpisode.status`. Returns `.completed` for legacy rows (nil terminal
    /// outcome) so the SessionGraph rebuild stays backward-compatible with
    /// messages persisted before terminal outcomes were tracked. Non-nil outcomes
    /// pass through `EpisodeLifecycle(_:)` for a 1:1 typed mapping.
    private static func episodeStatus(from terminalOutcome: ExecutionOutcome?) -> EpisodeLifecycle {
        guard let outcome = terminalOutcome else { return .completed }
        return EpisodeLifecycle(outcome)
    }

    /// Renders a `<termination>` XML element when the turn was force-terminated
    /// with a reason. Returns nil for `.completed` outcomes, missing outcomes, or
    /// missing reasons. The reason is truncated and XML-escaped for safe inclusion.
    private static func renderTerminationElement(
        terminalOutcome: ExecutionOutcome?,
        terminalReason: String?,
        indent: String
    ) -> String? {
        guard let outcome = terminalOutcome,
              let reason = terminalReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        switch outcome {
        // Degraded runs carry their early-stop reason too — it's the context the model
        // needs to understand why the prior answer may be incomplete.
        case .failed, .cancelled, .completedWithWarnings:
            return "\(indent)<termination>\(xmlEscape(truncate(reason, maxLength: 200)))</termination>\n"
        case .completed:
            return nil
        }
    }

    // MARK: - Build Graph (with enriched actions)

    // MARK: - Checkpoint Extraction

    /// Extracts the latest checkpoint and filters history to only include messages after it.
    /// Returns the checkpoint summary (if any) and the filtered history.
    private static func extractCheckpointContext(from history: [ChatMessage]) -> (summary: String?, filteredHistory: [ChatMessage]) {
        // Find the latest checkpoint message
        guard let checkpoint = history.last(where: {
            if case .checkpoint = $0.content { return true }
            return false
        }), case .checkpoint(let summary) = checkpoint.content else {
            return (nil, history)
        }

        // Filter to only include messages after the checkpoint
        let filtered = history.filter { $0.timestamp > checkpoint.timestamp }
        return (summary, filtered)
    }

    /// Wraps XML episodic memory output with an optional `<compacted_context>` preamble.
    private static func wrapWithCheckpoint(summary: String?, turnCount: Int, innerXML: String) -> String {
        guard let summary = summary else { return innerXML }

        let preamble = "  <compacted_context checkpoint_turns=\"\(turnCount)\">\n    \(xmlEscape(summary))\n  </compacted_context>\n"

        // Robust insertion: find <episodic_memory> tag regardless of trailing whitespace.
        // Try exact match first, then fall back to flexible search.
        if let insertionPoint = innerXML.range(of: "<episodic_memory>\n") {
            var modified = innerXML
            modified.insert(contentsOf: preamble, at: insertionPoint.upperBound)
            return modified
        } else if let tagRange = innerXML.range(of: "<episodic_memory>") {
            // Flexible: insert after the tag with a newline
            var modified = innerXML
            modified.insert(contentsOf: "\n" + preamble, at: tagRange.upperBound)
            return modified
        }

        // Last resort: wrap the entire output
        return "<episodic_memory>\n\(preamble)\(innerXML)\n</episodic_memory>"
    }

    /// Builds an ephemeral SessionGraph from chat history.
    ///
    /// Pairs user↔agent messages into `MemoryEpisode`s, extracts tool executions with
    /// parsed params and error reasons, and collects failed tool names into `negativeConstraints`
    /// (Ghost Protocol). The graph is never persisted — ChatMessage[] is the source of truth.
    ///
    /// - Parameters:
    ///   - history: The sanitized array of previous ChatMessages (excluding the current pending query).
    ///   - sessionID: The current conversation UUID string.
    /// - Returns: A fully assembled, ephemeral SessionGraph.
    static func buildGraph(from history: [ChatMessage], sessionID: String) -> SessionGraph {
        var episodes: [MemoryEpisode] = []
        var negativeConstraints: Set<String> = []

        // Filter out checkpoint messages — they are synthetic summaries, not real turns.
        // Also apply checkpoint context: only process turns after the latest checkpoint.
        let (_, filteredHistory) = extractCheckpointContext(from: history)
        let effectiveMessages = filteredHistory.filter {
            if case .checkpoint = $0.content { return false }
            return true
        }

        var pendingUserText: String? = nil

        for message in effectiveMessages {
            let text = message.content.textContent ?? ""

            if message.sender == .user {
                pendingUserText = text

            } else if message.sender == .agent {

                var actions: [MemoryAction] = []
                var usedTools: [String] = []
                var userCorrection: String? = nil

                // Extract tool executions from timeline events.
                // Ghost Protocol: `data.failureCategory` drives constraint policy directly —
                // no more string-matching on output text. Only hard-failure categories
                // (userDenied / permissionRejected / notFound) add the tool name to
                // `negativeConstraints`; soft failures (timeout / executionThrew / invalidArgs / cancelled)
                // are recorded in the episode for retrieval but do not ban the tool outright.
                for event in message.flattenedTimelineEvents {
                    if case .toolExecution(let data) = event, !data.isExecuting {

                        usedTools.append(data.name)
                        let classification = classify(data)

                        if classification.producesHardConstraint {
                            negativeConstraints.insert(data.name)
                        }
                        if let correction = classification.userCorrection {
                            userCorrection = correction
                        }

                        let action = MemoryAction(
                            id: data.id,
                            toolName: data.name,
                            intent: data.name,
                            status: classification.status,
                            params: parseParams(data.params),
                            errorReason: classification.errorReason
                        )
                        actions.append(action)
                    }
                }

                // Build episode from user-agent pair
                if let userText = pendingUserText {
                    let truncatedUser = userText.count > 50 ? String(userText.prefix(47)) + "..." : userText
                    let summary: String

                    if usedTools.isEmpty {
                        summary = "User query: '\(truncatedUser)' -> Agent provided a direct response."
                    } else {
                        let uniqueTools = Array(Set(usedTools)).joined(separator: ", ")
                        summary = "User query: '\(truncatedUser)' -> Agent executed tools: [\(uniqueTools)]."
                    }

                    // Episode status now reflects the executor's terminal outcome instead
                    // of being hardcoded to COMPLETED. Legacy rows without a recorded
                    // terminalOutcome still resolve to COMPLETED via the helper.
                    let episode = MemoryEpisode(
                        id: message.id,
                        primaryGoal: userText,
                        status: Self.episodeStatus(from: message.terminalOutcome),
                        finalOutcome: text.isEmpty ? "(Agent returned visual output/tool result)" : text,
                        summary: summary,
                        actions: actions,
                        userCorrection: userCorrection
                    )

                    episodes.append(episode)
                    pendingUserText = nil
                }
            }
        }

        return SessionGraph(
            sessionID: sessionID,
            episodes: episodes,
            negativeConstraints: Array(negativeConstraints),
            workingMemory: [:]
        )
    }

    // MARK: - XML Episodic Memory Builder

    /// Builds an XML episodic memory string for LLM prompt injection.
    ///
    /// Each turn encodes 4 signals: recency, outcome, tool errors, and user corrections.
    /// Tool actions include full parameter recipes so the LLM can replicate or avoid them.
    ///
    /// - Parameters:
    ///   - history: The array of previous ChatMessages.
    ///   - limit: The maximum number of recent turn-pairs to include (default 4).
    /// - Returns: An XML `<episodic_memory>` block ready for prompt injection.
    static func buildRecentHistoryString(from history: [ChatMessage], limit: Int = 4) -> String {
        // Extract checkpoint context — if a checkpoint exists, only format turns after it.
        let (checkpointSummary, filteredHistory) = extractCheckpointContext(from: history)
        let originalTurnCount = pairTurns(from: history).count

        // Pair user-agent messages into logical turns (from filtered history)
        let turns = pairTurns(from: filteredHistory)

        if turns.isEmpty {
            let emptyXML = "<episodic_memory>\n  <recent/>\n</episodic_memory>"
            let compactedTurnCount = checkpointSummary != nil ? originalTurnCount : 0
            return wrapWithCheckpoint(summary: checkpointSummary, turnCount: compactedTurnCount, innerXML: emptyXML)
        }

        let recentTurns = turns.suffix(limit)
        let totalTurns = turns.count

        var xml = "<episodic_memory>\n  <recent>\n"

        for (index, turn) in recentTurns.enumerated() {
            let absoluteIndex = totalTurns - recentTurns.count + index
            let turnsAgo = totalTurns - absoluteIndex
            let recencyLabel = turnsAgo == 1 ? "1 turn ago" : "\(turnsAgo) turns ago"

            let goal = xmlEscape(truncate(turn.userQuery, maxLength: 80))
            // Authoritative status (from executor) overrides action-derived classification.
            // Catches circuit-breaker aborts and iteration exhaustion where every tool
            // technically succeeded — those would otherwise read as "completed".
            let turnStatus: String
            if let authoritative = Self.authoritativeStatus(from: turn.terminalOutcome) {
                turnStatus = authoritative
            } else if turn.wasCancelled {
                turnStatus = "cancelled"
            } else if turn.actions.contains(where: { $0.status.isFailure }) {
                turnStatus = "failed"
            } else {
                turnStatus = "completed"
            }

            xml += "    <turn status=\"\(turnStatus)\" goal=\"\(goal)\" recency=\"\(recencyLabel)\">\n"

            // Agent response context — present on every turn so follow-ups
            // like "delete the first one" can resolve referents.
            if let outcome = turn.outcome {
                xml += "      <outcome>\(xmlEscape(outcome))</outcome>\n"
            }

            // Termination element — explicit reason for non-completed terminal outcomes
            // (circuit-breaker abort, iteration exhaustion, cancellation). Renders only
            // when the executor recorded both an outcome and a reason; legacy rows skip.
            if let termination = Self.renderTerminationElement(
                terminalOutcome: turn.terminalOutcome,
                terminalReason: turn.terminalReason,
                indent: "      "
            ) {
                xml += termination
            }

            for action in turn.actions {
                // `xmlValue` covers all 9 ActionStatus cases (success, denied,
                // permission_denied, failed, timeout, invalid_args, not_found,
                // cancelled, active). The previous switch only covered SUCCESS/DENIED
                // and silently collapsed everything else into "failed", losing
                // signal for timeouts, permission rejections, and not-found tools.
                xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(action.status.xmlValue)\">\n"

                // Params as XML attributes
                if !action.params.isEmpty {
                    let paramAttrs = action.params
                        .sorted(by: { $0.key < $1.key })
                        .map { "\($0.key)=\"\(xmlEscape($0.value))\"" }
                        .joined(separator: " ")
                    xml += "        <params \(paramAttrs)/>\n"
                }

                // Error reason for failed/denied actions
                if let error = action.errorReason {
                    xml += "        <error>\(xmlEscape(error))</error>\n"
                }

                xml += "      </action>\n"
            }

            // User correction signal
            if let correction = turn.userCorrection {
                xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
            }

            xml += "    </turn>\n"
        }

        xml += "  </recent>\n</episodic_memory>"

        // Wrap with checkpoint preamble if a compacted context exists.
        let compactedTurnCount = checkpointSummary != nil ? (originalTurnCount - turns.count) : 0
        return wrapWithCheckpoint(summary: checkpointSummary, turnCount: compactedTurnCount, innerXML: xml)
    }

    // MARK: - Pointer History (Skeleton + Tool)

    /// Builds an XML episodic memory string where every turn is a skeleton.
    /// Outcomes point to `get_conversation_history(INDEX)` for on-demand retrieval.
    /// Actions include tool name and status only — no params (save tokens).
    static func buildPointerHistoryString(from history: [ChatMessage]) -> String {
        let (_, filteredHistory) = extractCheckpointContext(from: history)
        let turns = pairTurns(from: filteredHistory)
        guard !turns.isEmpty else { return "" }

        var xml = "<episodic_memory>\n  <recent>\n"
        let totalTurns = turns.count

        for (index, turn) in turns.enumerated() {
            let turnsAgo = totalTurns - index
            let recency = turnsAgo == 1 ? "1 turn ago" : "\(turnsAgo) turns ago"
            // Same authority cascade as buildRecentHistoryString — terminalOutcome
            // takes precedence; fall back to action-derived classification for legacy rows.
            let status: String
            if let authoritative = Self.authoritativeStatus(from: turn.terminalOutcome) {
                status = authoritative
            } else if turn.wasCancelled {
                status = "cancelled"
            } else if turn.actions.contains(where: { $0.status.isFailure }) {
                status = "failed"
            } else {
                status = "completed"
            }
            let goal = xmlEscape(truncate(turn.userQuery, maxLength: 80))

            xml += "    <turn status=\"\(status)\" goal=\"\(goal)\" recency=\"\(recency)\">\n"
            xml += "      <outcome>Call get_conversation_history(\(index)) for details.</outcome>\n"

            if let termination = Self.renderTerminationElement(
                terminalOutcome: turn.terminalOutcome,
                terminalReason: turn.terminalReason,
                indent: "      "
            ) {
                xml += termination
            }

            // Skeleton actions — tool name + status only, no params
            for action in turn.actions {
                let toolStatus = action.status.xmlValue
                xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\"/>\n"

                // Always preserve error signals
                if let error = action.errorReason {
                    // Rewrite the action as non-self-closing to include error
                    xml.removeLast("      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\"/>\n".count)
                    xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\">\n"
                    xml += "        <error>\(xmlEscape(error))</error>\n"
                    xml += "      </action>\n"
                }
            }

            if let correction = turn.userCorrection {
                xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
            }

            xml += "    </turn>\n"
        }

        xml += "  </recent>\n</episodic_memory>"
        return xml
    }

    // MARK: - Hybrid History (Recent Full + Older Pointers)

    /// Builds an XML episodic memory string with a split strategy:
    /// - Older turns: pointer skeletons (same as `buildPointerHistoryString`)
    /// - Recent turns (last `inlineCount`): full content with outcomes, params, errors
    ///
    /// - Parameters:
    ///   - history: The array of ChatMessages.
    ///   - inlineCount: Number of most recent turns to render with full content (default 3).
    static func buildHybridHistoryString(from history: [ChatMessage], inlineCount: Int = 3) -> String {
        // Extract checkpoint context — if a checkpoint exists, only format turns after it.
        let (checkpointSummary, filteredHistory) = extractCheckpointContext(from: history)
        let originalTurnCount = pairTurns(from: history).count

        let turns = pairTurns(from: filteredHistory)
        guard !turns.isEmpty else { return "" }

        let totalTurns = turns.count
        let pointerCount = max(0, totalTurns - inlineCount)

        var xml = "<episodic_memory>\n  <recent>\n"

        for (index, turn) in turns.enumerated() {
            let turnsAgo = totalTurns - index
            let recency = turnsAgo == 1 ? "1 turn ago" : "\(turnsAgo) turns ago"
            let isPointer = index < pointerCount
            // Same authority cascade as the other emitters.
            let status: String
            if let authoritative = Self.authoritativeStatus(from: turn.terminalOutcome) {
                status = authoritative
            } else if turn.wasCancelled {
                status = "cancelled"
            } else if turn.actions.contains(where: { $0.status.isFailure }) {
                status = "failed"
            } else {
                status = "completed"
            }
            let goal = xmlEscape(truncate(turn.userQuery, maxLength: 80))

            xml += "    <turn status=\"\(status)\" goal=\"\(goal)\" recency=\"\(recency)\">\n"

            if isPointer {
                // Pointer skeleton — outcome points to tool, actions have no params
                xml += "      <outcome>Call get_conversation_history(\(index)) for details.</outcome>\n"

                if let termination = Self.renderTerminationElement(
                    terminalOutcome: turn.terminalOutcome,
                    terminalReason: turn.terminalReason,
                    indent: "      "
                ) {
                    xml += termination
                }

                for action in turn.actions {
                    let toolStatus = action.status.xmlValue
                    if let error = action.errorReason {
                        xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\">\n"
                        xml += "        <error>\(xmlEscape(error))</error>\n"
                        xml += "      </action>\n"
                    } else {
                        xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\"/>\n"
                    }
                }
            } else {
                // Full inline — same format as buildRecentHistoryString
                if let outcome = turn.outcome {
                    xml += "      <outcome>\(xmlEscape(outcome))</outcome>\n"
                }

                if let termination = Self.renderTerminationElement(
                    terminalOutcome: turn.terminalOutcome,
                    terminalReason: turn.terminalReason,
                    indent: "      "
                ) {
                    xml += termination
                }

                for action in turn.actions {
                    let toolStatus = action.status.xmlValue
                    let paramsAttrs = action.params.map { " \($0.key)=\"\(xmlEscape($0.value))\"" }.joined()
                    xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(toolStatus)\">\n"

                    if !action.params.isEmpty {
                        xml += "        <params\(paramsAttrs)/>\n"
                    }
                    if let error = action.errorReason {
                        xml += "        <error>\(xmlEscape(error))</error>\n"
                    }
                    xml += "      </action>\n"
                }
            }

            if let correction = turn.userCorrection {
                xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
            }

            xml += "    </turn>\n"
        }

        xml += "  </recent>\n</episodic_memory>"

        // Wrap with checkpoint preamble if a compacted context exists.
        let compactedTurnCount = checkpointSummary != nil ? (originalTurnCount - turns.count) : 0
        return wrapWithCheckpoint(summary: checkpointSummary, turnCount: compactedTurnCount, innerXML: xml)
    }

    // MARK: - Turn Pairing

    /// A paired user↔agent turn representing one complete interaction cycle.
    /// Internal visibility to allow shared use by ConversationHistoryTool for index stability.
    internal struct TurnPair {
        let userQuery: String
        let actions: [MemoryAction]
        let userCorrection: String?
        /// Truncated agent response (max 200 chars). Always present — for cancelled turns,
        /// synthesized from completed/failed tool names to preserve follow-up referents.
        let outcome: String?
        /// True when the user stopped the agent mid-execution before a response was generated.
        let wasCancelled: Bool
        /// Authoritative terminal outcome from the executor's `.executionFinished` event.
        /// Nil for legacy rows persisted before terminal outcomes were tracked — callers
        /// fall back to action-derived status in that case.
        let terminalOutcome: ExecutionOutcome?
        /// Human-readable reason accompanying a non-completed terminal outcome.
        /// Surfaced as `<termination>` in the XML so the model sees explicit context
        /// for circuit-breaker aborts and iteration exhaustion.
        let terminalReason: String?
    }

    /// Pairs consecutive user↔agent messages into logical turns.
    /// Internal visibility so ConversationHistoryTool can use the same pairing for index stability.
    static func pairTurns(from history: [ChatMessage]) -> [TurnPair] {
        var turns: [TurnPair] = []
        var pendingUserText: String? = nil

        for message in history {
            if message.sender == .user {
                pendingUserText = message.content.textContent ?? ""

            } else if message.sender == .agent, let userText = pendingUserText {
                var actions: [MemoryAction] = []
                var userCorrection: String? = nil

                for event in message.flattenedTimelineEvents {
                    if case .toolExecution(let data) = event, !data.isExecuting {
                        let classification = classify(data)

                        if let correction = classification.userCorrection {
                            userCorrection = correction
                        }

                        actions.append(MemoryAction(
                            id: data.id,
                            toolName: data.name,
                            intent: data.name,
                            status: classification.status,
                            params: parseParams(data.params),
                            errorReason: classification.errorReason
                        ))
                    }
                }

                // Always capture the agent's response as outcome so the model knows
                // what it told the user — not just which tools ran. Without this,
                // follow-up references like "delete the first one" have no referent
                // because the agent can't see what files it previously listed.
                let responseText = message.content.textContent ?? ""

                // Detect cancellation: the executor emits this placeholder when
                // the user stops execution mid-session. Modern rows also have
                // `terminalOutcome == .cancelled`; we OR the two signals so a row
                // missing one but having the other is still classified correctly.
                let cancellationPlaceholders = [
                    "*Operation stopped by user.*",
                    "*Operation was stopped before a response could be generated.*"
                ]
                let wasCancelled = cancellationPlaceholders.contains(where: { responseText.contains($0) })
                    || message.terminalOutcome == .cancelled

                let outcome: String?
                if wasCancelled || responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Cancelled or empty — synthesize outcome from completed tool actions
                    // so the next turn has factual context about what was done before termination.
                    if !actions.isEmpty {
                        let completedTools = actions.filter { $0.status == .success }.map(\.toolName)
                        let failedTools = actions.filter { $0.status != .success }.map(\.toolName)
                        var parts: [String] = []
                        if !completedTools.isEmpty { parts.append("Completed: " + completedTools.joined(separator: ", ")) }
                        if !failedTools.isEmpty { parts.append("Failed: " + failedTools.joined(separator: ", ")) }
                        outcome = parts.isEmpty ? "(Terminated by user before any tools ran)" : parts.joined(separator: ". ") + ". (Terminated by user)"
                    } else {
                        outcome = "(Terminated by user before any tools ran)"
                    }
                } else {
                    outcome = truncate(responseText, maxLength: 200)
                }

                turns.append(TurnPair(
                    userQuery: userText,
                    actions: actions,
                    userCorrection: userCorrection,
                    outcome: outcome,
                    wasCancelled: wasCancelled,
                    terminalOutcome: message.terminalOutcome,
                    terminalReason: message.terminalReason
                ))
                pendingUserText = nil
            }
        }

        // Orphaned user message — asked but never got a response
        if let userText = pendingUserText {
            turns.append(TurnPair(
                userQuery: userText,
                actions: [],
                userCorrection: nil,
                outcome: "No agent response",
                wasCancelled: true,
                terminalOutcome: .cancelled,
                terminalReason: "Agent never responded to this query"
            ))
        }

        return turns
    }
}
