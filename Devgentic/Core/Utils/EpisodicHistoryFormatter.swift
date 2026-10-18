// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EpisodicHistoryFormatter.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: an unmarked placeholder makes a destructive overwrite of a large file read as a clean create
    /// The `<effect>` element for one action: what it changed on disk, so "undo that" is answerable.
    /// `baseline="none"`: prior content never captured (`removed="0"` is a placeholder). `diff="elided"`:
    /// measured, body dropped for budget. `diff="on_demand"`: left for retrieval by the pointer strategy.
    static func renderEffect(_ effect: ActionEffect, diff availability: EffectDiff = .inline) -> String {
        let hasBody = effect.diff != nil
        let carriesBody = hasBody && availability == .inline
        // `truncated` describes the BODY. With no body there is nothing for "partial" to
        // describe, and it would contradict the availability marker.
        let truncatedAttr = (effect.isTruncated && carriesBody) ? " truncated=\"true\"" : ""
        let baselineAttr = hasBody ? "" : " baseline=\"none\""
        // Nothing to elide or fetch when the diff never existed, so an unmeasured write is
        // never relabelled — it stays `baseline="none"` under every availability.
        let diffAttr = hasBody ? availability.attribute : ""

        let openTag = "        <effect file=\"\(xmlEscape(effect.fileName))\" path=\"\(xmlEscape(effect.path))\" added=\"\(effect.linesAdded)\" removed=\"\(effect.linesRemoved)\"\(truncatedAttr)\(baselineAttr)\(diffAttr)"

        // Self-closing when there is no body — an empty open/close pair is two lines and
        // ~26 wasted characters on every bodyless effect, and pointer turns are all body-less.
        guard carriesBody, let body = effect.diff else { return openTag + "/>\n" }
        return openTag + ">\n\(xmlEscape(body))\n        </effect>\n"
    }

    /// Whether an `<effect>` body is in the prompt and, if not, what the model can do about it. One attribute
    /// with mutually exclusive values, because the cases carry different action implications.
    enum EffectDiff {
        /// The body is rendered inline.
        case inline
        /// Measured, dropped to fit the aggregate budget. NOT retrievable by the model —
        /// the full diff is on the timeline row, which is a user-facing surface.
        case elided
        /// Measured, but not inlined by the pointer strategy; retrievable via the `get_conversation_history(N)` call this
        /// turn's `<outcome>` names.
        case onDemand
        /// Measured, but this profile has no tools: a diff is a revert instrument and a profile that cannot call
        /// `write_file` cannot act on one. Distinct from `elided` (budget) and `on_demand` (promises a retrieval);
        /// counts and path still render.
        case withheld
        // Why: `on_demand` promises a retrievable change; once the file moved that promise is false and the model answers from
        // a stale record and makes no tool calls.
        /// Measured, but the file has changed since the write, so the stored diff does not describe it.
        /// Counts and path still render; only the claim that the stored body matches the file is withdrawn (like `withheld`).
        case stale

        var attribute: String {
            switch self {
            case .inline:   return ""
            case .elided:   return " diff=\"elided\""
            case .onDemand: return " diff=\"on_demand\""
            case .withheld: return " diff=\"withheld\""
            case .stale:    return " diff=\"stale\""
            }
        }
    }

    // Why: injected, not called in `renderEffect`: the check is a `stat` and the formatter runs on every
    // `ContextWindowGauge` recompute; the request builder supplies `.live`, the gauge `.unknown` (no I/O)
    /// Decides whether an effect's file still matches what the write left behind. `.unknown` is also the answer
    /// for an effect with no fingerprint.
    struct EffectStalenessCheck: Sendable {
        let isStale: @Sendable (ActionEffect) -> Bool

        /// Asks the filesystem. For the request path only.
        static let live = EffectStalenessCheck { effect in
            guard let fingerprint = effect.fingerprint else { return false }
            return fingerprint.differsFromDisk(at: effect.path)
        }

        /// Never reports staleness and touches no files. For sizing, and for any caller that
        /// must not do I/O.
        static let unknown = EffectStalenessCheck { _ in false }
    }

    /// Truncates a string to a maximum length, appending "..." if truncated. Fine for a goal, an outcome or a
    /// param, where "there was more" is all the reader needs; errors use `cappedError`.
    private static func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength - 3)) + "..."
    }

    /// Longest tool-failure text carried into memory. Error text is the highest-value prose in the blob: it is
    /// why the agent must do something different, and unlike a successful read it cannot be re-derived by calling
    /// the tool again. A quarter of `ActionEffect.diffCharacterLimit`.
    static let errorCharacterLimit = 1_024

    /// Truncation that states what it dropped, matching `ToolExecutionData.cappedOutput`. The generic `truncate`
    /// appends only "..."; naming the loss lets the model ask for more instead of adapting to a cause it never
    /// saw (real errors are often several frames down).
    static func cappedError(_ text: String) -> String {
        guard text.count > errorCharacterLimit else { return text }
        let dropped = text.count - errorCharacterLimit
        return String(text.prefix(errorCharacterLimit))
            + "… [truncated \(dropped) characters of error output]"
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

    /// Structured classification of a single tool execution, derived from `ToolExecutionData.failureCategory`
    /// with a conservative fallback for persisted data without the category. Shared by `buildGraph` and
    /// `pairTurns` so both classify a failure identically.
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

        let truncatedOutput = data.output.map { cappedError($0) }

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

    /// Returns an authoritative turn status when `terminalOutcome` provides one: `.failed` and `.cancelled`
    /// override action-derived status (e.g. a circuit-breaker abort where every call succeeded). `.completed` and
    /// a nil outcome return nil so the caller derives status from the actions.
    private static func authoritativeStatus(from terminalOutcome: ExecutionOutcome?) -> String? {
        guard let outcome = terminalOutcome else { return nil }
        switch outcome {
        case .failed:    return "failed"
        // Degraded success: the run stopped early but shipped a best-effort answer; "partial" says the answer may be
        // incomplete without overstating it as a failure.
        case .completedWithWarnings: return "partial"
        case .cancelled: return "cancelled"
        // The next turn is told the previous one hit its time limit.
        case .timedOut:  return "timed_out"
        case .completed: return nil
        }
    }

    /// Maps an executor `ExecutionOutcome` to the typed `EpisodeLifecycle` used by `MemoryEpisode.status`.
    /// Returns `.completed` for rows without a terminal outcome; other outcomes map 1:1 through
    /// `EpisodeLifecycle(_:)`.
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
        case .failed, .cancelled, .completedWithWarnings, .timedOut:
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

    /// Builds an ephemeral SessionGraph from chat history; it is never persisted (ChatMessage[] is the source of truth).
    /// Pairs user/agent messages into `MemoryEpisode`s, extracts tool executions, collects failed tool names as constraints.
    /// `history` is the sanitized previous messages, excluding the current pending query.
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

                // Extracts tool executions from timeline events; only hard failures (userDenied / permissionRejected /
                // notFound) add the tool name to `negativeConstraints`, soft ones are only recorded.
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
                            errorReason: classification.errorReason,
                            effect: data.effect,
                            exitCode: data.exitCode
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

                    // Episode status reflects the executor's terminal outcome; rows without a recorded `terminalOutcome` resolve
                    // to COMPLETED via the helper.
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

    // MARK: - Shared Turn Renderers
    // There are exactly two ways to render a turn, inline and pointer; every strategy chooses which to use for
    // which turns, and they live here once so strategies cannot drift apart.

    /// ` exit="N"` for a shell command that returned non-zero, empty otherwise. Surfaces the exit code in later
    /// prompts, since successful tool output is not carried and a failed `swift build` would otherwise look like
    /// a passing one.
    private static func exitAttribute(_ action: MemoryAction) -> String {
        guard let code = action.exitCode, code != 0 else { return "" }
        return " exit=\"\(code)\""
    }

    /// Turn status, resolved through one authority cascade for every strategy.
    /// `terminalOutcome` wins because it catches circuit-breaker aborts and iteration
    /// exhaustion, where every tool technically succeeded but the run did not.
    private static func turnStatus(for turn: TurnPair) -> String {
        if let authoritative = authoritativeStatus(from: turn.terminalOutcome) { return authoritative }
        if turn.wasCancelled { return "cancelled" }
        if turn.actions.contains(where: { $0.status.isFailure }) { return "failed" }
        return "completed"
    }

    private static func recencyLabel(turnsAgo: Int) -> String {
        turnsAgo == 1 ? "1 turn ago" : "\(turnsAgo) turns ago"
    }

    /// The opening `<turn>` tag, identical for both renderers.
    private static func turnOpenTag(_ turn: TurnPair, recency: String) -> String {
        let goal = xmlEscape(truncate(turn.userQuery, maxLength: 80))
        return "    <turn status=\"\(turnStatus(for: turn))\" goal=\"\(goal)\" recency=\"\(recency)\">\n"
    }

    /// Whether this turn's `<outcome>` would only repeat an answer the native turns carry in full.
    static func outcomeIsCarriedNatively(_ turn: TurnPair, _ answersCarriedNatively: Set<UUID>) -> Bool {
        guard turn.outcomeIsResponseClip, let id = turn.agentMessageID else { return false }
        return answersCarriedNatively.contains(id)
    }

    /// A turn rendered in FULL: outcome, params, errors, and what each action changed.
    private static func renderInlineTurn(_ turn: TurnPair, recency: String, includeImageNames: Bool,
                                         elidedActionIDs: Set<UUID> = [],
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown,
                                         answersCarriedNatively: Set<UUID> = []) -> String {
        var xml = turnOpenTag(turn, recency: recency)

        // Image label: names the images the user attached on this turn so the model can map the re-provided image
        // bytes (attached to the current message) to their turn. Vision profiles only.
        if includeImageNames, !turn.attachedImageNames.isEmpty {
            let names = turn.attachedImageNames.map(xmlEscape).joined(separator: ", ")
            xml += "      <attached_images>\(names)</attached_images>\n"
        }

        // Agent response context, present on every turn so follow-ups can resolve referents, except when the same
        // answer already rides in full as a native assistant turn (`answersCarriedNatively`). `goal` stays.
        if let outcome = turn.outcome, !outcomeIsCarriedNatively(turn, answersCarriedNatively) {
            xml += "      <outcome>\(xmlEscape(outcome))</outcome>\n"
        }

        if let termination = renderTerminationElement(
            terminalOutcome: turn.terminalOutcome,
            terminalReason: turn.terminalReason,
            indent: "      "
        ) {
            xml += termination
        }

        for action in turn.actions {
            // `exit` is separate from `status`: `status` is whether the tool ran, `exit` what the command returned
            // (merging them would make a `grep` with no match a tool failure). Only non-zero is emitted.
            xml += "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(action.status.xmlValue)\"\(exitAttribute(action))>\n"

            // Sorted by key: Dictionary order is seeded per process, so an unsorted
            // emit rendered the same conversation differently on every launch.
            if !action.params.isEmpty {
                let paramAttrs = action.params
                    .sorted(by: { $0.key < $1.key })
                    .map { "\($0.key)=\"\(xmlEscape($0.value))\"" }
                    .joined(separator: " ")
                xml += "        <params \(paramAttrs)/>\n"
            }

            if let error = action.errorReason {
                xml += "        <error>\(xmlEscape(error))</error>\n"
            }

            // What the action actually changed, so "undo that" is answerable. An elided action keeps the element and its
            // counts and loses only the diff body; dropping the element would read as "nothing happened".
            if let effect = action.effect {
                // Precedence: `withheld` first (no tools, nothing to retrieve with), then `stale` (the stored body does not describe
                // the file; inlining it would hand the model a revert instrument for a vanished state), and only then the budget.
                let availability: EffectDiff
                if !toolsAvailable { availability = .withheld }
                else if staleness.isStale(effect) { availability = .stale }
                else if elidedActionIDs.contains(action.id) { availability = .elided }
                else { availability = .inline }
                xml += renderEffect(effect, diff: availability)
            }

            xml += "      </action>\n"
        }

        if let correction = turn.userCorrection {
            xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
        }

        xml += "    </turn>\n"
        return xml
    }

    // Why: `toolsAvailable` has no default: a silent one made both call sites promise a fetch to profiles that have no
    // tools to keep it.
    /// A turn rendered as a skeleton: tool names and statuses only, with the outcome pointing at `get_conversation_history`.
    /// Params and effects are omitted by design; errors are the standing exception, as a failure is a durable consequence.
    /// With `toolsAvailable` false, effects are marked `diff=withheld` instead of `on_demand`: counts render, no fetch.
    private static func renderPointerTurn(_ turn: TurnPair, index: Int, recency: String,
                                          toolsAvailable: Bool,
                                          staleness: EffectStalenessCheck) -> String {
        var xml = turnOpenTag(turn, recency: recency)
        // The retrieval instruction is only true when there is a tool to retrieve with; a skeleton that cannot be
        // expanded says so rather than naming a tool.
        xml += toolsAvailable
            ? "      <outcome>Call get_conversation_history(\(index)) for details.</outcome>\n"
            : "      <outcome>Summary only — full detail is not retrievable this turn.</outcome>\n"

        if let termination = renderTerminationElement(
            terminalOutcome: turn.terminalOutcome,
            terminalReason: turn.terminalReason,
            indent: "      "
        ) {
            xml += termination
        }

        for action in turn.actions {
            let open = "      <action tool=\"\(xmlEscape(action.toolName))\" status=\"\(action.status.xmlValue)\"\(exitAttribute(action))"

            var children = ""
            if let error = action.errorReason {
                children += "        <error>\(xmlEscape(error))</error>\n"
            }
            // A file mutation is a durable consequence, like an error. Counts only (~90 chars): enough to know something
            // changed; the body comes from `get_conversation_history(N)`.
            if let effect = action.effect {
                // `on_demand` is a PROMISE that get_conversation_history(N) returns this change.
                // A file that has moved since makes it false — see `EffectDiff.stale`.
                let availability: EffectDiff
                if !toolsAvailable { availability = .withheld }
                else if staleness.isStale(effect) { availability = .stale }
                else { availability = .onDemand }
                children += renderEffect(effect, diff: availability)
            }

            xml += children.isEmpty ? open + "/>\n" : open + ">\n" + children + "      </action>\n"
        }

        if let correction = turn.userCorrection {
            xml += "      <user_correction>\(xmlEscape(correction))</user_correction>\n"
        }

        xml += "    </turn>\n"
        return xml
    }

    // Why: returning "" on an empty post-checkpoint history threw away the fresh summary and, since
    // `AgentConnect` gates `ConversationHistoryTool` on the rendered text, the means to fetch it back
    /// Wraps rendered turns in the `<episodic_memory>` envelope and applies the checkpoint preamble: the single
    /// exit for every strategy. An empty history is `<recent/>`, not silence.
    private static func envelope(turnsXML: String, checkpointSummary: String?, compactedTurnCount: Int,
                                 toolsAvailable: Bool = true) -> String {
        // Tells a tool-less profile that the `<action>` transcript is true history: without it, the actions with no
        // schemas to match pressure the model into imitating tool calls.
        let preface = (!toolsAvailable && turnsXML.contains("<action "))
            ? "  <tool_availability>The actions below are HISTORY from earlier in this conversation. You have NO tools available this turn — do not attempt to call them. File changes show their line counts; the diffs themselves are not carried, so you cannot revert them.</tool_availability>\n"
            : ""

        let inner = turnsXML.isEmpty
            ? "<episodic_memory>\n  <recent/>\n</episodic_memory>"
            : "<episodic_memory>\n\(preface)  <recent>\n\(turnsXML)  </recent>\n</episodic_memory>"
        return wrapWithCheckpoint(summary: checkpointSummary, turnCount: compactedTurnCount, innerXML: inner)
    }

    // MARK: - Aggregate Effect Budget

    /// Which effect diffs fit this prompt, and what it cost to find out.
    private struct EffectBudgetOutcome {
        let elidedActionIDs: Set<UUID>
        let carriedCount: Int
        let carriedChars: Int
        /// Chronological, for the log — the pass itself walks backwards.
        let elidedFileNames: [String]
        /// Nil when no budget was supplied, i.e. every diff was carried.
        let budget: Int?

        var elidedCount: Int { elidedFileNames.count }
        var totalCount: Int { carriedCount + elidedCount }
    }

    /// Decides which effect diffs lose their body to fit the prompt: walks newest first and stops at the first
    /// that does not fit (the rule `NativeHistoryConverter` applies to turn pairs), keeping a contiguous recent
    /// window. Only the diff body is budgeted; the element and counts always render.
    private static func applyEffectBudget(to inlineTurns: ArraySlice<TurnPair>, budget: Int?) -> EffectBudgetOutcome {
        var candidates: [(id: UUID, fileName: String, chars: Int)] = []
        for turn in inlineTurns.reversed() {
            for action in turn.actions.reversed() {
                guard let effect = action.effect, let diff = effect.diff else { continue }
                candidates.append((action.id, effect.fileName, diff.count))
            }
        }

        guard let budget else {
            return EffectBudgetOutcome(
                elidedActionIDs: [],
                carriedCount: candidates.count,
                carriedChars: candidates.reduce(0) { $0 + $1.chars },
                elidedFileNames: [],
                budget: nil
            )
        }

        var spent = 0
        var carried = 0
        var overflowed = false
        var elidedIDs: Set<UUID> = []
        var elidedNames: [String] = []

        for candidate in candidates {
            if !overflowed, spent + candidate.chars <= budget {
                spent += candidate.chars
                carried += 1
            } else {
                overflowed = true
                elidedIDs.insert(candidate.id)
                elidedNames.append(candidate.fileName)
            }
        }

        return EffectBudgetOutcome(
            elidedActionIDs: elidedIDs,
            carriedCount: carried,
            carriedChars: spent,
            elidedFileNames: elidedNames.reversed(),
            budget: budget
        )
    }

    /// Logs how many `<outcome>` clips were left out because the native turns carry those answers in full.
    /// Request path only (a nil correlation is a gauge measurement).
    private static func logCarriedOutcomes(_ inlineTurns: [TurnPair], _ answersCarriedNatively: Set<UUID>,
                                           strategy: String, correlation: String?) {
        guard let correlation, !answersCarriedNatively.isEmpty else { return }
        let omitted = inlineTurns.filter { outcomeIsCarriedNatively($0, answersCarriedNatively) }.count
        guard omitted > 0 else { return }
        let kept = inlineTurns.filter { $0.outcome != nil }.count - omitted
        episodicLogger.info("[EPISODIC] \(correlation) \(strategy): omitted \(omitted) <outcome> clip(s) — those answers ride in full as native assistant turns; \(kept) outcome(s) kept (synthesized, or not carried natively). CONSEQUENCE: each answer reaches the model once, complete, instead of twice with one copy cut at 200 chars.")
    }

    private static func logEpisodicBudget(strategy: String, messages: Int, turnsRendered: Int,
                                          inlineTurns: Int, onDemandEffects: Int, xmlChars: Int,
                                          outcome: EffectBudgetOutcome, correlation: String?,
                                          toolsAvailable: Bool = true) {
        // No correlation means this render is a measurement (the fit gauges size the blob), not a request; logging
        // it would put phantom "[EPISODIC] ELIDED …" lines in the log.
        guard let correlation else { return }
        let tag = "\(correlation) "
        let shape = "\(strategy): \(messages) msg → \(turnsRendered) turn(s), \(xmlChars) chars XML"

        // Rendering nothing is the loudest case: it is the signature of the post-compaction turn, where the
        // checkpoint is the last message and the filter leaves no turns behind it.
        guard turnsRendered > 0 else {
            episodicLogger.info("[EPISODIC] \(tag)\(shape) — NO turns rendered. The model sees an empty <recent/>; if a checkpoint exists its <compacted_context> summary is the only history it gets this turn.")
            return
        }

        if outcome.elidedCount > 0, let budget = outcome.budget {
            let names = outcome.elidedFileNames.joined(separator: ", ")
            episodicLogger.info("[EPISODIC] \(tag)\(shape), \(inlineTurns) inline — ELIDED \(outcome.elidedCount) of \(outcome.totalCount) effect diff(s) to fit the \(budget)-char aggregate budget (oldest first): \(names). Those actions keep their counts and are marked diff=\"elided\", but the model cannot describe or revert those specific changes from memory this turn; the full diffs remain on the timeline rows.")
            return
        }

        // Pointer skeletons carry effects too (counts only, bodies behind the tool) and are not budgeted, so they
        // are reported separately from the budget outcome; hybrid can have both kinds.
        var parts: [String] = []
        if outcome.totalCount > 0 {
            let ceiling = outcome.budget.map(String.init) ?? "unbudgeted"
            parts.append("\(outcome.totalCount) inline effect(s) carrying \(outcome.carriedChars)/\(ceiling) diff chars")
        }
        if onDemandEffects > 0 {
            // The marker depends on whether the profile has the retrieval tool; hardcoding "on_demand" would log a
            // promise the blob does not make for tool-less profiles.
            parts.append(toolsAvailable
                ? "\(onDemandEffects) effect(s) as diff=\"on_demand\" — counts only, bodies via get_conversation_history(N)"
                : "\(onDemandEffects) effect(s) as diff=\"withheld\" — counts only, and no tool exists this turn to fetch the bodies")
        }
        let carried = parts.isEmpty ? "no file changes recorded" : parts.joined(separator: " + ")
        episodicLogger.debug("[EPISODIC] \(tag)\(shape), \(inlineTurns) inline, \(carried).")
    }

    // Why: numbering from the latest checkpoint made `get_conversation_history(0)` return the oldest compacted
    // turn, so "undo that" could revert the wrong change
    /// The turn list `get_conversation_history(N)` numbers, which every pointer skeleton enumerates. One
    /// definition numbers every turn from the start of the conversation (compacted rows are never deleted), so
    /// the skeleton and the tool cannot disagree.
    static func retrievableTurns(from history: [ChatMessage]) -> [TurnPair] {
        turnContext(from: history).turns
    }

    /// Turns after the latest checkpoint, plus how many the checkpoint stands in for.
    /// `compactedTurnCount` is 0 without a checkpoint so the preamble is omitted entirely.
    private static func turnContext(from history: [ChatMessage]) -> (turns: [TurnPair], summary: String?, compactedCount: Int) {
        let (summary, filteredHistory) = extractCheckpointContext(from: history)
        let turns = pairTurns(from: filteredHistory)
        let compacted = summary != nil ? (pairTurns(from: history).count - turns.count) : 0
        return (turns, summary, compacted)
    }

    // MARK: - Strategy Dispatch

    /// Turn windows each strategy renders. Constants rather than literals at the call site
    /// because `AgentConnect` spends them and the fit gauges measure what was spent — if the
    /// two ever disagree, the gauge lies about the exact payload it exists to measure.
    static let recentTurnLimit = 10
    static let hybridInlineCount = 3

    // Why: `history` must be ascending (oldest first): `pairTurns` walks forward, so a descending array (as the chat view
    // holds) mispairs every turn.
    /// The one place a history strategy becomes a rendered blob; `AgentConnect` and the fit gauges both build through it,
    /// so the gauge's number is the payload that ships. `correlation` is nil for measurement (silent).
    /// `toolsAvailable` is false for a bot, whose history can still contain a tool transcript from an earlier agent profile.
    static func build(strategy: HistoryStrategy,
                      from history: [ChatMessage],
                      includeImageNames: Bool = false,
                      effectBudget: Int? = nil,
                      correlation: String? = nil,
                      toolsAvailable: Bool = true,
                      staleness: EffectStalenessCheck = .unknown,
                      answersCarriedNatively: Set<UUID> = []) -> String {
        // Every branch forwards `toolsAvailable`: a branch that did not would give a tool-less profile the agent
        // rendering (full diff bodies, `diff="on_demand"` naming a tool it cannot call).
        switch strategy {
        case .recentHistory:
            return buildRecentHistoryString(from: history, limit: recentTurnLimit,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness,
                                            answersCarriedNatively: answersCarriedNatively)
        case .fullHistory:
            return buildRecentHistoryString(from: history, limit: history.count,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness,
                                            answersCarriedNatively: answersCarriedNatively)
        case .pointer:
            return buildPointerHistoryString(from: history, correlation: correlation,
                                             strategyLabel: strategy.rawValue,
                                             toolsAvailable: toolsAvailable, staleness: staleness)
        case .hybrid:
            return buildHybridHistoryString(from: history, inlineCount: hybridInlineCount,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness,
                                            answersCarriedNatively: answersCarriedNatively)
        }
    }

    // MARK: - XML Episodic Memory Builder

    /// Builds the XML episodic memory for prompt injection: per turn, recency, outcome, errors and corrections.
    /// - Parameters: limit: max recent turn-pairs; includeImageNames: label attached images, for vision profiles
    /// only.
    static func buildRecentHistoryString(from history: [ChatMessage], limit: Int = 4, includeImageNames: Bool = false,
                                         effectBudget: Int? = nil, correlation: String? = nil,
                                         strategyLabel: String = "recent",
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown,
                                         answersCarriedNatively: Set<UUID> = []) -> String {
        let (turns, summary, compacted) = turnContext(from: history)
        let recentTurns = turns.suffix(limit)
        // No bodies are rendered without tools, so there is nothing for the budget to spend.
        let budgeted = applyEffectBudget(to: recentTurns, budget: toolsAvailable ? effectBudget : nil)

        // Recency counts back from the newest RENDERED turn — the last one is "1 turn
        // ago". Turns older than `limit` are not rendered at all.
        var body = ""
        for (index, turn) in recentTurns.enumerated() {
            body += renderInlineTurn(
                turn,
                recency: recencyLabel(turnsAgo: recentTurns.count - index),
                includeImageNames: includeImageNames,
                elidedActionIDs: budgeted.elidedActionIDs,
                toolsAvailable: toolsAvailable,
                staleness: staleness,
                answersCarriedNatively: answersCarriedNatively
            )
        }
        logCarriedOutcomes(Array(recentTurns), answersCarriedNatively, strategy: strategyLabel, correlation: correlation)

        let xml = envelope(turnsXML: body, checkpointSummary: summary, compactedTurnCount: compacted,
                           toolsAvailable: toolsAvailable)
        logEpisodicBudget(strategy: strategyLabel, messages: history.count, turnsRendered: recentTurns.count,
                          inlineTurns: recentTurns.count, onDemandEffects: 0, xmlChars: xml.count,
                          outcome: budgeted, correlation: correlation)
        return xml
    }

    // MARK: - Pointer History (Skeleton + Tool)

    /// Builds an XML episodic memory string where every turn is a skeleton: outcomes point to
    /// `get_conversation_history(INDEX)`, actions carry tool name and status only. A `<compacted_context>`
    /// preamble still rides along when a checkpoint exists.
    static func buildPointerHistoryString(from history: [ChatMessage], correlation: String? = nil,
                                          strategyLabel: String = "pointer",
                                          toolsAvailable: Bool = true,
                                          staleness: EffectStalenessCheck = .unknown) -> String {
        let (turns, summary, compacted) = turnContext(from: history)

        var body = ""
        for (index, turn) in turns.enumerated() {
            body += renderPointerTurn(turn, index: index, recency: recencyLabel(turnsAgo: turns.count - index),
                                      toolsAvailable: toolsAvailable, staleness: staleness)
        }

        let xml = envelope(turnsXML: body, checkpointSummary: summary, compactedTurnCount: compacted,
                           toolsAvailable: toolsAvailable)
        // No effect bodies here, but every mutating action still renders a counts-only `diff=on_demand` effect; reporting those
        // through the budget outcome would log '0 effect(s)' for a conversation that recorded twenty file changes.
        let onDemand = turns.reduce(0) { $0 + $1.actions.filter { $0.effect != nil }.count }
        logEpisodicBudget(strategy: strategyLabel, messages: history.count, turnsRendered: turns.count,
                          inlineTurns: 0, onDemandEffects: onDemand, xmlChars: xml.count,
                          outcome: applyEffectBudget(to: [], budget: nil), correlation: correlation,
                          toolsAvailable: toolsAvailable)
        return xml
    }

    // MARK: - Hybrid History (Recent Full + Older Pointers)

    /// Builds an XML episodic memory string with a split strategy: older turns as pointer skeletons, the last
    /// `inlineCount` turns in full; both use the same renderers as the other strategies.
    /// - Parameters: inlineCount: most recent turns rendered in full (default 3).
    static func buildHybridHistoryString(from history: [ChatMessage], inlineCount: Int = 3, includeImageNames: Bool = false,
                                         effectBudget: Int? = nil, correlation: String? = nil,
                                         strategyLabel: String = "hybrid",
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown,
                                         answersCarriedNatively: Set<UUID> = []) -> String {
        let (turns, summary, compacted) = turnContext(from: history)
        let pointerCount = max(0, turns.count - inlineCount)
        // Only the inline segment carries effect bodies, so only it is budgeted; with no tools it carries none (every effect is
        // marked `withheld`), so budgeting would only log a misleading ELIDED count. Same gate as `buildRecentHistoryString`.
        let budgeted = applyEffectBudget(to: turns.dropFirst(pointerCount),
                                         budget: toolsAvailable ? effectBudget : nil)

        var body = ""
        for (index, turn) in turns.enumerated() {
            let recency = recencyLabel(turnsAgo: turns.count - index)
            body += index < pointerCount
                ? renderPointerTurn(turn, index: index, recency: recency,
                                    toolsAvailable: toolsAvailable, staleness: staleness)
                : renderInlineTurn(turn, recency: recency, includeImageNames: includeImageNames,
                                   elidedActionIDs: budgeted.elidedActionIDs,
                                   toolsAvailable: toolsAvailable, staleness: staleness,
                                   answersCarriedNatively: answersCarriedNatively)
        }
        logCarriedOutcomes(Array(turns.dropFirst(pointerCount)), answersCarriedNatively,
                           strategy: strategyLabel, correlation: correlation)

        let xml = envelope(turnsXML: body, checkpointSummary: summary, compactedTurnCount: compacted,
                           toolsAvailable: toolsAvailable)
        let hybridOnDemand = turns.prefix(pointerCount).reduce(0) { $0 + $1.actions.filter { $0.effect != nil }.count }
        logEpisodicBudget(strategy: strategyLabel, messages: history.count, turnsRendered: turns.count,
                          inlineTurns: turns.count - pointerCount, onDemandEffects: hybridOnDemand,
                          xmlChars: xml.count, outcome: budgeted, correlation: correlation,
                          toolsAvailable: toolsAvailable)
        return xml
    }

    // MARK: - Turn Pairing

    /// A paired user↔agent turn representing one complete interaction cycle.
    /// Internal visibility to allow shared use by ConversationHistoryTool for index stability.
    internal struct TurnPair {
        let userQuery: String
        /// Filenames of images the USER attached on this turn. Rendered as an
        /// `<attached_images>` label (vision profiles only) so the model can map the
        /// re-provided image bytes back to the turn they belong to. Empty for text turns.
        let attachedImageNames: [String]
        let actions: [MemoryAction]
        let userCorrection: String?
        /// Truncated agent response (max 200 chars). Always present — for cancelled turns,
        /// synthesized from completed/failed tool names to preserve follow-up referents.
        /// This is the PROMPT form: it rides every request, so it stays small.
        let outcome: String?
        /// The same response untruncated: the detail `get_conversation_history(N)` serves when the model asks for
        /// what the skeleton withheld. Falls back to the synthesized outcome for cancelled or empty turns, which
        /// beats the raw placeholder text.
        let fullResponse: String
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
        /// The agent message this turn's answer came from; nil for an orphaned question.
        var agentMessageID: UUID? = nil
        /// True when `outcome` is a clip of the agent's own response text — the case that can
        /// duplicate a native assistant turn. False for SYNTHESIZED outcomes (cancelled or
        /// empty turns: "Completed: … (Terminated by user)"), which no native turn carries.
        var outcomeIsResponseClip: Bool = false
    }

    /// Pairs consecutive user↔agent messages into logical turns.
    /// Internal visibility so ConversationHistoryTool can use the same pairing for index stability.
    static func pairTurns(from history: [ChatMessage]) -> [TurnPair] {
        var turns: [TurnPair] = []
        var pendingUserText: String? = nil
        var pendingUserImages: [String] = []

        for message in history {
            // Same rule as `NativeHistoryConverter.pairMessages`: a row this build cannot read is skipped and clears the
            // pending user turn, so indexes stay aligned between the native skeleton and `get_conversation_history`.
            guard !message.content.isUnrecognised else {
                pendingUserText = nil
                pendingUserImages = []
                continue
            }
            if message.sender == .user {
                pendingUserText = message.content.textContent ?? ""
                pendingUserImages = message.attachedImageFiles?.map(\.name) ?? []

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
                            errorReason: classification.errorReason,
                            effect: data.effect,
                            exitCode: data.exitCode
                        ))
                    }
                }

                // Always capture the agent's response as the outcome, so follow-ups like "delete the first one" have a
                // referent: the model sees what it told the user, not just which tools ran.
                let responseText = message.content.textContent ?? ""

                // Detect cancellation from the executor's placeholder or `terminalOutcome == .cancelled`, so a row carrying either
                // signal is classified correctly; `.contains` is deliberate: this classifies rows, it doesn't gate indexing.
                let wasCancelled = responseText.contains(ChatMessage.stoppedRunPlaceholder)
                    || message.terminalOutcome == .cancelled

                let outcome: String?
                let fullResponse: String
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
                    // No real response exists, so there is nothing fuller to serve.
                    fullResponse = outcome ?? ""
                } else {
                    outcome = truncate(responseText, maxLength: 200)
                    fullResponse = responseText
                }

                turns.append(TurnPair(
                    userQuery: userText,
                    attachedImageNames: pendingUserImages,
                    actions: actions,
                    userCorrection: userCorrection,
                    outcome: outcome,
                    fullResponse: fullResponse,
                    wasCancelled: wasCancelled,
                    terminalOutcome: message.terminalOutcome,
                    terminalReason: message.terminalReason,
                    agentMessageID: message.id,
                    outcomeIsResponseClip: !(wasCancelled || responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ))
                pendingUserText = nil
                pendingUserImages = []
            }
        }

        // Orphaned user message — asked but never got a response
        if let userText = pendingUserText {
            turns.append(TurnPair(
                userQuery: userText,
                attachedImageNames: pendingUserImages,
                actions: [],
                userCorrection: nil,
                outcome: "No agent response",
                fullResponse: "No agent response",
                wasCancelled: true,
                terminalOutcome: .cancelled,
                terminalReason: "Agent never responded to this query"
            ))
        }

        return turns
    }
}

private let episodicLogger = DGLogger(category: "Episodic")
