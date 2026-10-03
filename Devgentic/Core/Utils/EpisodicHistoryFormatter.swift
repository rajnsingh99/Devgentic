// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
//        <turn status="completed|partial|failed|cancelled" goal="..." recency="1 turn ago">
//          <outcome>Truncated agent response</outcome>
//          <termination>Reason for forced termination (e.g. circuit-breaker abort)</termination>
//          <action tool="tool_name" status="..." exit="1">
//            <params key="value" .../>
//            <error>Error reason (1024 chars — errorCharacterLimit — then a truncation note)</error>
//            <effect file="X.java" path="/abs/path" added="14" removed="5" ...>diff</effect>
//          </action>
//          <user_correction>User denied: tool_name</user_correction>
//        </turn>
//      </recent>
//    </episodic_memory>
//
//  `<action status>` is the full `ActionStatus.xmlValue` vocabulary, not a three-value one:
//    active | success | denied | permission_denied | failed | timeout | invalid_args |
//    not_found | cancelled
//  `exit` is the shell COMMAND's exit status and appears only when non-zero. It is separate
//  from `status` on purpose: the tool succeeded — it ran the command — while the command
//  itself did not. Collapsing them would abort runs on a `grep` miss.
//
//  `<effect>` carries AT MOST ONE of the following markers — never two. They are mutually
//  exclusive by construction (see `renderEffect`), because each answers a different "what can
//  I do about this?", and a pair of them would answer it two ways at once:
//    truncated="true"   the diff BODY hit `diffCharacterLimit` — only ever with a body present
//    baseline="none"    no pre-write snapshot existed, so the change could not be reconstructed
//    diff="elided"      a body exists but the aggregate budget dropped it this turn
//    diff="on_demand"   body withheld; fetch it with get_conversation_history(N)
//    diff="withheld"    body withheld and NOT fetchable — the profile has no tools this turn
//  The element is self-closing whenever it has no body, which is every pointer turn.
//
//  Not shown above, all emitted by `envelope` / `wrapWithCheckpoint`:
//    <tool_availability>          when a tool-less profile is handed a tool transcript
//    <compacted_context checkpoint_turns="N">  a checkpoint summary, preceding <recent>
//    <recent/>                    self-closing when no turns survive the filter — the
//                                 post-compaction shape, where the summary is the only history
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

    /// The `<effect>` element for one action — what it changed on disk. This is what makes
    /// "undo that" answerable: without it the model knows it called `write_file` and nothing
    /// about the result.
    ///
    /// `baseline="none"` marks a write whose prior content was never captured (the file was
    /// over `preWriteSnapshotByteLimit`, or wasn't readable as UTF-8). Its `removed="0"` is a
    /// PLACEHOLDER, and without the marker the model reads a destructive overwrite of a large
    /// file as a clean create — and will offer to undo something it cannot reconstruct.
    ///
    /// `diff="elided"` marks a measured change whose BODY was dropped to fit the aggregate
    /// effect budget. It is deliberately not `baseline="none"`: that one means the pre-image
    /// was never captured, so the change is unrecoverable and `removed="0"` is a placeholder.
    /// Elided means the opposite — it WAS measured, the counts are real, and the diff is
    /// still on the timeline row. Spelling both the same way would re-create exactly the
    /// ambiguity `baseline="none"` exists to remove.
    ///
    /// `diff="on_demand"` marks a measured change the POINTER strategy deliberately did not
    /// inline. Unlike `elided`, the model can still get it: this turn's `<outcome>` names the
    /// `get_conversation_history(N)` call that returns it.
    ///
    /// Internal rather than private so the contract above is testable.
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

    /// Whether an `<effect>` body is in the prompt — and if not, what the model can do about
    /// it. One attribute, mutually exclusive values, because the three cases have different
    /// action implications: conflating any two re-creates the ambiguity `baseline="none"`
    /// exists to remove.
    enum EffectDiff {
        /// The body is rendered inline.
        case inline
        /// Measured, dropped to fit the aggregate budget. NOT retrievable by the model —
        /// the full diff is on the timeline row, which is a user-facing surface.
        case elided
        /// Measured, deliberately not inlined by the pointer strategy. Retrievable via the
        /// `get_conversation_history(N)` call this turn's `<outcome>` names.
        case onDemand
        /// Measured, but this profile has NO TOOLS — a diff is a revert instrument, and a
        /// profile that cannot call `write_file` cannot act on one. Distinct from `elided`
        /// (which means the budget dropped it) because the reason is permanent for this turn,
        /// and from `on_demand` (which promises a retrieval) because there is no tool to
        /// retrieve with. The counts and path still render: "what did you change?" stays
        /// answerable, only "undo it" does not.
        case withheld
        /// Measured, but the FILE HAS CHANGED since the write — so the stored diff no longer
        /// describes it.
        ///
        /// ⚠️⚠️ Distinct from every case above because the reason is about the WORLD, not this
        /// prompt's budget or capabilities. `on_demand` promises "call get_conversation_history(N)
        /// and you will get this change"; once the file moved, that promise is false. Field-observed
        /// 2026-09-20: a file was restored underneath a conversation and the record kept advertising
        /// a retrievable diff, so the model answered "successfully completed in a previous turn" and
        /// made ZERO tool calls.
        ///
        /// ⚠️ The counts and path still render. "What did you change?" stays answerable — only the
        /// claim that the stored body still matches the file is withdrawn. Same shape as `withheld`,
        /// different cause.
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

    /// Decides whether an effect's file still matches what the write left behind.
    ///
    /// ⚠️⚠️ INJECTED, and it must stay injected. The comparison is a `stat`, and this formatter is
    /// called by `ContextWindowGauge` to SIZE the prompt — on every recompute, including while the
    /// user types. Putting the syscall inside `renderEffect` would put the filesystem on that path.
    /// The request builder supplies `.live`; the gauge supplies `.unknown` and does no I/O.
    ///
    /// ⚠️ `.unknown` is also the honest answer for an effect with no fingerprint (recorded before
    /// the field existed), which is why "unknown" renders exactly as it did before this case
    /// existed rather than guessing either way.
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

    /// Truncates a string to a maximum length, appending "..." if truncated.
    ///
    /// Fine for a goal, an outcome or a param — nobody ACTS on those, so "there was more" is
    /// all the reader needs. Errors get `cappedError` instead; see below.
    private static func truncate(_ string: String, maxLength: Int) -> String {
        if string.count <= maxLength { return string }
        return String(string.prefix(maxLength - 3)) + "..."
    }

    /// Longest tool-failure text carried into memory.
    ///
    /// Was 150 — shorter than most compiler errors and nearly every stack trace, so the model
    /// routinely saw a clipped first line and adapted to a cause it could not read. Error text
    /// is the highest-value prose in the blob: it is WHY the agent must do something different,
    /// and unlike a successful read it cannot be re-derived by calling the tool again.
    ///
    /// A quarter of `ActionEffect.diffCharacterLimit`. Bounded in aggregate by the iteration
    /// cap (15–20 tool calls per turn), so even an all-failing turn carries ~20 KB — the same
    /// order as a single effect diff, and far less than the diffs a working turn carries.
    static let errorCharacterLimit = 1_024

    /// Truncation that states what it dropped, matching `ToolExecutionData.cappedOutput`.
    ///
    /// The generic `truncate` appends "..." and nothing else. That is a decision input here:
    /// a silently clipped stack trace makes the model adapt to a cause it never saw, and the
    /// real error is often several frames down. Naming the loss lets it ask for more instead
    /// of guessing.
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
        // HITL Waiting Contract §4: the next turn is told the previous one hit its limit.
        case .timedOut:  return "timed_out"
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

    // MARK: - Shared Turn Renderers
    //
    // There are exactly TWO ways to render a turn — inline and pointer — and every
    // strategy is a choice of which to use for which turns. They live here, once.
    //
    // Each strategy used to hand-roll its own copy, and the copies drifted:
    // `buildHybridHistoryString`'s inline branch was commented "same format as
    // buildRecentHistoryString" while emitting no `<effect>` and unsorted `<params>`,
    // so a hybrid profile could not answer "undo that" for a write that had just
    // happened. Fixing that one branch would have left the mechanism that produced it
    // intact; composing from a single renderer makes the whole class of drift
    // impossible instead.

    /// ` exit="N"` for a shell command that returned non-zero, empty otherwise.
    ///
    /// This is the whole later-turn fix: the exit code was surfaced in the observation and
    /// then lost, because successful tool output is deliberately not carried. So on the next
    /// prompt a failed `swift build` was indistinguishable from a passing one — the model
    /// could read its own `status="success"` and conclude the build was fine.
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

    /// A turn rendered in FULL: outcome, params, errors, and what each action changed.
    private static func renderInlineTurn(_ turn: TurnPair, recency: String, includeImageNames: Bool,
                                         elidedActionIDs: Set<UUID> = [],
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown) -> String {
        var xml = turnOpenTag(turn, recency: recency)

        // Image label — names the images the user attached on this turn so the model
        // can map the re-provided image bytes (attached to the current message) back
        // to the turn they belong to. Vision profiles only; text turns render nothing.
        if includeImageNames, !turn.attachedImageNames.isEmpty {
            let names = turn.attachedImageNames.map(xmlEscape).joined(separator: ", ")
            xml += "      <attached_images>\(names)</attached_images>\n"
        }

        // Agent response context — present on every turn so follow-ups
        // like "delete the first one" can resolve referents.
        if let outcome = turn.outcome {
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
            // `xmlValue` covers all 9 ActionStatus cases — an earlier switch collapsed
            // everything but success/denied into "failed", losing timeouts, permission
            // rejections, and not-found tools.
            // `exit` is SEPARATE from `status` on purpose. `status` is whether the TOOL ran;
            // `exit` is what the COMMAND returned. Merging them would make `grep` with no
            // match a tool failure, and three of those abort the run via the circuit breaker.
            // Only non-zero is emitted — a zero exit is the default and costs nothing to omit.
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

            // What the action actually changed. This is what makes "undo that"
            // answerable — without it the model knows it called write_file and
            // nothing about the result.
            //
            // An elided action keeps the ELEMENT and its counts and loses only the diff
            // body, so the model still knows the file changed and by how much. Dropping
            // the whole element would read as "nothing happened", which is the failure
            // `<effect>` was introduced to fix.
            if let effect = action.effect {
                // ⚠️ Precedence. `withheld` first: with no tools there is nothing to retrieve
                // WITH, which is true regardless of the file. `stale` next, because once the file
                // has moved the stored body no longer describes it — rendering it inline would
                // hand the model a revert instrument for a state that no longer exists, which is
                // the same mistake as promising a retrieval. Only then does the budget speak.
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

    /// A turn rendered as a SKELETON: tool names and statuses only, with the outcome
    /// pointing at `get_conversation_history(index)` for on-demand detail. Params and
    /// effects are omitted deliberately — that omission is the strategy.
    ///
    /// Errors are the standing exception: a failure is a durable consequence, not a
    /// detail the model can re-derive by looking again.
    ///
    /// `toolsAvailable` decides how an effect is marked: `diff="on_demand"` names a retrieval
    /// the model can perform, so a tool-less profile gets `diff="withheld"` instead — the
    /// counts still render, only the promise of a fetch is dropped. The parameter has no
    /// default because a silent one is exactly how both call sites came to make that promise
    /// to profiles that have no tools to keep it with.
    private static func renderPointerTurn(_ turn: TurnPair, index: Int, recency: String,
                                          toolsAvailable: Bool,
                                          staleness: EffectStalenessCheck) -> String {
        var xml = turnOpenTag(turn, recency: recency)
        // The retrieval instruction is only true when there is something to retrieve WITH.
        // Marking the effects `withheld` while this line still said "Call
        // get_conversation_history(N)" left the blob contradicting itself: the envelope
        // preface says the profile has no tools this turn, and every turn body told it to
        // call one. A skeleton that cannot be expanded should say so rather than name a tool.
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
            // A file mutation is a durable consequence, not a detail the model can re-derive
            // by looking again — the same reason errors are the skeleton's standing
            // exception. Counts only, ~90 chars: enough to know something changed and that
            // it is worth asking about. The body comes from `get_conversation_history(N)`.
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

    /// Wraps rendered turns in the `<episodic_memory>` envelope and applies the checkpoint
    /// preamble — the single exit for every strategy.
    ///
    /// Shared because two strategies used to `return ""` on an empty post-checkpoint
    /// history BEFORE reaching the wrap. Compaction leaves the checkpoint as the last
    /// message, so the very next turn filtered to zero turns and threw away the summary
    /// that had just been computed to stand in for the turns it replaced — and, because
    /// `AgentConnect` gates `ConversationHistoryTool` on the rendered text, the means to
    /// fetch it back went with it. An empty history is `<recent/>`, not silence.
    private static func envelope(turnsXML: String, checkpointSummary: String?, compactedTurnCount: Int,
                                 toolsAvailable: Bool = true) -> String {
        // Without this a tool-less profile reads a full `<action tool="write_file">` transcript
        // with no schemas to match — the same mimicry pressure that made tool summaries in
        // assistant turns produce imitated tool calls instead of real ones. The actions are
        // TRUE history and worth keeping; what was missing was the sentence saying so.
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

    /// Decides which effect diffs must lose their body to fit the prompt.
    ///
    /// Walks NEWEST first and stops at the first diff that does not fit — the same
    /// newest-first, stop-on-overflow rule `NativeHistoryConverter` applies to turn pairs,
    /// so both history channels trim by one policy. Stopping rather than greedily skipping
    /// keeps the carried set a contiguous recent window the model can reason about ("I can
    /// see the last N changes") instead of a scattered subset with holes in it.
    ///
    /// Newest-first because "undo that" refers to the most recent write. Only the diff
    /// BODY is budgeted; the element and its counts always render.
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

    /// Episodic memory had NO size observability at all: nothing logged the blob, so a
    /// context overflow caused by effect growth was undiagnosable from logs. An elision is
    /// a silent drop, so it is logged at info with its consequence spelled out; the quiet
    /// case still records the size at debug so growth is visible before it bites.
    private static func logEpisodicBudget(strategy: String, messages: Int, turnsRendered: Int,
                                          inlineTurns: Int, onDemandEffects: Int, xmlChars: Int,
                                          outcome: EffectBudgetOutcome, correlation: String?,
                                          toolsAvailable: Bool = true) {
        // No correlation → this render is a MEASUREMENT (the fit gauges build the blob to
        // size it), not a request. Logging it would put phantom "[EPISODIC] ELIDED …" lines
        // in the log for prompts that were never sent.
        guard let correlation else { return }
        let tag = "\(correlation) "
        let shape = "\(strategy): \(messages) msg → \(turnsRendered) turn(s), \(xmlChars) chars XML"

        // Rendering nothing is the loudest case, not the quietest: it is the signature of the
        // post-compaction turn, where the checkpoint is the last message and the filter leaves
        // no turns behind it. Two strategies used to return "" here and lose the summary too.
        guard turnsRendered > 0 else {
            episodicLogger.info("[EPISODIC] \(tag)\(shape) — NO turns rendered. The model sees an empty <recent/>; if a checkpoint exists its <compacted_context> summary is the only history it gets this turn.")
            return
        }

        if outcome.elidedCount > 0, let budget = outcome.budget {
            let names = outcome.elidedFileNames.joined(separator: ", ")
            episodicLogger.info("[EPISODIC] \(tag)\(shape), \(inlineTurns) inline — ELIDED \(outcome.elidedCount) of \(outcome.totalCount) effect diff(s) to fit the \(budget)-char aggregate budget (oldest first): \(names). Those actions keep their counts and are marked diff=\"elided\", but the model cannot describe or revert those specific changes from memory this turn; the full diffs remain on the timeline rows.")
            return
        }

        // Pointer skeletons carry effects too now — counts only, bodies behind the tool. They
        // are NOT budgeted (no bodies to budget), so reporting them through the budget
        // outcome alone would log "0 effect(s)" for a turn that recorded twenty file changes.
        // Hybrid can have both kinds at once, so both are reported.
        var parts: [String] = []
        if outcome.totalCount > 0 {
            let ceiling = outcome.budget.map(String.init) ?? "unbudgeted"
            parts.append("\(outcome.totalCount) inline effect(s) carrying \(outcome.carriedChars)/\(ceiling) diff chars")
        }
        if onDemandEffects > 0 {
            // The marker these render under depends on whether the profile HAS the retrieval
            // tool. Hardcoding "on_demand" here logged a promise the blob no longer makes for
            // tool-less profiles, which is exactly the drift this log exists to catch.
            parts.append(toolsAvailable
                ? "\(onDemandEffects) effect(s) as diff=\"on_demand\" — counts only, bodies via get_conversation_history(N)"
                : "\(onDemandEffects) effect(s) as diff=\"withheld\" — counts only, and no tool exists this turn to fetch the bodies")
        }
        let carried = parts.isEmpty ? "no file changes recorded" : parts.joined(separator: " + ")
        episodicLogger.debug("[EPISODIC] \(tag)\(shape), \(inlineTurns) inline, \(carried).")
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

    /// The ONE place a history strategy becomes a rendered blob.
    ///
    /// `AgentConnect` builds the prompt through this and the fit gauges size the prompt
    /// through it, so the number the gauge reports IS the payload that ships — not a
    /// parallel estimate keeping its own copy of the render rules. This file exists because
    /// copies drift; an estimator would have been a fourth one.
    ///
    /// - Parameter correlation: nil for measurement (silent), a `conv:…/trace:…` string on
    ///   the request path (logs).
    /// - Important: `history` must be ASCENDING (oldest first). `pairTurns` walks forward
    ///   matching each user message to the agent reply that follows it, so a descending
    ///   array — which is what the chat view holds — mispairs every turn.
    /// - Parameter toolsAvailable: false for a BOT, which `AgentConnect` gives `rawTools = []`
    ///   and `ChatExecutor` sends `tools: nil`. Its history can still contain a full tool
    ///   transcript from when the conversation ran under an agent profile.
    static func build(strategy: HistoryStrategy,
                      from history: [ChatMessage],
                      includeImageNames: Bool = false,
                      effectBudget: Int? = nil,
                      correlation: String? = nil,
                      toolsAvailable: Bool = true,
                      staleness: EffectStalenessCheck = .unknown) -> String {
        // EVERY branch forwards `toolsAvailable`. Two of them did not, and because the
        // builders below it defaulted the flag to true, a tool-less profile silently got the
        // agent rendering: no `<tool_availability>` preface, full diff bodies inline, and
        // `diff="on_demand"` effects naming a `get_conversation_history` call it cannot make.
        // A diff is a revert instrument and the pointer outcome is a fetch instruction —
        // neither belongs in a prompt for a profile that was sent `tools: nil`.
        switch strategy {
        case .recentHistory:
            return buildRecentHistoryString(from: history, limit: recentTurnLimit,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness)
        case .fullHistory:
            return buildRecentHistoryString(from: history, limit: history.count,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness)
        case .pointer:
            return buildPointerHistoryString(from: history, correlation: correlation,
                                             strategyLabel: strategy.rawValue,
                                             toolsAvailable: toolsAvailable, staleness: staleness)
        case .hybrid:
            return buildHybridHistoryString(from: history, inlineCount: hybridInlineCount,
                                            includeImageNames: includeImageNames,
                                            effectBudget: effectBudget, correlation: correlation,
                                            strategyLabel: strategy.rawValue,
                                            toolsAvailable: toolsAvailable, staleness: staleness)
        }
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
    /// - Parameter includeImageNames: when true (vision profiles), each turn that had
    ///   attached images renders an `<attached_images>` label so the model can map the
    ///   re-provided image bytes to the turn they belong to. Left false for non-vision
    ///   profiles, whose images are omitted — labeling images the model won't receive
    ///   would be misleading.
    static func buildRecentHistoryString(from history: [ChatMessage], limit: Int = 4, includeImageNames: Bool = false,
                                         effectBudget: Int? = nil, correlation: String? = nil,
                                         strategyLabel: String = "recent",
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown) -> String {
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
                staleness: staleness
            )
        }

        let xml = envelope(turnsXML: body, checkpointSummary: summary, compactedTurnCount: compacted,
                           toolsAvailable: toolsAvailable)
        logEpisodicBudget(strategy: strategyLabel, messages: history.count, turnsRendered: recentTurns.count,
                          inlineTurns: recentTurns.count, onDemandEffects: 0, xmlChars: xml.count,
                          outcome: budgeted, correlation: correlation)
        return xml
    }

    // MARK: - Pointer History (Skeleton + Tool)

    /// Builds an XML episodic memory string where every turn is a skeleton.
    /// Outcomes point to `get_conversation_history(INDEX)` for on-demand retrieval.
    /// Actions include tool name and status only — no params (save tokens).
    ///
    /// A `<compacted_context>` preamble still rides along when a checkpoint exists: the
    /// skeleton replaces DETAIL, not the summary standing in for turns that were
    /// compacted away. This used to discard the summary outright.
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
        // No effect BODIES here by construction, but every mutating action still renders a
        // counts-only `diff="on_demand"` effect — reporting those through the budget outcome
        // would log "0 effect(s)" for a conversation that recorded twenty file changes.
        // Skeletons also grow linearly with conversation length, so the size is worth seeing.
        let onDemand = turns.reduce(0) { $0 + $1.actions.filter { $0.effect != nil }.count }
        logEpisodicBudget(strategy: strategyLabel, messages: history.count, turnsRendered: turns.count,
                          inlineTurns: 0, onDemandEffects: onDemand, xmlChars: xml.count,
                          outcome: applyEffectBudget(to: [], budget: nil), correlation: correlation,
                          toolsAvailable: toolsAvailable)
        return xml
    }

    // MARK: - Hybrid History (Recent Full + Older Pointers)

    /// Builds an XML episodic memory string with a split strategy:
    /// - Older turns: pointer skeletons (`renderPointerTurn`, as `buildPointerHistoryString`)
    /// - Recent turns (last `inlineCount`): full content (`renderInlineTurn`, as
    ///   `buildRecentHistoryString`) — outcomes, params, errors, and effects
    ///
    /// Both segments call the SAME renderers the other two strategies call. The previous
    /// inline branch was a copy that claimed parity in a comment and had lost `<effect>`.
    ///
    /// - Parameters:
    ///   - history: The array of ChatMessages.
    ///   - inlineCount: Number of most recent turns to render with full content (default 3).
    static func buildHybridHistoryString(from history: [ChatMessage], inlineCount: Int = 3, includeImageNames: Bool = false,
                                         effectBudget: Int? = nil, correlation: String? = nil,
                                         strategyLabel: String = "hybrid",
                                         toolsAvailable: Bool = true,
                                         staleness: EffectStalenessCheck = .unknown) -> String {
        let (turns, summary, compacted) = turnContext(from: history)
        let pointerCount = max(0, turns.count - inlineCount)
        // Only the inline segment carries effect bodies, so only it is budgeted — and with no
        // tools it carries none, because `renderInlineTurn` marks every effect `withheld`
        // ahead of consulting `elidedActionIDs`. Budgeting anyway would compute an elision set
        // that changes no output and then log "ELIDED N of M" for bodies that were dropped for
        // an entirely different, permanent reason. Same gate `buildRecentHistoryString` uses.
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
                                   toolsAvailable: toolsAvailable, staleness: staleness)
        }

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
        /// The same response UNTRUNCATED — the detail `get_conversation_history(N)` serves
        /// when the model asks for what the skeleton deliberately withheld.
        ///
        /// The tool used to hand back `outcome`, i.e. the identical 200-char clip the prompt
        /// already carried, so a `pointer` agent could never recover more than 200 characters
        /// of any answer it had given and a `recentHistory` agent got a round trip that
        /// returned exactly what it already had.
        ///
        /// Falls back to the synthesized outcome for cancelled/empty turns: there is no
        /// fuller version, and the synthesis (which names the tools that did complete) beats
        /// the raw placeholder text.
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
    }

    /// Pairs consecutive user↔agent messages into logical turns.
    /// Internal visibility so ConversationHistoryTool can use the same pairing for index stability.
    static func pairTurns(from history: [ChatMessage]) -> [TurnPair] {
        var turns: [TurnPair] = []
        var pendingUserText: String? = nil
        var pendingUserImages: [String] = []

        for message in history {
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

                // Always capture the agent's response as outcome so the model knows
                // what it told the user — not just which tools ran. Without this,
                // follow-up references like "delete the first one" have no referent
                // because the agent can't see what files it previously listed.
                let responseText = message.content.textContent ?? ""

                // Detect cancellation: the executor emits this placeholder when
                // the user stops execution mid-session. Modern rows also have
                // `terminalOutcome == .cancelled`; we OR the two signals so a row
                // missing one but having the other is still classified correctly.
                // Single source of truth for the literals (ChatMessage owns them —
                // resolveFinalizedContent is the producer). `.contains` semantics kept
                // here deliberately: this CLASSIFIES rows, it doesn't gate indexing.
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
                    terminalReason: message.terminalReason
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
