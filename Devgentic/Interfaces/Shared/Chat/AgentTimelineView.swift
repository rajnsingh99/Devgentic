// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentTimelineView.swift
//  Devgentic
//

import SwiftUI
import os

private let timelineLogger = DGLogger(category: "AgentTimelineView")

struct AgentTimelineView: View {
    /// The timeline events to render. Can come from a ChatMessage or directly from
    /// a workflow node's per-node timeline (`WorkflowExecutionState.nodeTimelines[nodeID]`).
    private let events: [TimelineEvent]
    private let isStreaming: Bool

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 15.0
    @AppStorage(AppSettings.showTimelineThoughtsKey) private var showThoughts: Bool = false

    /// Optional text of the final content shown below the timeline. Used to
    /// deduplicate narrative events that would otherwise repeat the same text.
    /// Populated from `ChatMessage.content.textContent` in the message-based init.
    private let finalContentText: String?

    /// Optional streaming context that drives the bottom progress footer (pulsing icon +
    /// live elapsed + final token count). Populated only by the message-based init —
    /// workflow per-node timelines have their own indicators and leave this nil.
    private let streamingContext: StreamingContext?

    /// When true, `.thought`/`.reasoning` nodes render as a muted compact row —
    /// appropriate when the bubble shows its final answer separately. Workflow
    /// per-node views keep this false because their "thought" often *is* the
    /// node's final output and should stay full scale.
    private let compactReasoning: Bool

    /// [TL-4] Change marker for `events` — proxies the whole array in `Equatable` so
    /// SwiftUI can skip body (and the grouping rebuild) when the timeline didn't change.
    /// Bumped by `ChatMessage.timelineEvents.didSet` on EVERY mutation path.
    private let revision: UInt64

    /// How the run ACTUALLY ended, when the caller knows it (`ChatMessage.terminalOutcome`,
    /// stamped at finalize). The header must never claim a run was stopped without this:
    /// the previous heuristic inferred cancellation from a per-tool `failureCategory`, which
    /// `ToolExecutionLoop` also stamps when the user merely SKIPS an `ask_user` prompt on a run
    /// that then completes normally. nil = not known (the workflow per-node init), and the
    /// header then reports success/degraded but never "Stopped".
    private let terminalOutcome: ExecutionOutcome?

    /// `message.lifecycleState.isInterrupted`, or false for the workflow per-node inits, which
    /// render a node's events and have no message lifecycle of their own.
    private let isInterrupted: Bool

    /// The conversation this timeline BELONGS to, when the caller knows it. Threaded down to
    /// `ActionDetailView` so an "Open in viewer" whose disk read outlives a conversation switch
    /// can be dropped instead of landing a tab in whatever conversation is open when it returns
    /// (CF-53).
    ///
    /// nil = the caller supplied none. That is NOT "this surface opens no tabs" — any caller
    /// that leaves it nil still opens into the SAME shared Code Viewer, because
    /// `ChatHistoryViewModel` is injected at the app root. A nil here only means the
    /// per-conversation half of the check cannot run; the switch-in-flight half in
    /// `ActionDetailView.shouldDeliverOpen` still covers it. The workflow per-node timeline
    /// DOES supply one (`WorkflowExecutionTimelineView` passes its `conversationID` to all four
    /// `AgentTimelineView` inits) — note that value is the SIDEBAR selection, which leads the
    /// chat view model by the switch debounce; see the property's doc there.
    private let conversationID: UUID?

    /// When true, the expanded nodes container is constrained to a fixed/proportional
    /// maximum height with vertical scrolling, preventing long tool sequences from pushing
    /// the final answer off-screen. Set to false by callers that already own the vertical
    /// scroll container (e.g. `WorkflowExecutionTimelineView`).
    private let scrollable: Bool

    /// Initialize from a ChatMessage (existing usage in chat bubbles).
    init(message: ChatMessage, scrollable: Bool = true) {
        self.events = message.timelineEvents
        self.revision = message.timelineRevision
        self.terminalOutcome = message.terminalOutcome
        self.isInterrupted = message.lifecycleState.isInterrupted
        self.conversationID = message.conversationId
        self.isStreaming = message.isStreaming
        self.finalContentText = message.currentAgentContent?.textContent ?? message.content.textContent
        self.streamingContext = StreamingContext(
            startedAt: message.timestamp,
            isStreaming: message.isStreaming
        )
        self.compactReasoning = true
        self.scrollable = scrollable
    }

    /// Initialize from raw timeline events (used by workflow per-node detail views).
    /// - Parameter chatFidelity: When `true`, render with the same compact
    ///   reasoning treatment used in chat bubbles (`InterimReasoningRow` for
    ///   thoughts) and surface the streaming footer when `isStreaming` is true.
    ///   The workflow execution UI passes `true` for the live "currently running"
    ///   node so its in-flight timeline matches what the user sees in chat.
    /// - Parameter streamingStartedAt: Wall-clock start time for the streaming
    ///   footer's elapsed counter. Required when `chatFidelity && isStreaming`;
    ///   ignored otherwise.
    /// - Parameter finalContentText: When the caller renders the final answer
    ///   separately below this timeline (e.g. the workflow node detail view),
    ///   pass it here so a trailing reasoning event that merely repeats the
    ///   answer is deduplicated — same behaviour as the chat-bubble init.
    /// - Parameter conversationID: The chat conversation these events belong to, when there is
    ///   one. Only the capability cards pass it — a plan step's / attempt's nested timeline is
    ///   still IN a chat message, so its file rows need CF-53's destination check exactly as
    ///   much as a top-level row does, and `CapabilityCardRouter` puts most agent runs' tool
    ///   rows there. The workflow per-node callers leave it nil — see the `conversationID`
    ///   property for what nil does and does not mean there.
    /// - Parameter scrollable: When `true`, wraps expanded nodes in an internal scroll container
    ///   capped at `ChatUIConstants.agentTimelineMaxHeight`. Defaults to `false` for raw event
    ///   views since parent containers typically manage their own scrolling.
    init(
        events: [TimelineEvent],
        revision: UInt64 = 0,
        isStreaming: Bool = false,
        chatFidelity: Bool = false,
        streamingStartedAt: Date? = nil,
        finalContentText: String? = nil,
        conversationID: UUID? = nil,
        scrollable: Bool = false
    ) {
        self.events = events
        self.revision = revision
        self.terminalOutcome = nil
        self.isInterrupted = false
        self.conversationID = conversationID
        self.isStreaming = isStreaming
        self.finalContentText = finalContentText
        if chatFidelity, isStreaming, let start = streamingStartedAt {
            self.streamingContext = StreamingContext(startedAt: start, isStreaming: true)
        } else {
            self.streamingContext = nil
        }
        self.compactReasoning = chatFidelity
        self.scrollable = scrollable
    }

    @State private var isTimelineExpanded: Bool = false
    @State private var userToggled: Bool = false
    @State private var timelineContentHeight: CGFloat = 0
    @State private var isHoveringRoot: Bool = false

    private var timelineMaxHeight: CGFloat {
        ChatUIConstants.agentTimelineMaxHeight(forChatFontSize: CGFloat(chatFontSize))
    }

    private var isContentOverflowing: Bool {
        scrollable && timelineContentHeight > timelineMaxHeight
    }

    private func timelineContainerHeight(nodesCount: Int) -> CGFloat {
        let naturalHeight = timelineContentHeight > 0 ? timelineContentHeight : initialEstimatedHeight(for: nodesCount)
        return min(naturalHeight, timelineMaxHeight)
    }

    private func initialEstimatedHeight(for count: Int) -> CGFloat {
        let estimated = CGFloat(count) * 44.0 + (streamingContext?.shouldDisplay == true ? 32.0 : 0.0) + 10.0
        return min(estimated, timelineMaxHeight)
    }

    /// Which tool rows the user has expanded, keyed by the tool event's stable id.
    ///
    /// Deliberately held HERE rather than as `@State` on each row. A row's view identity is
    /// not stable: when a second tool arrives, `buildGroupedNodes` promotes `.action(A)` into
    /// `.actionGroup([A, B])`, which moves `ActionDetailView` to the other branch of the body
    /// switch and hands it fresh structural identity — silently resetting per-row `@State`.
    /// The whole subtree is also torn down when the run ends and `isStreaming` flips. Either
    /// one collapsed a row the user had just opened, which reads as "expanding does nothing".
    /// `data.id` survives both (`ActiveStreamManager` mutates the row in place on completion).
    @State private var expandedRowIDs: Set<UUID> = []

    var body: some View {
        // Grouping is O(n) over up to `ChatMessage.maxTimelineEvents` (500) events —
        // NOT the "< 30" this comment used to assume — and body re-ran on every parent
        // pass, i.e. every streamed token. [TL-4] The chat bubble call site wraps this
        // view in `.equatable()` so body (and this rebuild) is skipped unless the
        // timeline `revision`, streaming flag, or (post-stream) final text changed.
        let nodes = Self.buildGroupedNodes(
            from: events,
            isStreaming: isStreaming,
            finalContentText: finalContentText
        )
        let hasThoughts = nodes.contains {
            if case .thought = $0 { return true }
            return false
        }
        let visibleNodes = Self.filterVisibleNodes(nodes, showThoughts: showThoughts)
        let showFooter = streamingContext?.shouldDisplay ?? false
        // [tc-7] Read ONCE — see the `summary` property. Both the glyph, the tint and the title
        // (which `body` needs twice: the visible `Text` and the `.accessibilityLabel`) come from
        // these two locals.
        let summaryValue = summary
        let titleText = summaryTitle(nodesCount: nodes.count, summary: summaryValue, showThoughts: showThoughts)
        if !nodes.isEmpty || showFooter {
            VStack(alignment: .leading, spacing: 4) {
                // Minimal Antigravity-Style Root Header
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isTimelineExpanded.toggle()
                            userToggled = true
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isStreaming {
                                Circle()
                                    .fill(theme.accentColor)
                                    .frame(width: 6, height: 6)
                                    .frame(width: 14, alignment: .center)
                            } else {
                                Image(systemName: summaryValue.status.glyph)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(summaryTint(for: summaryValue.status))
                                    .frame(width: 14, alignment: .center)
                            }

                            Text(titleText)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundColor(isHoveringRoot ? theme.primaryText : theme.secondaryText)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(isTimelineExpanded ? 90 : 0))
                                .padding(.leading, 1)

                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                        .padding(.horizontal, 2)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isHoveringRoot = hovering
                    }
                    .help(isTimelineExpanded ? String(localized: "Collapse execution log") : String(localized: "Expand execution log"))
                    .accessibilityLabel(
                        "\(titleText). "
                        + (isTimelineExpanded ? String(localized: "Collapse execution log") : String(localized: "Expand execution log"))
                    )

                    // Inline Thoughts toggle (only rendered when there are thoughts in the timeline)
                    if hasThoughts {
                        Button {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                showThoughts.toggle()
                            }
                        } label: {
                            HStack(spacing: 3.5) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9, weight: .medium))
                                Text(showThoughts ? String(localized: "Thoughts: On") : String(localized: "Thoughts: Off"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(showThoughts ? theme.accentColor.opacity(0.14) : theme.surfaceOverlay.opacity(0.4))
                            )
                            .foregroundColor(showThoughts ? theme.accentColor : theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .help(showThoughts ? String(localized: "Hide agent reasoning & thoughts") : String(localized: "Show agent reasoning & thoughts"))
                        .accessibilityLabel(showThoughts ? String(localized: "Hide agent reasoning and thoughts") : String(localized: "Show agent reasoning and thoughts"))
                    }
                }

                // Expanded Nodes Content
                if Self.showsTimelineBody(isTimelineExpanded: isTimelineExpanded,
                                          isStreaming: isStreaming,
                                          userToggled: userToggled) {
                    Group {
                        if scrollable {
                            ScrollViewReader { proxy in
                                ScrollView(.vertical, showsIndicators: isContentOverflowing) {
                                    timelineNodesContent(nodes: visibleNodes)
                                }
                                .frame(height: timelineContainerHeight(nodesCount: visibleNodes.count))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .onChange(of: revision) { _, _ in
                                    if isStreaming {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            if let ctx = streamingContext, ctx.shouldDisplay {
                                                proxy.scrollTo("streaming_footer", anchor: .bottom)
                                            } else if let lastID = visibleNodes.last?.id {
                                                proxy.scrollTo(lastID, anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            timelineNodesContent(nodes: visibleNodes)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            .padding(.vertical, 4)
            .onAppear {
                if !userToggled {
                    isTimelineExpanded = isStreaming
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if !userToggled {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        isTimelineExpanded = streaming
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func timelineNodesContent(nodes: [TimelineNode]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(nodes) { node in
                TimelineNodeGroupView(
                    node: node,
                    compactReasoning: compactReasoning,
                    isStreaming: isStreaming,
                    conversationID: conversationID,
                    expandedRowIDs: $expandedRowIDs
                )
                .id(node.id)
            }
            if let ctx = streamingContext, ctx.shouldDisplay {
                StreamingTimelineFooter(context: ctx)
                    .id("streaming_footer")
                    .transition(.opacity)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.tertiaryText.opacity(0.2))
                .frame(width: 1)
                .padding(.leading, 8.5)
                .padding(.top, 2)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { p in
            p.size.height
        } action: { newHeight in
            timelineContentHeight = newHeight
        }
    }

    /// Whether the execution log's body renders.
    ///
    /// [CF-47] The body used to be gated on `isTimelineExpanded || isStreaming`, so collapsing
    /// DURING a run did nothing at all while the chevron rotated shut and the `.help` and
    /// VoiceOver label both announced it as collapsed — the one control on a live run advertised
    /// an action it would not perform until the run ended. The streaming auto-expand is a
    /// DEFAULT, so it stops applying the moment the user takes the decision themselves. The
    /// alternative (suppress the chevron, help and label while streaming) was rejected: it makes
    /// the control inert instead of making it work.
    ///
    /// `nonisolated static` and pure so the rule is unit-testable; the `@State` plumbing that
    /// sets these three is not.
    nonisolated static func showsTimelineBody(isTimelineExpanded: Bool,
                                              isStreaming: Bool,
                                              userToggled: Bool) -> Bool {
        if userToggled { return isTimelineExpanded }
        // `.onAppear` only runs AFTER the first render, so on that first pass a streaming
        // timeline still has `isTimelineExpanded == false`. `|| isStreaming` is the auto-expand
        // default covering that window; once the user has toggled, it is theirs to decide.
        return isTimelineExpanded || isStreaming
    }

    /// What the collapsed header may claim about a finished run.
    ///
    /// The header is the ONLY thing visible once a run ends — `.onChange(of: isStreaming)`
    /// collapses the body — and it used to hardcode a green `checkmark.circle.fill` plus
    /// "Executed N steps", asserting success for runs where half the tools failed or which
    /// were cancelled outright. The failed rows are red once expanded and `TerminalOutcomeChip`
    /// renders below the content, but neither is inside the collapsed log, so the log itself
    /// was the thing lying.
    ///
    /// `message.terminalOutcome` decides it when the caller has one, and the events decide it
    /// otherwise — the workflow per-node init has no message, and a run with failed tool rows
    /// must still read degraded there.
    enum TimelineSummaryStatus {
        case succeeded, degraded, cancelled
        /// The run never reached a clean finish and never stamped an outcome — a force-quit
        /// mid-run, or a `.parkedHITL` message reloaded and not resumed. Distinct from
        /// `.degraded`, which is a run that DID end and reported how.
        case interrupted

        var glyph: String {
            switch self {
            case .succeeded:   return "checkmark.circle.fill"
            case .degraded:    return "exclamationmark.triangle.fill"
            case .cancelled:   return "slash.circle"
            // Deliberately a CIRCLE, not the triangle `.degraded` uses: the two states sit in
            // the same slot and must stay tellable apart at a glance.
            case .interrupted: return "exclamationmark.circle"
            }
        }
    }

    /// Failed-tool count alongside the status, so the title can say how much went wrong.
    /// `static` + internal for the same reason as `buildGroupedNodes`: it is the part with
    /// logic worth testing directly.
    /// - Parameter isInterrupted: `message.lifecycleState.isInterrupted`. Only consulted when
    ///   `outcome` is nil, because an outcome means the run reached an end and reported it.
    ///   A force-quit reaches neither `finalizeMessage` nor `.executionFinished`, so nothing
    ///   stamps `terminalOutcome` and it restores nil — while `markInterruptedByProcessDeath`
    ///   deliberately writes NOTHING to the abandoned row (resume finds it by `output == nil`),
    ///   so `failed` stays 0 too. Both of those are correct in themselves, and together they
    ///   made `case .completed, nil:` return `.succeeded`: a green checkmark and "Executed 3
    ///   steps" directly above the `InterruptedRunChip` saying the run was cut off. The header
    ///   had no way to know — the view was never handed `lifecycleState`.
    /// ⚠️ [tc-7] Returns `toolCount` as well, so ONE flatten answers every question the header
    /// asks. `summaryTitle` used to run its own second `events.flatMap(\.flattenedIncludingNested)`
    /// for exactly the same count.
    static func summarize(events: [TimelineEvent],
                          outcome: ExecutionOutcome? = nil,
                          isInterrupted: Bool = false) -> (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int) {
        // FLATTENED, not top-level. With Plan & Execute or Reflexion on — most agent runs —
        // `CapabilityCardRouter` routes every tool event into the active step's/attempt's nested
        // array, so the top-level array holds only the card itself and ZERO tool rows. Reading it
        // flat made the header report "Thought for N steps" with a green checkmark for a run in
        // which every tool failed: exactly the blindness CH25 was filed for, in the fix meant to
        // stop the header lying.
        var failed = 0
        var toolCount = 0
        for event in events.flatMap(\.flattenedIncludingNested) {
            guard case .toolExecution(let data) = event else { continue }
            toolCount += 1
            // ⚠️ [tc-4] A SKIPPED `ask_user` is not a failure. `ToolExecutionLoop` yields
            // `.toolFailed(category: .cancelled)` with `isSuccess: didAnswer` == false when the
            // user declines or ignores the prompt, and the run then continues and completes
            // normally. Counting it made the header read "Executed 4 steps (4 tools · 1 failed)"
            // in amber about an event the USER declined — while `ActionDetailView.statusIcon`
            // painted that same row a muted grey `arrow.uturn.left` with no failure capsule.
            // The row and the header disagreed about one event.
            //
            // Narrow on PURPOSE: only `ask_user` AND only the `.cancelled` category. An
            // `ask_user` that failed for any other reason is a real failure, and a cancelled
            // WRITE still counts — the write did not happen. That last point is what keeps
            // CF-46's `testSkippedAskUserDoesNotMakeACompletedRunLookCancelled` green: its
            // `row()` helper builds a `write_file`, so it pins the cancelled-write rule, not
            // this one. CF-46 itself is untouched — it is about never inferring a STOPPED RUN
            // from a per-tool category, which this does not do.
            let isDeclinedPrompt = data.name == "ask_user" && data.failureCategory == .cancelled
            if data.isSuccess == false, !isDeclinedPrompt { failed += 1 }
        }
        // The RUN's own outcome LEADS; the tool-failure count can only escalate from there.
        //
        // [CF-46] It used to be consulted for `.cancelled` alone, so `.failed` and
        // `.completedWithWarnings` fell through to the failure count — and neither produces a
        // failed tool ROW (iteration exhaustion and the circuit breaker end the LOOP, not a
        // tool), so `failed == 0` and the header rendered a green checkmark plus "Executed N
        // steps" directly above the amber TerminalOutcomeChip saying the run didn't finish
        // cleanly. Both map to `.degraded` because that is exactly how the chip treats them —
        // one amber vocabulary for "the answer shipped but the run stopped early".
        //
        // Cancellation likewise comes from the outcome and is never inferred from a tool row:
        // `failureCategory == .cancelled` is also written by `ToolExecutionLoop` when the user
        // skips an `ask_user` prompt ("skip/timeout = cancelled (soft failure, no constraint)"),
        // after which the run continues and finishes — so the old heuristic asserted "Stopped"
        // for a run that completed. Flattening makes those rows MORE visible, not less, so the
        // two changes have to land together.
        switch outcome {
        case .cancelled:
            return (.cancelled, failed, toolCount)
        case .failed, .completedWithWarnings:
            return (.degraded, failed, toolCount)
        case .completed, nil:
            // The outcome still LEADS where there is one; this only fills the gap it leaves.
            if outcome == nil, isInterrupted {
                return (.interrupted, failed, toolCount)
            }
            return (failed > 0 ? .degraded : .succeeded, failed, toolCount)
        }
    }

    /// ⚠️ [tc-7] COMPUTED, and therefore deliberately read EXACTLY ONCE per body pass, into a
    /// local. It was read six times — `summaryStatus`, `summaryTint` (which read
    /// `summaryStatus`), `summaryTitle` twice (the `Text` and the `.accessibilityLabel`), and
    /// `summaryTitle`'s own separate tool-count flatten — each one a fresh recursive flatten of
    /// up to `ChatMessage.maxTimelineEvents` (500) events PLUS every nested capability-card
    /// sub-event. Cheap while streaming (the `isStreaming` ternaries short-circuit and
    /// `summaryTitle` returns early), so the cost landed on conversation load, where every
    /// finalized agent message renders once.
    ///
    /// Do not read this property more than once in `body`, and do not reintroduce a second
    /// flatten anywhere downstream — pass the value.
    private var summary: (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int) {
        Self.summarize(events: events, outcome: terminalOutcome, isInterrupted: isInterrupted)
    }

    private func summaryTint(for status: TimelineSummaryStatus) -> Color {
        switch status {
        case .succeeded: return theme.successColor
        case .degraded:  return theme.warningColor
        case .cancelled: return theme.tertiaryText
        // ⚠️ `warningColor`, matching `InterruptedRunChip` (AgentBubbleContentView), which renders
        // on the NEXT LINE for exactly this state. The register suggested `tertiaryText`; a muted
        // grey beside the chip's amber would have read as two different claims about one run.
        case .interrupted: return theme.warningColor
        }
    }

    private func summaryTitle(nodesCount: Int,
                              summary: (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int),
                              showThoughts: Bool = true) -> String {
        Self.summaryTitle(
            nodesCount: nodesCount,
            summary: summary,
            terminalOutcome: terminalOutcome,
            isStreaming: isStreaming,
            showThoughts: showThoughts
        )
    }

    /// Pure, unit-testable filtering of timeline nodes according to the user's thought-visibility preference.
    static func filterVisibleNodes(_ nodes: [TimelineNode], showThoughts: Bool) -> [TimelineNode] {
        if showThoughts { return nodes }
        let filtered = nodes.filter {
            if case .thought = $0 { return false }
            return true
        }
        // If there are no tool/action nodes (pure narrative run), keep thoughts visible
        // so the expanded timeline doesn't become an empty container.
        return filtered.isEmpty ? nodes : filtered
    }

    /// [tc-7] Takes the ALREADY-COMPUTED summary.
    static func summaryTitle(
        nodesCount: Int,
        summary: (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int),
        terminalOutcome: ExecutionOutcome? = nil,
        isStreaming: Bool = false,
        showThoughts: Bool = true
    ) -> String {
        if isStreaming {
            return String(localized: "Agent is thinking & executing… (\(nodesCount) step\(nodesCount == 1 ? "" : "s"))")
        }

        let status = summary.status
        let failed = summary.failedTools
        let toolCount = summary.toolCount
        let steps = "\(nodesCount) step\(nodesCount == 1 ? "" : "s")"

        // ⚠️ BEFORE the zero-tool early return below. An interrupted run that died before its
        // first tool would otherwise read "Thought for 2 steps" — the same clean-run claim this
        // status exists to stop, just via the other branch.
        if status == .interrupted {
            guard toolCount > 0 else {
                return String(localized: "Interrupted after \(steps)")
            }
            let tools = "\(toolCount) tool\(toolCount == 1 ? "" : "s")"
            return failed > 0
                ? String(localized: "Interrupted after \(steps) (\(tools) · \(failed) failed)")
                : String(localized: "Interrupted after \(steps) (\(tools))")
        }

        guard toolCount > 0 else {
            return String(localized: "Thought for \(nodesCount) step\(nodesCount == 1 ? "" : "s")")
        }

        let tools = "\(toolCount) tool\(toolCount == 1 ? "" : "s")"
        let executionDescriptor = showThoughts ? "\(steps) (\(tools))" : "\(tools)"

        switch status {
        case .succeeded:
            return String(localized: "Executed \(executionDescriptor)")
        case .degraded:
            let descriptor = showThoughts ? "\(steps) (\(tools)" : "\(tools)"
            if terminalOutcome == .failed {
                return failed > 0
                    ? String(localized: "Ended early after \(descriptor) · \(failed) failed)")
                    : String(localized: "Ended early after \(descriptor))")
            }
            if terminalOutcome == .completedWithWarnings {
                return failed > 0
                    ? String(localized: "Completed with warnings after \(descriptor) · \(failed) failed)")
                    : String(localized: "Completed with warnings after \(descriptor))")
            }
            return failed > 0
                ? String(localized: "Executed \(executionDescriptor) · \(failed) failed")
                : String(localized: "Executed \(executionDescriptor)")
        case .cancelled:
            let descriptor = showThoughts ? "\(steps) (\(tools)" : "\(tools)"
            return failed > 0
                ? String(localized: "Stopped after \(descriptor) · \(failed) failed)")
                : String(localized: "Stopped after \(descriptor))")
        case .interrupted:
            return String(localized: "Interrupted after \(steps) (\(tools))")
        }
    }

    /// Tool calls that only OBSERVE a background task. Deliberately NOT including
    /// `stop_background_task`: that one CHANGES state, and an action the user took (or the agent took on
    /// their behalf) should stay visible even when its outcome is also on the card. Hide
    /// observations, keep actions.
    private static let backgroundPollTools: Set<String> = ["get_task_output", "command_output"]

    /// Drops poll rows for tasks that already have a `.backgroundTask` card.
    ///
    /// ⚠️ Device test 2026-09-21: asked to "check on it periodically", the model produced NINE
    /// `command_status` calls in ~40 seconds — one every few seconds, because nothing lets it
    /// wait. (2026-09-23: it did it TWENTY times and hit the iteration cap; `command_status` has
    /// since been withdrawn and the polls now arrive as `command_output`, which this folds.) Each was an ordinary tool execution, so the timeline showed nine identical
    /// "Command bg_1" rows above a card that was already displaying the same status live.
    ///
    /// Folded in the VIEW, not at the source: the events stay in `timelineEvents`, so episodic
    /// history, resume reconstruction and export are unaffected. This is presentation — the polls
    /// really happened and the record should still say so.
    ///
    /// ⚠️ Only when a card EXISTS for that task. A task adopted with no live stream has no card,
    /// and hiding its polls too would leave the user with nothing at all.
    static func foldBackgroundTaskPolls(_ events: [TimelineEvent]) -> [TimelineEvent] {
        let carded: Set<String> = Set(events.compactMap {
            if case .backgroundTask(let data) = $0 { return data.taskID }
            return nil
        })
        guard !carded.isEmpty else { return events }

        return events.filter { event in
            guard case .toolExecution(let data) = event,
                  backgroundPollTools.contains(data.name) else { return true }
            // A `command_output` with no `task_id` is the list-everything form; with a card on
            // screen it is the same noise, so it folds too.
            guard let id = taskID(inParams: data.params) else { return false }
            return !carded.contains(id)
        }
    }

    /// ⚠️ PARSED, not substring-matched. `params.contains("bg_1")` would also fire on a
    /// `batch_command` whose COMMAND text happened to mention a task id, folding a row that is
    /// not a poll at all — the shape-matching class of defect this codebase has already paid for
    /// four times.
    private static func taskID(inParams params: String) -> String? {
        guard let data = params.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["task_id"] as? String
    }

    /// Builds grouped timeline nodes from raw events.
    /// Homogeneous / heterogeneous tool runs of size 2+ collapse into `.actionGroup`.
    /// Single tools render as `.action` (no collapsible header).
    /// `ask_user` always renders as `.action` (interactive moments shouldn't hide in a group).
    static func buildGroupedNodes(
        from events: [TimelineEvent],
        isStreaming: Bool,
        finalContentText: String? = nil
    ) -> [TimelineNode] {
        var events = events

        // Pass 0: Strip redundant or obsolete infrastructure progress thoughts
        // ("Model loaded. Starting execution…", "Preparing agent tools…")
        events.removeAll { event in
            switch event {
            case .thought(_, let text), .reasoning(_, let text):
                return isRedundantSystemText(text)
            default:
                return false
            }
        }

        // Deduplication pass 1: if not streaming and last event is narrative
        // (thought/reasoning), hide it — it usually duplicates the final outcome
        // shown immediately below.
        //
        // ⚠️ [tc-11] Gated on there BEING a final outcome below. This pass used to run
        // unconditionally, so when the bubble had no answer to duplicate it deleted the only
        // record of what the agent had been doing. Reachable three ways, and the workflow one is
        // the strongest: a `.skipped` or cancelled node renders its timeline with no final text
        // at all, so the user's last "why" vanished with it. A `.stoppedRunPlaceholder` is not an
        // answer either — it is the synthetic marker for a run that produced nothing, which is
        // exactly when the narrative is all there is.
        //
        // Deliberately NOT a containment test ("is the thought a prefix of the answer?"): that
        // would also stop dropping the trailing system-status thought ("Composing final
        // response…") this pass exists to hide, which pass 2's equality test cannot catch.
        // `isSyntheticPlaceholder` rather than two inline comparisons — it already owns both
        // placeholder spellings (and its own exact-match-after-trim rule), so a third can never
        // be added without this gate learning about it.
        let hasFinalAnswerBelow: Bool = {
            guard let final = finalContentText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !final.isEmpty else { return false }
            return !ChatMessage.isSyntheticPlaceholder(final)
        }()
        if !isStreaming, hasFinalAnswerBelow, let last = events.last {
            switch last {
            case .thought, .reasoning:
                events.removeLast()
            default:
                break
            }
        }

        // Deduplication pass 2: strip any narrative event whose text exactly
        // matches the final content. Catches the single-iter genuine-completion
        // case where the model's reasoning IS the final answer — without this,
        // the same 60-character response appears twice (once in the timeline,
        // once as the bubble's main content). Pass 1's "last event" rule doesn't
        // catch it because a trailing `.thought("Composing final response…")`
        // gets emitted after the reasoning.
        if !isStreaming,
           let finalText = finalContentText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !finalText.isEmpty {
            events.removeAll { event in
                switch event {
                case .thought(_, let text), .reasoning(_, let text):
                    return text.trimmingCharacters(in: .whitespacesAndNewlines) == finalText
                default:
                    return false
                }
            }
        }

        // Pass 3: Merge consecutive short-status thoughts into one row. System-level
        // infrastructure progress ("Connecting to Ollama…", "Model loaded…",
        // "Preparing agent tools…") is emitted as individual `.thought` events,
        // each short (< 100 chars, no newlines). Left alone, these stack as 3+
        // separate rows dominating the top of every bubble. Merged, they become
        // one compact progress line joined with " · ". Real model narratives are
        // long / multiline and fall outside this rule.
        events = collapseShortStatusRuns(events)

        // Pass 4: fold away the polls on a background task that already has a card.
        events = foldBackgroundTaskPolls(events)

        var nodes: [TimelineNode] = []
        var pendingActions: [TimelineEvent] = []

        func flushActions() {
            if pendingActions.isEmpty { return }
            if pendingActions.count == 1 {
                nodes.append(.action(pendingActions[0]))
            } else {
                nodes.append(.actionGroup(pendingActions))
            }
            pendingActions = []
        }

        for event in events {
            switch event {
            case .thought(let id, let text):
                flushActions()
                if isRedundantSystemText(text) {
                    break
                }
                if isSystemStatusText(text) {
                    nodes.append(.status(id: id, text: text))
                } else {
                    nodes.append(.thought(id: id, text: text))
                }

            case .reasoning(let id, let text):
                // Reasoning reuses the `.thought` timeline node for identical visual
                // treatment. The semantic split lives at the TimelineEvent layer so
                // analytics / scratchpad paths can distinguish model vs. system prose.
                flushActions()
                if isRedundantSystemText(text) {
                    break
                }
                if isSystemStatusText(text) {
                    nodes.append(.status(id: id, text: text))
                } else {
                    nodes.append(.thought(id: id, text: text))
                }

            case .toolExecution(let data):
                if data.name == "ask_user" {
                    // Interactive — never hide inside a group; surface as its own row.
                    flushActions()
                    nodes.append(.action(event))
                } else {
                    pendingActions.append(event)
                }

            case .mediaGeneration:
                pendingActions.append(event)

            case .backgroundTask(let data):
                // Never grouped. A grouped row collapses to a one-line summary, and this is the
                // only place a running task is visible at all — the tool call that started it
                // returned long ago.
                flushActions()
                nodes.append(.backgroundCard(data))

            case .unknown(let id, let caseName, _):
                flushActions()
                nodes.append(.unrecognized(id: id, caseName: caseName))

            case .capabilityMilestone(let id, let kind, let detail):
                flushActions()
                nodes.append(.capabilityMilestone(id: id, kind: kind, detail: detail))

            case .warning(let id, let category, let text):
                flushActions()
                nodes.append(.warning(id: id, category: category, text: text))

            case .planExecution(let data):
                flushActions()
                nodes.append(.planCard(data))

            case .reflectionRun(let data):
                flushActions()
                nodes.append(.reflectionCard(data))
            }
        }

        flushActions()
        return nodes
    }

    /// Collapses runs of ≥2 short-status `.thought` / `.reasoning` events into a
    /// single event whose text joins the items with " · ". Events outside the
    /// run pass through untouched. See call site for rationale.
    private static func collapseShortStatusRuns(_ events: [TimelineEvent]) -> [TimelineEvent] {
        var out: [TimelineEvent] = []
        var run: [(id: UUID, text: String)] = []

        func flush() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                out.append(.thought(id: run[0].id, text: run[0].text))
            } else {
                let merged = run.map(\.text).joined(separator: " · ")
                out.append(.thought(id: run[0].id, text: merged))
            }
            run.removeAll()
        }

        for event in events {
            switch event {
            case .thought(_, let text), .reasoning(_, let text):
                if isRedundantSystemText(text) {
                    continue
                }
            default:
                break
            }

            let shortStatus: (UUID, String)? = {
                switch event {
                case .thought(let id, let text) where isShortStatusText(text) && !isSystemStatusText(text):
                    return (id, text)
                case .reasoning(let id, let text) where isShortStatusText(text) && !isSystemStatusText(text):
                    return (id, text)
                default:
                    return nil
                }
            }()
            if let s = shortStatus {
                run.append(s)
            } else {
                flush()
                out.append(event)
            }
        }
        flush()
        return out
    }

    private static func isShortStatusText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= 100 && !trimmed.contains("\n")
    }

    private static func isSystemStatusText(_ text: String) -> Bool {
        guard !isRedundantSystemText(text) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("Connecting to Ollama:")
            || trimmed.hasPrefix("Loading local model:")
            || trimmed.hasPrefix("Connecting to ")
            || trimmed.hasPrefix("Connecting…")
            || (isShortStatusText(text) && (trimmed.contains("Connecting to Ollama") || trimmed.contains("Loading local model")))
    }

    private static func isRedundantSystemText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("Model loaded")
            || trimmed.contains("Preparing agent tools")
            || trimmed.contains("Preparing tools")
    }
}

// MARK: - Models

enum TimelineNode: Identifiable {
    case thought(id: UUID, text: String)
    /// System infrastructure status (e.g. Connecting to Ollama, model initialization).
    /// Rendered as a simple status line rather than an interim model reasoning block.
    case status(id: UUID, text: String)
    /// A single tool invocation rendered inline (no collapsible header).
    case action(TimelineEvent)
    /// Two or more tool invocations collapsed into a header + expandable detail list.
    case actionGroup([TimelineEvent])
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)
    case warning(id: UUID, category: WarningCategory, text: String)
    /// Structured Plan & Execute card (step checklist with nested sub-timelines).
    case backgroundCard(BackgroundTaskData)
    case planCard(PlanRunData)
    /// Structured Reflexion card (attempt rows with nested sub-timelines).
    case reflectionCard(ReflectionRunData)
    /// An event a NEWER build wrote that this build has no renderer for.
    ///
    /// ⚠️ Rendered, not hidden. Silently dropping it makes the timeline under-report what the run
    /// actually did — and if the unrecognised event is a capability card, its whole nested
    /// sub-timeline vanishes with no indication anything is missing. A visible row is the only
    /// honest option: the data IS preserved on disk, this build just cannot draw it.
    case unrecognized(id: UUID, caseName: String)

    var id: UUID {
        switch self {
        case .thought(let id, _):              return id
        case .status(let id, _):               return id
        case .action(let e):                   return e.id
        case .actionGroup(let a):              return a.first?.id ?? UUID()
        case .capabilityMilestone(let id, _, _): return id
        case .warning(let id, _, _):           return id
        case .backgroundCard(let data):        return data.id
        case .planCard(let data):              return data.id
        case .reflectionCard(let data):        return data.id
        case .unrecognized(let id, _):         return id
        }
    }
}

// MARK: - Subviews

struct TimelineNodeGroupView: View {
    let node: TimelineNode
    /// When true, thought/reasoning nodes render in a muted compact row.
    /// See `AgentTimelineView.compactReasoning` for the rationale.
    var compactReasoning: Bool = false
    /// Threaded to capability cards so their live indicators (ticking elapsed,
    /// auto-expanded running step) only run while the message is streaming.
    var isStreaming: Bool = false
    /// The owning conversation, forwarded to `ActionDetailView` for CF-53's destination check.
    /// nil when the caller supplied none — see `AgentTimelineView.conversationID`.
    var conversationID: UUID? = nil
    /// Owned by `AgentTimelineView` — see the declaration there for why a row's
    /// disclosure cannot live in the row.
    @Binding var expandedRowIDs: Set<UUID>

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true

    @State private var isHoveringHeader = false

    var body: some View {
        switch node {
        case .thought(_, let text):
            // Chat/code bubbles render the final answer as separate main content
            // below the timeline, so any thought that survives dedup is *interim*
            // reasoning between tool calls. Models like qwen-coder emit full-response-
            // sized narratives before each tool call ("Project Analysis Summary…"
            // with h1s and bullet lists), which visually competes with the real
            // final answer. InterimReasoningRow de-emphasises these so the final
            // answer stays the clear focus.
            //
            // Workflow per-node views (compactReasoning == false) keep the full
            // markdown — their "thought" often IS the node's output.
            if compactReasoning {
                // [CF-49] `isLive` gates the sparkle's repeating pulse. Without it a reasoning
                // row in a run that finished last week held a Core Animation loop forever.
                InterimReasoningRow(text: text, isLive: isStreaming)
            } else {
                WorkflowMarkdownView(text: text)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .status(_, let text):
            SystemStatusRow(text: text)

        case .capabilityMilestone(_, let kind, let detail):
            CapabilityMilestoneRow(kind: kind, detail: detail)

        case .warning(_, let category, let text):
            WarningRow(category: category, text: text)

        case .unrecognized(_, let caseName):
            UnrecognizedEventRow(caseName: caseName)

        case .backgroundCard(let data):
            BackgroundTaskCard(data: data, conversationID: conversationID)

        case .planCard(let data):
            PlanProgressCard(data: data, isStreaming: isStreaming, conversationID: conversationID)

        case .reflectionCard(let data):
            ReflectionAttemptsCard(data: data, isStreaming: isStreaming, conversationID: conversationID)

        case .action(let event):
            ActionDetailView(event: event,
                             originConversationID: conversationID,
                             expandedRowIDs: $expandedRowIDs,
                             isStandalone: true)

        case .actionGroup(let actions):
            VStack(alignment: .leading, spacing: 2) {
                // Group header (clean Antigravity-style)
                Button {
                    if reduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(generateGroupTitle(actions))
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundColor(isHoveringHeader ? theme.primaryText : theme.secondaryText)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .padding(.leading, 1)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 2.5)
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isHoveringHeader = hovering
                }

                if isExpanded {
                    let requiresSubScroll = actions.count > 5
                    let subScrollMaxHeight: CGFloat = 220

                    Group {
                        if requiresSubScroll {
                            ScrollView(.vertical, showsIndicators: true) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(actions) { action in
                                        ActionDetailView(event: action,
                                                         originConversationID: conversationID,
                                                         expandedRowIDs: $expandedRowIDs,
                                                         isStandalone: false)
                                    }
                                }
                                .padding(.trailing, 4)
                                .padding(.vertical, 1)
                            }
                            .frame(maxHeight: subScrollMaxHeight)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(actions) { action in
                                    ActionDetailView(event: action,
                                                     originConversationID: conversationID,
                                                     expandedRowIDs: $expandedRowIDs,
                                                     isStandalone: false)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                    }
                    .padding(.leading, 14)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Builds a Claude-Code-style group title by bucketing tool invocations by name,
    /// then rendering "<primary bucket>, <minor>, <minor>..." with natural pluralization.
    /// Mixed groups: "Read 6 files, edited 2 files, used a tool".
    private func generateGroupTitle(_ actions: [TimelineEvent]) -> String {
        guard !actions.isEmpty else { return String(localized: "Action Group") }

        // Bucket tool executions by tool name; ignore media here (titled separately if only media).
        var buckets: [(name: String, count: Int)] = []
        var bucketIndex: [String: Int] = [:]
        for action in actions {
            if case .toolExecution(let data) = action {
                if let i = bucketIndex[data.name] {
                    buckets[i].count += 1
                } else {
                    bucketIndex[data.name] = buckets.count
                    buckets.append((name: data.name, count: 1))
                }
            }
        }

        guard !buckets.isEmpty else {
            // Media-only group fallback
            return "Produced \(actions.count) artifact\(actions.count == 1 ? "" : "s")"
        }

        // Sort by count desc, keep stable ordering by original insertion for ties.
        let sortedBuckets = buckets.enumerated()
            .sorted { a, b in
                if a.element.count != b.element.count { return a.element.count > b.element.count }
                return a.offset < b.offset
            }
            .map(\.element)

        var segments: [String] = []
        for (idx, bucket) in sortedBuckets.enumerated() {
            let verb = ToolArgFormatter.verb(tool: bucket.name)
            let object = ToolArgFormatter.objectLabel(tool: bucket.name, plural: bucket.count)
            let segment: String
            if idx == 0 {
                segment = bucket.count == 1 ? "\(verb) \(object)" : "\(verb) \(bucket.count) \(object)"
            } else {
                let lowerVerb = verb.lowercased()
                segment = bucket.count == 1 ? "\(lowerVerb) a \(object)" : "\(lowerVerb) \(bucket.count) \(object)"
            }
            segments.append(segment)
            if segments.count >= 4 { break }
        }
        return segments.joined(separator: ", ")
    }
}

// MARK: - Action Detail Row

/// What a file-touching tool row can open in the Code Viewer. File-scope (not view-nested)
/// so the resolution semantics — especially append mode — are unit-testable.
struct TimelineFileViewerAction: Equatable {
    let fileName: String
    /// Absolute path of the file this row touched. Identity for tab reuse (a bare basename
    /// collides across directories) and the read source for `.fromDisk` rows.
    let filePath: String
    /// Where the viewer gets the content.
    ///
    /// `.inline` — the params already carry the exact bytes (the write tools). Params are
    /// not size-capped, so this is faithful.
    /// `.fromDisk` — read the file at click time. Required for `read_file`, whose content
    /// would otherwise come from `ToolExecutionData.output`, which IS capped
    /// (`maxPersistedOutputLength`) and additionally carries a decorative header — so a
    /// large file would open truncated, with the marker embedded in the code.
    enum ContentSource: Equatable {
        case inline(String)
        case fromDisk
    }
    let source: ContentSource
    let preWriteContent: String?
    let isWrite: Bool

    /// The content when it is already known; nil when a disk read is required.
    var inlineContent: String? {
        if case .inline(let text) = source { return text }
        return nil
    }

    /// Successful `write_file` / `overwrite_file` / `create_new_file` rows open the
    /// POST-WRITE file (with a pre-write diff when the snapshot was captured); successful
    /// `read_file` rows open what the agent read.
    ///
    /// APPEND MODE is the trap this exists to handle: `write_file` with the append flag
    /// carries only the appended FRAGMENT in `content` — treating it as the file produced
    /// a diff claiming the entire file was deleted and one line added. The post-write file
    /// is snapshot + fragment; without the snapshot it can't be represented faithfully,
    /// so the row gets NO affordance rather than a lying one.
    /// Tools that SHOULD produce a chip. Anything else legitimately has none, so its nil
    /// return stays silent — logging every `execute_shell` row would drown the signal.
    /// ⚠️ `create_file` and `edit_code` belong here alongside `write_file`, and their absence was
    /// an oversight rather than a policy. All three are `.libraryExceptCode` in
    /// `NativeToolCatalog` — the file-editing tools a CHAT or WORKFLOW profile gets, superseded
    /// only when the Library is opened for a Code profile — and `write_file` was already listed.
    /// Without them, `TimelineFileViewerAction.resolve` returned nil, so `ActionEffect.from`
    /// produced nil too: a chat-profile file write got no `+N −M`, no "Previous version", and no
    /// PERSISTED `ActionEffect` — the record that exists precisely because the model cannot
    /// reconstruct a file it has already overwritten.
    /// Exposed for the drift test that ties this to `SnapshotToolContract` — see its doc.
    static var chipEligibleToolsForTesting: Set<String> { chipEligibleTools }

    private static let chipEligibleTools: Set<String> = [
        "write_file", "overwrite_file", "create_new_file", "create_file",
        "edit_code_single", "edit_code_batch", "edit_code", "read_file"
    ]

    /// What to do with an append whose pre-write snapshot is missing — the one case where
    /// the timeline chip and episodic memory need OPPOSITE defaults.
    enum MissingBaselinePolicy {
        /// No affordance. The post-write file is snapshot + fragment; without the snapshot,
        /// opening the fragment as though it were the file is a lying affordance.
        case skipAction
        /// Record the fragment with no baseline. Memory's failure mode is the reverse of the
        /// viewer's: an unrecorded write reads as "nothing happened", which is precisely the
        /// amnesia `<effect>` exists to fix. `ActionEffect.from` renders it `baseline="none"`.
        case recordFragment
    }

    /// [tc-8] String-driven form — parses, then delegates.
    static func resolve(data: ToolExecutionData,
                        missingBaseline: MissingBaselinePolicy = .skipAction) -> TimelineFileViewerAction? {
        resolve(data: data, params: parsedParams(data.params), missingBaseline: missingBaseline)
    }

    /// [tc-8] The form that takes an ALREADY-PARSED params dictionary — see
    /// `ToolArgFormatter.primaryLabel(tool:dict:)` for why.
    ///
    /// ⚠️ `params` is OPTIONAL, not a plain dictionary: nil means "the params were not decodable
    /// JSON", which is a different diagnostic from "decoded fine but carried no path" and the two
    /// `skip` reasons below must keep saying which happened.
    static func resolve(data: ToolExecutionData,
                        params: [String: Any]?,
                        missingBaseline: MissingBaselinePolicy = .skipAction) -> TimelineFileViewerAction? {
        // Not a file tool — no chip expected, nothing to explain.
        guard chipEligibleTools.contains(data.name) else { return nil }

        // Past this point every nil is a FILE tool that failed to get a chip, which is
        // exactly the "why is the button missing?" question on-device. Each exit says why.
        func skip(_ reason: String) -> TimelineFileViewerAction? {
            timelineLogger.info("[CodeViewer] No viewer chip for '\(data.name)' [\(data.id.uuidString.prefix(8))] — \(reason).")
            return nil
        }

        // In-flight or failed rows have no chip by design; the row's own status shows why.
        guard data.isSuccess == true, !data.isExecuting else { return nil }

        guard let params else {
            return skip("tool params are not decodable JSON, so the target file is unknown")
        }
        // Both spellings exist: native tools take `path`, split tools `file_path`.
        guard let rawPath = (params["path"] as? String) ?? (params["file_path"] as? String),
              !rawPath.isEmpty else {
            return skip("no 'path'/'file_path' argument — nothing to open")
        }
        // MUST match how the executor resolved it. `expandingTildeInPath` expands `~` but
        // leaves a RELATIVE path untouched, and `URL(fileURLWithPath:)` then anchors that to
        // the PROCESS working directory — `/` for a GUI-launched app. The write tools go
        // through `FilePathResolver`, which anchors relative paths to HOME; the viewer did
        // not, so a model emitting `Notes.java` produced a tab pointing at `/Notes.java`
        // while the agent had written `~/Notes.java`.
        let filePath = FilePathResolver.resolve(rawPath)
        let fileName = (filePath as NSString).lastPathComponent

        switch data.name {
        // `create_file` carries `{file_path, content, overwrite?}` — the same full-post-state
        // shape as these three. It has no append mode, so the `isAppendMode` branch below stays
        // `write_file`-only.
        case "write_file", "overwrite_file", "create_new_file", "create_file":
            guard let content = params["content"] as? String, !content.isEmpty else {
                return skip("write to '\(fileName)' carried no 'content' argument")
            }
            if data.name == "write_file", isAppendMode(params) {
                guard let pre = data.preWriteContent else {
                    guard missingBaseline == .recordFragment else {
                        return skip("append to '\(fileName)' has no pre-write snapshot, so the post-write file can't be reconstructed (file was unreadable or over the snapshot cap at capture time)")
                    }
                    // The fragment IS what was added, so `linesAdded` downstream is exact and
                    // `removed: 0` is genuinely true rather than a placeholder — an append
                    // removes nothing. It still renders `baseline="none"` because the XML has
                    // no append marker, so the model cannot tell this apart from an overwrite
                    // and would read a placeholder zero as measured. Under-claiming is the
                    // safe direction; the alternative recorded nothing at all.
                    return TimelineFileViewerAction(
                        fileName: fileName,
                        filePath: filePath,
                        source: .inline(content),
                        preWriteContent: nil,
                        isWrite: true
                    )
                }
                return TimelineFileViewerAction(
                    fileName: fileName,
                    filePath: filePath,
                    source: .inline(pre + content),
                    preWriteContent: pre,
                    isWrite: true
                )
            }
            return TimelineFileViewerAction(
                fileName: fileName,
                filePath: filePath,
                source: .inline(content),
                preWriteContent: data.preWriteContent,
                isWrite: true
            )
        // `edit_code` is the superseded original of these two and carries the same
        // `{file_path, edits | old_string+new_string}` shape, so it needs the same read-back.
        case "edit_code_single", "edit_code_batch", "edit_code":
            // Edit params carry only find/replace strings — the post-state comes from the
            // executor's read-back. Without it the change can't be represented: no chip.
            guard let post = data.postWriteContent, !post.isEmpty else {
                return skip("edit of '\(fileName)' has no post-write read-back, so its result can't be shown (file unreadable or over the snapshot cap after the edit)")
            }
            return TimelineFileViewerAction(
                fileName: fileName,
                filePath: filePath,
                source: .inline(post),
                preWriteContent: data.preWriteContent,
                isWrite: true
            )
        case "read_file":
            // Deliberately NOT `data.output`: that is capped and header-decorated. Read the
            // file itself at click time instead.
            guard data.output?.isEmpty == false else {
                return skip("read of '\(fileName)' produced no output — treating it as nothing to open")
            }
            return TimelineFileViewerAction(
                fileName: fileName,
                filePath: filePath,
                source: .fromDisk,
                preWriteContent: nil,
                isWrite: false
            )
        default:
            return nil
        }
    }

    /// Mirrors `WriteFileTool`'s own append decoding: any of its alias keys, as a Bool
    /// or a Bool-coercible string. (JSONSerialization bridges JSON booleans — and 0/1
    /// numbers — to `Bool` via NSNumber, which `as? Bool` handles.)
    private static func isAppendMode(_ params: [String: Any]) -> Bool {
        for key in ["append", "isAppend", "shouldAppend", "appending"] {
            if let flag = params[key] as? Bool { return flag }
            if let string = params[key] as? String, let flag = Bool(string.lowercased()) { return flag }
        }
        return false
    }

    private static func parsedParams(_ params: String) -> [String: Any]? {
        guard let data = params.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// `.task(id:)` key for chip resolution — the row must re-resolve when the tool finishes,
/// not just when a different event takes its place. Completion is also the ONLY place
/// `params` is rewritten (`completeToolTimelineEvent` / `CapabilityCardRouter.completeTool`
/// assign `params` and flip `isExecuting` in the same mutation), so a cache keyed on this
/// is also a cache keyed on the params. Internal, not private, so the cache rule in
/// `ActionDetailView.primaryArgLabel` can be unit-tested.
struct TimelineChipKey: Equatable {
    let id: UUID
    let isExecuting: Bool
    let isSuccess: Bool?
}

struct ActionDetailView: View {
    let event: TimelineEvent
    /// The conversation this row was rendered for, when the caller supplied one. `openInViewer`
    /// compares it against the view model's current conversation AFTER its disk read returns
    /// (CF-53). A nil falls back to the switch-in-flight term of `shouldDeliverOpen`, not to
    /// "always deliver".
    var originConversationID: UUID? = nil
    @Environment(\.appTheme) private var theme
    /// Optional lookup: contexts that render timelines without a chat VM in the
    /// environment simply show no Code Viewer chip instead of crashing.
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?
    /// Disclosure lives in `AgentTimelineView`, keyed by `data.id` — per-row `@State` was
    /// being reset out from under the user by view-identity churn.
    @Binding var expandedRowIDs: Set<UUID>
    /// When true, the row is rendered standalone at the top level of the timeline
    /// with card styling matching interim reasoning thoughts.
    var isStandalone: Bool = false
    @State private var isHovering: Bool = false
    /// "+N −M" for successful writes with a pre-write snapshot; computed off-main once.
    @State private var writeDiffStat: (added: Int, deleted: Int)? = nil

    /// Neither of the next two values is resolved in `body`: each JSON-parses the tool
    /// params — the FULL params string, which for `write_file` / `create_new_file` is the
    /// whole file, and is never capped — and a body-side call re-parsed it once per row per
    /// render pass across the whole timeline, on the main actor, for every stream event.
    /// Both are resolved once per row in `.task(id: TimelineChipKey)` (`resolveChip`) and
    /// cached here. (`ToolArgFormatter.primaryLabel` did exactly the forbidden thing at the
    /// row label until CF-45, a few lines below this rule.)
    @State private var resolvedAction: TimelineFileViewerAction?
    /// The row's primary-argument label, with the key it was resolved for. Read through
    /// `primaryArgLabel(cached:for:tool:params:)`, which falls back to a fresh parse on a
    /// key mismatch — so the first pass (before `.task` runs) and the one pass after the
    /// completion rewrite of `params` still render, at one parse each, and a recycled row
    /// identity can never show the previous row's label.
    @State private var primaryArgCache: (key: TimelineChipKey, label: String)?
    /// True while a `.fromDisk` row is being read after a click.
    @State private var isOpeningFromDisk = false
    /// Why the last "Open in viewer" failed, rendered under the row. `.fromDisk` is the ONLY
    /// route a `read_file` row offers (`TimelineFileViewerAction.resolve` deliberately refuses
    /// `data.output`), so a silent failure left the user with no affordance and no explanation
    /// — the spinner simply stopped. Every other error surface in this cluster renders
    /// something; this one rendered nothing.
    @State private var openFailureReason: String?

    private func rowDetail(_ data: ToolExecutionData) -> TimelineRowDetail? {
        TimelineRowDetail.resolve(data)
    }

    private func isOutputExpanded(_ data: ToolExecutionData) -> Bool {
        expandedRowIDs.contains(data.id)
    }

    /// Always-visible pills for a file-touching row: the change stat, an inline diff, and
    /// the affordances that open content in the Code Viewer.
    ///
    /// Deliberately split into TWO sources. `data.effect` is PERSISTED and self-sufficient
    /// (path, counts, diff), so the stat and the diff render from it alone. Everything that
    /// needs actual file CONTENT — "Previous version", "Open in viewer" — needs
    /// `resolvedAction`, which reads the SESSION-SCOPED snapshots and is nil after a reload.
    /// Gating the whole block on `resolvedAction` made the persisted diff unreachable for
    /// `edit_code_*` and append rows on any reloaded conversation, defeating the point of
    /// persisting it (found by the 2026-07-26 re-scope audit).
    @ViewBuilder
    private func fileViewerChip(data: ToolExecutionData) -> some View {
        let effect = data.effect
        let isNoOpWrite: Bool = {
            if let effect { return effect.linesAdded == 0 && effect.linesRemoved == 0 }
            return writeDiffStat.map { $0.added == 0 && $0.deleted == 0 } ?? false
        }()
        let stat: (added: Int, deleted: Int)? = effect.map { ($0.linesAdded, $0.linesRemoved) } ?? writeDiffStat
        // A persisted effect with `diff == nil` came from `ActionEffectBuilder`'s no-baseline
        // branch: the file was over `preWriteSnapshotByteLimit` (512 KB) or wasn't readable as
        // UTF-8 when the snapshot was taken. Its `linesRemoved: 0` is a PLACEHOLDER, not a
        // measurement — printing "+N −0" made a destructive overwrite of an 800 KB file look
        // exactly like creating a new one. `writeDiffStat` is always measured against a real
        // pre-image, so it stays trusted.
        let hasBaseline: Bool = effect.map { $0.diff != nil } ?? true

        if effect != nil || resolvedAction != nil {
            HStack(spacing: 5) {
                if let stat {
                    if isNoOpWrite {
                        Text(String(localized: "No changes"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                    } else if !hasBaseline {
                        Text(String(localized: "Wrote \(stat.added) lines"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.tertiaryText)
                            .help(String(localized: "The file couldn't be captured before the write (too large, or not readable as text), so what this replaced can't be shown."))
                            .accessibilityLabel(String(localized: "Wrote \(stat.added) lines; no baseline, so the replaced content is unknown"))
                    } else {
                        HStack(spacing: 2) {
                            Text("+\(stat.added)").foregroundColor(theme.successColor)
                            Text("−\(stat.deleted)").foregroundColor(theme.errorColor)
                        }
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    }
                }

                // Recovery path — a pure viewer use. Needs the session-scoped snapshot,
                // so it is simply absent after a reload rather than misleading.
                if let viewModel = chatHistoryViewModel, let action = resolvedAction,
                   !isNoOpWrite, let pre = action.preWriteContent {
                    Button {
                        viewModel.openTimelineFileInCodeViewer(
                            fileName: action.fileName,
                            filePath: nil,
                            content: pre
                        )
                    } label: {
                        Text(String(localized: "Previous"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(theme.surfaceOverlay.opacity(0.5)))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Open this file as it was before the change"))
                    .accessibilityLabel(String(localized: "Open previous version in code viewer"))
                }

                // Reads open in the viewer — that is what it is for.
                if let viewModel = chatHistoryViewModel, let action = resolvedAction,
                   !action.isWrite {
                    Button {
                        openInViewer(action, viewModel: viewModel, preWriteContent: nil)
                    } label: {
                        HStack(spacing: 2) {
                            if isOpeningFromDisk {
                                ProgressView().controlSize(.mini).scaleEffect(0.6)
                            }
                            Text(String(localized: "Open"))
                                .font(.system(size: 9.5, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(theme.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isOpeningFromDisk)
                    .help(String(localized: "Open the file the agent read"))
                    .accessibilityLabel(String(localized: "Open in code viewer"))
                }
            }
        }
    }

    /// The change this row made, rendered where the change happened.
    ///
    /// Reads `ToolExecutionData.effect`, which is derived ONCE at tool completion and
    /// persisted — so this survives a relaunch, and it is the SAME value the agent has in
    /// episodic memory. The row and the model can therefore never describe a write
    /// differently, which they could if this recomputed its own diff.
    @ViewBuilder
    private func inlineDiff(_ effect: ActionEffect) -> some View {
        if let diff = effect.diff {
            ViewThatFits(in: .vertical) {
                diffLines(diff: diff, isTruncated: effect.isTruncated)

                ScrollView(.vertical, showsIndicators: true) {
                    diffLines(diff: diff, isTruncated: effect.isTruncated)
                }
                .frame(height: 200)
            }
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surfaceOverlay.opacity(0.35)))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.accentColor.opacity(0.4))
                    .frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private func diffLines(diff: String, isTruncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                diffLine(line)
            }
            if isTruncated {
                // Never let a partial change read as the whole one.
                Text(String(localized: "Diff truncated — open the previous version to see everything."))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func diffLine(_ line: String) -> some View {
        let kind: (color: Color, background: Color) = {
            if line.hasPrefix("+") { return (theme.successColor, theme.successColor.opacity(0.1)) }
            if line.hasPrefix("-") { return (theme.errorColor, theme.errorColor.opacity(0.1)) }
            return (theme.secondaryText, .clear)
        }()
        Text(line.isEmpty ? " " : line)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(kind.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(kind.background)
            .textSelection(.enabled)
    }

    /// Opens the row's file, reading from disk first when the row has no inline content
    /// (`read_file`). The read is off-main and the failure path is explicit — a file the
    /// agent read may since have been moved or deleted.
    private func openInViewer(_ action: TimelineFileViewerAction,
                              viewModel: ChatHistoryViewModel,
                              preWriteContent: String?) {
        if let inline = action.inlineContent {
            viewModel.openTimelineFileInCodeViewer(
                fileName: action.fileName,
                filePath: action.filePath,
                content: inline
            )
            return
        }

        guard !isOpeningFromDisk else { return }
        isOpeningFromDisk = true
        openFailureReason = nil
        let path = action.filePath
        Task {
            // `try?` here discarded the real error, so "moved", "no permission" and
            // "not UTF-8" were indistinguishable in the log and invisible in the UI.
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try String(contentsOfFile: path, encoding: .utf8)) }
                catch { return .failure(error) }
            }.value
            isOpeningFromDisk = false

            // [CF-53] The read outlived a conversation switch. Nothing cancels this task and the
            // view holds no handle to it, so without a destination check the tab (and its failure
            // banner) landed in whatever conversation is open when the disk read returns.
            //
            // `currentChatMessages` CANNOT answer this on its own: `loadConversation` assigns it
            // only after its fetch returns, so for the whole duration of a switch it still names
            // the OUTGOING conversation (`ChatHistoryViewModel.destinationConversationID`) — the
            // one window `resetCodeViewer()` has already emptied the viewer in. So the in-flight
            // flag is asked FIRST and the displayed identity is only trusted outside a load.
            let current = viewModel.currentChatMessages.first?.conversationId
            let isLoadInFlight = viewModel.isInitiallyLoadingConversation
            guard Self.shouldDeliverOpen(origin: originConversationID,
                                         current: current,
                                         isLoadInFlight: isLoadInFlight) else {
                openFailureReason = nil
                let origin = originConversationID?.uuidString.prefix(8) ?? "no conversation"
                let now = isLoadInFlight
                    ? "a conversation switch is still in flight"
                    : "\(current?.uuidString.prefix(8) ?? "none") is open now"
                timelineLogger.info("[CodeViewer] Timeline open of '\(path)' dropped — it was started in conversation \(origin) and \(now). CONSEQUENCE: no tab opens; planting one here would also suppress the incoming conversation's tab restore, so the user re-clicks the row once the switch settles.")
                return
            }

            switch result {
            case .failure(let error):
                let reason = Self.openFailureText(for: error, path: path)
                openFailureReason = reason
                timelineLogger.warning("[CodeViewer] Timeline open of '\(path)' failed — \(error.localizedDescription). Surfaced to the user under the row; nothing opened.")
                return
            case .success(let content) where content.isEmpty:
                // Readable but empty: opening a blank tab looks like a bug, so say so.
                openFailureReason = String(localized: "This file is now empty — nothing to show.")
                timelineLogger.warning("[CodeViewer] Timeline open of '\(path)' read 0 bytes — the file is empty now; nothing opened.")
                return
            case .success(let content):
                openFailureReason = nil
                viewModel.openTimelineFileInCodeViewer(
                    fileName: action.fileName,
                    filePath: path,
                    content: content
                )
            }
        }
    }

    /// Whether a completed disk read may still open a tab.
    ///
    /// [CF-53] The sibling paths in `ChatHistoryViewModel` were given explicit destination checks
    /// by CH15/CH17/CH60; this one had none. Two independent ways the click can be stale, because
    /// the row's own identity only covers one of them:
    ///
    /// * `isLoadInFlight` — a conversation switch is between `resetCodeViewer()` (which has
    ///   already stashed and emptied the viewer) and `restoreCodeViewerSession(for:)`. NOTHING may
    ///   be planted in that window, whatever the row's origin: `currentChatMessages` still names
    ///   the OUTGOING conversation throughout it, so `origin == current` passes exactly when it
    ///   must not, and a tab planted here ALSO suppresses the incoming conversation's restore,
    ///   which only fires on an empty viewer. This term is also what covers any caller that
    ///   supplies no origin yet opens into that same shared viewer.
    /// * `origin != current` — the switch settled on a different conversation before the read
    ///   returned.
    ///
    /// A nil `origin` outside a load still delivers: the viewer's owner has not moved, so there is
    /// nothing to be wrong about.
    ///
    /// Deliberately conservative — a same-conversation reload in flight drops too. Re-clicking
    /// costs the user one click; the other error destroys the incoming conversation's tabs and
    /// unsaved drafts.
    ///
    /// ⚠️ The stated REASON was "the chat view model publishes no destination identity to tell the
    /// two apart (its `destinationConversationID` is private)". That was true until 2026-09-06,
    /// when the property was made internal for `ConversationSyncService`; it would now distinguish
    /// the two cases (on a same-conversation reload the destination IS the origin). The
    /// conservatism is therefore a CHOICE from here on, not a constraint — and a cheap one, since
    /// `loadConversation` skips `resetCodeViewer()` on a same-conversation reload, so there is no
    /// emptied viewer to plant into. Anyone tightening this must change the CALL SITE too, which
    /// still passes the positional `currentChatMessages.first?.conversationId` as `current`.
    ///
    /// `nonisolated static` and pure so the rule is unit-testable; the `Task`/read plumbing is not.
    nonisolated static func shouldDeliverOpen(origin: UUID?, current: UUID?, isLoadInFlight: Bool) -> Bool {
        guard !isLoadInFlight else { return false }
        guard let origin else { return true }
        return origin == current
    }

    /// Turns a read error into something the user can act on. `CocoaError` codes are checked
    /// rather than the message, so the distinction survives localization.
    private static func openFailureText(for error: Error, path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let cocoa = error as? CocoaError
        switch cocoa?.code {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return String(localized: "\(name) has been moved or deleted since the agent read it.")
        case .fileReadNoPermission:
            return String(localized: "Devgentic doesn't have permission to read \(name).")
        case .fileReadInapplicableStringEncoding:
            return String(localized: "\(name) isn't UTF-8 text, so it can't be shown here.")
        default:
            return String(localized: "Couldn't open \(name): \(error.localizedDescription)")
        }
    }

    /// The ONE key both the resolver task and the label cache use — built in one place so
    /// they cannot disagree about when a row has changed.
    nonisolated static func chipKey(for data: ToolExecutionData) -> TimelineChipKey {
        TimelineChipKey(id: data.id, isExecuting: data.isExecuting, isSuccess: data.isSuccess)
    }

    /// The row label: the cached one when it was resolved for exactly `key`, a fresh parse
    /// otherwise. A miss is not an error — it is the very first body pass before `.task`
    /// has run, or the single pass after completion rewrote `params` (a new key) before
    /// `resolveChip` re-resolves. `nonisolated static` and pure so the hit/miss rule is
    /// unit-testable (`TimelinePrimaryArgCacheTests`); the `.task` plumbing is not.
    nonisolated static func primaryArgLabel(
        cached: (key: TimelineChipKey, label: String)?,
        for key: TimelineChipKey,
        tool: String,
        params: String
    ) -> String {
        if let cached, cached.key == key { return cached.label }
        return ToolArgFormatter.primaryLabel(tool: tool, params: params)
    }

    /// Whether this row needs its OWN measured diff, or already has the answer persisted.
    ///
    /// [CF-48] `fileViewerChip` reads `writeDiffStat` only as the fallback for a row with no
    /// `effect`: `stat`, `isNoOpWrite` and `hasBaseline` all take the `effect` branch first. So
    /// on the in-session path — where `ActionEffectBuilder` has already produced an effect — the
    /// full-file LCS diff below was computed and never read, and because it lives in `.task(id:)`
    /// it was re-armed every time the row scrolled back into the `LazyVStack`.
    ///
    /// `nonisolated static` and pure so the rule is unit-testable; the `.task` plumbing is not.
    nonisolated static func needsMeasuredWriteDiff(hasPersistedEffect: Bool,
                                                   action: TimelineFileViewerAction?) -> Bool {
        guard !hasPersistedEffect, let action, action.isWrite else { return false }
        return action.preWriteContent != nil && action.inlineContent != nil
    }

    /// One resolution + one stat computation + one label parse per row, keyed by the event
    /// id and completion state — off the render path entirely.
    private func resolveChip(for data: ToolExecutionData) async {
        // Label first, before any suspension: it is the cheapest of the three and the one
        // every row shows, so it must not wait behind a detached diff.
        // [tc-8] ONE parse for this row, shared by the label and the chip resolution.
        let parsed = ToolArgFormatter.parsedParamsForRow(data.params)
        primaryArgCache = (
            key: Self.chipKey(for: data),
            label: ToolArgFormatter.primaryLabel(tool: data.name, dict: parsed)
        )
        let action = TimelineFileViewerAction.resolve(data: data, params: parsed)
        resolvedAction = action

        guard Self.needsMeasuredWriteDiff(hasPersistedEffect: data.effect != nil, action: action),
              let pre = action?.preWriteContent,
              let content = action?.inlineContent else { return }
        // Byte-identical no-op: skip the detached diff — equality is O(n) and the answer
        // is already known.
        if pre == content {
            writeDiffStat = (0, 0)
            return
        }
        writeDiffStat = await Task.detached(priority: .utility) {
            DiffUtility.changeCounts(original: pre, modified: content)
        }.value
    }

    @ViewBuilder
    private func toolTypeIcon(tool: String, data: ToolExecutionData) -> some View {
        if data.isExecuting {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 13, height: 13)
        } else if let success = data.isSuccess, !success {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.errorColor)
                .frame(width: 13, height: 13)
        } else {
            switch tool {
            case "read_file", "write_file", "edit_file", "edit_code", "create_file",
                 "create_new_file", "overwrite_file", "edit_code_single", "edit_code_batch", "file_overview":
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.orange.opacity(0.85))
                    .frame(width: 13, height: 13)
            case "list_directory", "project_tree", "codebase_map", "batch_move_files":
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.blue.opacity(0.85))
                    .frame(width: 13, height: 13)
            case "grep", "grep_search", "ripgrep", "code_search", "glob_files",
                 "code_search_text", "code_search_symbol", "code_search_files", "web_search", "spotlight_search", "fs_smart_search":
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 13, height: 13)
            case "execute_shell", "run_shell", "bash", "shell", "batch_command", "run_command", "start_background_task":
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 13, height: 13)
            case "ask_user":
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 13, height: 13)
            case "diff_files":
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 13, height: 13)
            default:
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 13, height: 13)
            }
        }
    }

    var body: some View {
        if case .toolExecution(let data) = event {
            // ⚠️ [tc-9] Resolved ONCE per body pass. `TimelineRowDetail.resolve` trims and scans
            // the tool output — up to 32 KB for a write row — and it was called twice on every
            // pass: once by `actionRowButton` for the `isDisclosable` predicate and again here
            // for the disclosed content. A `LazyVStack` re-runs this on every scroll-in.
            let detail = rowDetail(data)
            let isDisclosable = detail != nil && !data.isExecuting
            let isExpanded = isOutputExpanded(data)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Button {
                        guard isDisclosable else { return }
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if expandedRowIDs.contains(data.id) {
                                expandedRowIDs.remove(data.id)
                            } else {
                                expandedRowIDs.insert(data.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            toolTypeIcon(tool: data.name, data: data)
                                .accessibilityLabel(statusAccessibilityLabel(data: data))

                            Text(ToolArgFormatter.verb(tool: data.name))
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(theme.secondaryText)

                            // Cached per key by `resolveChip`; parsed inline only on a miss (see
                            // `primaryArgLabel`). A direct `primaryLabel` call here re-parsed the
                            // full params — the whole file for a write — on every body pass (CF-45).
                            let primaryArg = Self.primaryArgLabel(
                                cached: primaryArgCache,
                                for: Self.chipKey(for: data),
                                tool: data.name,
                                params: data.params
                            )
                            if !primaryArg.isEmpty {
                                Text(primaryArg)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundColor(isHovering ? theme.primaryText : theme.primaryText.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            if let dur = data.durationMs, dur >= 100 {
                                Text("(\(DurationFormat.milliseconds(dur)))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(theme.tertiaryText)
                            }

                            Spacer(minLength: 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // `.allowsHitTesting` rather than `.disabled`: on macOS a `.plain` button
                    // renders its label dimmed when disabled, which would grey out the verb,
                    // path and spinner of every row for as long as it runs.
                    .allowsHitTesting(isDisclosable)
                    // SwiftUI has no "expanded" trait for a hand-rolled disclosure, and the
                    // label text is identical in both states — without this VoiceOver cannot
                    // tell them apart at all.
                    .accessibilityValue(
                        isDisclosable
                            ? Text(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
                            : Text("")
                    )
                    .accessibilityHint(
                        isDisclosable
                            ? Text(isExpanded
                                   ? String(localized: "Hides this step's details")
                                   : String(localized: "Shows this step's details"))
                            : Text("")
                    )

                    trailingStatusBadge(data: data)

                    fileViewerChip(data: data)

                    if isDisclosable {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if expandedRowIDs.contains(data.id) {
                                    expandedRowIDs.remove(data.id)
                                } else {
                                    expandedRowIDs.insert(data.id)
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .padding(.horizontal, 4)
                                .frame(minHeight: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isHovering && isDisclosable {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(theme.surfaceOverlay.opacity(0.45))
                    }
                }

                // Disclosed detail
                if isExpanded, let detail {
                    VStack(alignment: .leading, spacing: 3) {
                        switch detail {
                        case .diff(let effect, let note):
                            inlineDiff(effect)
                            // Only present when the output says something the diff cannot —
                            // see `TimelineRowDetail.resolve`.
                            if let note { expandedOutput(note) }
                        case .output(let out):
                            expandedOutput(out)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 2)
                    .transition(.opacity)
                }

                // The one route this row offers can fail (the file moved, went unreadable,
                // or stopped being text). Say so where the click happened.
                if let openFailureReason {
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.errorColor)
                        Text(openFailureReason)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.primaryText.opacity(0.85))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.errorColor.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(theme.errorColor.opacity(0.2), lineWidth: 0.5)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(localized: "Could not open file. \(openFailureReason)"))
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1.5)
            .onHover { hovering in
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    isHovering = hovering
                }
            }
            // Keyed on the completion state too: a row resolves to no chip while the tool
            // is still executing, and must re-resolve once it finishes — which is also when
            // `params` is rewritten, so the cached label re-resolves with it.
            .task(id: Self.chipKey(for: data)) {
                await resolveChip(for: data)
            }
        }
    }

    @ViewBuilder
    private func expandedOutput(_ out: String) -> some View {
        ViewThatFits(in: .vertical) {
            Text(out)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.primaryText.opacity(0.75))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)

            ScrollView(.vertical, showsIndicators: true) {
                Text(out)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 200)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.surfaceOverlay.opacity(0.3))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.secondaryText.opacity(0.3))
                .frame(width: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .transition(.opacity)
    }

    @ViewBuilder
    private func leadingStatusIcon(data: ToolExecutionData) -> some View {
        Group {
            if data.isExecuting {
                ProgressView()
                    .controlSize(.mini)
            } else if let success = data.isSuccess {
                if data.name == "ask_user" {
                    Image(systemName: success ? "bubble.left.fill" : "arrow.uturn.left")
                        .font(.system(size: 10))
                        .foregroundColor(success ? theme.streamingIndicator.opacity(0.85) : theme.secondaryText.opacity(0.5))
                } else if success {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(theme.successColor.opacity(0.85))
                } else {
                    Image(systemName: data.failureCategory?.icon ?? "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.errorColor)
                }
            } else {
                // ⚠️ [tc-10] SETTLED, but its outcome was never reported. `isExecuting == false` with
                // `isSuccess == nil` used to fall off the end of this `if`/`else if` and render
                // NOTHING, so a row a user Stop had closed looked the same as one still waiting for a
                // badge — no spinner, no glyph, nothing to say the tool's fate is unknown.
                //
                // Reachable from EXACTLY three writers, all deliberate terminal closes in
                // `DanglingToolRowCloser`: `closeReporting` (cancel), `closeForUserSkipReporting`
                // (the user skipped the node) and `markInterruptedByProcessDeath`. Every normal
                // completion pairs `isSuccess` with `isExecuting = false` — `ActiveStreamManager`
                // :1261/:1264 and `CapabilityCardRouter` :252/:255 — and `ToolOutput.isSuccess` is a
                // non-optional `Bool`, so a finished tool can never land here.
                //
                // ⚠️ `slash.circle`, matching `CapabilityStatusIcon`'s cancelled glyph — NOT
                // `ToolFailureCategory.cancelled.icon`, which is `xmark.circle` and reads as a
                // failure. A user's own Stop is not a failure; `summarize` still counts nothing here.
                Image(systemName: data.failureCategory == .cancelled ? "slash.circle" : "circle.dotted")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .frame(width: 14, alignment: .center)
        .accessibilityLabel(statusAccessibilityLabel(data: data))
    }

    private func statusAccessibilityLabel(data: ToolExecutionData) -> String {
        if data.isExecuting {
            return String(localized: "Running")
        } else if let success = data.isSuccess {
            if success {
                return String(localized: "Succeeded")
            } else {
                return String(localized: "Failed: \(data.failureCategory?.displayName ?? "Error")")
            }
        } else {
            return data.failureCategory == .cancelled
                ? String(localized: "Cancelled before it finished")
                : String(localized: "Outcome unknown — the run ended first")
        }
    }

    @ViewBuilder
    private func trailingStatusBadge(data: ToolExecutionData) -> some View {
        if !data.isExecuting, data.name != "ask_user", let success = data.isSuccess, !success, let cat = data.failureCategory {
            Text(cat.displayName.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(theme.errorColor.opacity(0.85))
                .tracking(0.3)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.errorColor.opacity(0.12))
                )
        }
    }

}

// MARK: - Capability Milestone Row

struct CapabilityMilestoneRow: View {
    let kind: CapabilityMilestoneKind
    let detail: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(milestoneColor)
                .frame(width: 18, alignment: .center)

            Text(detail)
                .font(.system(.caption, weight: .medium))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [milestoneColor.opacity(0.12), milestoneColor.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(milestoneColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var milestoneColor: Color {
        theme.capabilityColor(for: kind.colorCategory)
    }
}

// MARK: - Warning Row

struct WarningRow: View {
    let category: WarningCategory
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: category.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 14, alignment: .center)

            Text(category.displayName.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundColor(.orange.opacity(0.95))
                .tracking(0.3)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.orange.opacity(0.15)))

            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
    }
}

/// Clean single-line row for system-level progress (e.g. "Connecting to Ollama: ...")
/// that should not be branded as an interim model reasoning "thought".
struct SystemStatusRow: View {
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 13, height: 13)

            Text(text)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(theme.secondaryText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
    }
}

// MARK: - Interim Reasoning Row

/// Compact display for `.thought`/`.reasoning` nodes inside a chat/code bubble.
/// Strips heading markers (so `# Summary` doesn't render as an H1 competing with
/// the final answer), renders at a muted scale, and provides a clean Antigravity-style
/// collapsible tree hierarchy.
struct InterimReasoningRow: View {
    let text: String
    /// [CF-49] Whether the run producing this reasoning is still going.
    var isLive: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        let flattened = flattenedText
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    if isLive {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.accentColor)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    }

                    Text(isLive ? String(localized: "Thinking…") : String(localized: "Thought process"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(isHovering ? theme.primaryText : theme.secondaryText)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.leading, 1)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovering = hovering
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    Text(flattened)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText.opacity(0.9))
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                .padding(.leading, 12)
                .padding(.vertical, 3)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(theme.tertiaryText.opacity(0.2))
                        .frame(width: 1)
                        .padding(.leading, 2)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            if isLive {
                isExpanded = true
            }
        }
    }

    /// Flattens markdown for compact display: drops heading markers, list
    /// bullets (dash / star / numbered), inline emphasis (`**bold**`, `__bold__`,
    /// `*italic*`), and collapses blank lines so the row reads as a single muted
    /// paragraph rather than a full document. Inline code (backticks) is kept —
    /// file paths / identifiers inside them carry meaning.
    private var flattenedText: String {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Strip leading heading markers (#, ##, ###…).
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)

            // Strip a single leading dash/star/plus list marker.
            for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
                line.removeFirst(marker.count)
                break
            }

            // Strip a leading numbered-list marker like "1. " or "12) ".
            line = Self.stripNumberedListMarker(line)

            // Strip bold/italic emphasis — keep backticks.
            line = line.replacingOccurrences(of: "**", with: "")
            line = line.replacingOccurrences(of: "__", with: "")

            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line) }
        }
        return out.joined(separator: " · ")
    }

    private static func stripNumberedListMarker(_ line: String) -> String {
        // Match digits followed by '.' or ')' and a space, e.g. "1. foo" or "12) bar".
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            idx = line.index(after: idx)
        }
        guard idx > line.startIndex, idx < line.endIndex,
              line[idx] == "." || line[idx] == ")" else { return line }
        let afterPunct = line.index(after: idx)
        guard afterPunct < line.endIndex, line[afterPunct] == " " else { return line }
        return String(line[line.index(after: afterPunct)...])
    }

}

// MARK: - Streaming Footer

/// Snapshot of the fields needed to render the streaming progress footer.
/// Carved out so the footer can be fed from a ChatMessage today or any other
/// source (workflow, scheduled run) later without changing the view contract.
struct StreamingContext {
    let startedAt: Date
    let isStreaming: Bool

    /// Footer is a progress indicator — it only appears while the response is
    /// still streaming. Once streaming ends, the bubble's existing `TokenUsageBadge`
    /// carries the final token + duration summary, so the footer hides to avoid
    /// a duplicate "done" display or a stale ticking timer next to old messages.
    var shouldDisplay: Bool { isStreaming }
}

/// Bottom-of-timeline progress indicator modelled on Claude Code's streaming chip:
/// pulsing sparkle + live elapsed time. Token count lives in the bubble's
/// TokenUsageBadge once the response completes; we don't duplicate it here.
struct StreamingTimelineFooter: View {
    let context: StreamingContext

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.streamingIndicator.opacity(0.95))
                .frame(width: 14, alignment: .center)
                .symbolEffect(.pulse, options: .repeating, isActive: context.isStreaming && !reduceMotion)

            // TimelineView re-renders once per second while visible and stops
            // when off-screen — cheaper than a Timer and auto-cleans on removal.
            TimelineView(.periodic(from: context.startedAt, by: 1.0)) { timeline in
                Text(DurationFormat.elapsed(from: context.startedAt, to: timeline.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
        // `.ignore`, and a label with no elapsed time in it. This used to be
        // `"Streaming, \(elapsed(to: Date()))"` — rebuilt on every body pass, so the label
        // changed once a second and VoiceOver re-announced the footer for the whole
        // response. It also read `Date()` instead of the TimelineView's own `timeline.date`,
        // so the spoken time didn't match the displayed one.
        //
        // The elapsed counter stays visual. A duration spoken aloud is stale the moment
        // it's said, and "Streaming response" is the part that's actually actionable —
        // same call as the run-history cards.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streaming response")
    }
}

// MARK: - Tool Arg Formatter

/// Extracts display-ready verb, object label, and primary argument for a tool invocation.
/// Drives both group-header summarization ("Read 3 files") and per-row labels ("Read BackendOrchestrationService.swift").
/// Tool-name lookups are local to this file so the timeline rendering owns its vocabulary
/// instead of leaking display strings into the tool registry.
enum ToolArgFormatter {

    /// Short verb used in both row labels and group titles.
    /// First bucket in a mixed group uses TitleCase; subsequent buckets lowercase it.
    static func verb(tool: String) -> String {
        if let v = verbOverrides[tool] { return v }
        let parts = tool.lowercased().split(separator: "_")
        if let first = parts.first {
            return String(first).capitalized
        }
        return tool.capitalized
    }

    /// Singular/plural object noun for the group title ("file" / "files", "directory" / "directories").
    /// Defaults to "tool" / "tools" for unknown tools.
    static func objectLabel(tool: String, plural: Int) -> String {
        if let m = objectOverrides[tool] {
            return plural == 1 ? m.singular : m.plural
        }
        return plural == 1 ? "tool" : "tools"
    }

    /// The primary argument to surface in the row — filename for fs ops, query for searches,
    /// command prefix for shell, question for ask_user, etc. Empty string means "no useful label".
    /// [tc-8] String form — parses, then delegates. Kept for the callers that genuinely hold only
    /// a String (`ConversationExporter`, and `primaryArgLabel`'s cache-miss path).
    static func primaryLabel(tool: String, params: String) -> String {
        primaryLabel(tool: tool, dict: parseParams(params))
    }

    /// [tc-8] The form that takes an ALREADY-PARSED params dictionary.
    ///
    /// `resolveChip` needs both this and `TimelineFileViewerAction.resolve` for the same row, and
    /// each used to run its own `JSONSerialization` pass over the full, uncapped params — which
    /// for a write row is the entire file. Worse than once per row: `.task(id:)` keys on
    /// `(id, isExecuting, isSuccess)`, and completion flips `isExecuting` AND rewrites `params`,
    /// so a normal live run resolved every write row twice — four full parses of the file on the
    /// main actor.
    ///
    /// ⚠️ Deliberately NOT moved into a `Task.detached`: that inserts a suspension before
    /// `primaryArgCache` is set, so the first render falls through to the cache-miss path and
    /// parses anyway. Parsing once and sharing the result is the whole fix.
    static func primaryLabel(tool: String, dict: [String: Any]?) -> String {
        // `final_answer` is a terminal signal — its `answer` arg is rendered as the
        // assistant's final message directly below this chip. Surfacing the answer
        // text in the chip duplicates it and leaks raw markdown (`###`, `**`, etc.)
        // into a non-rendering label. Keep the chip terse — just the "Final" verb.
        if tool == "final_answer" {
            return ""
        }

        guard let dict, !dict.isEmpty else { return "" }

        switch tool {
        // ⚠️ The Code profile's intent-split tools MUST be listed here too. `CodeToolPreset`
        // supplies `create_new_file`/`overwrite_file`/`edit_code_single`/`edit_code_batch` to
        // every Code profile, and none of them was in this switch — so they fell through to the
        // fallback below, which surfaced whichever String the params dictionary happened to
        // yield first. For `{file_path, content}` that is frequently `content`, so a row for a
        // newly created Swift file rendered `Create import SwiftUI import Foundation str…`
        // instead of `Create Notes.swift`. The same label feeds `ConversationExporter`, so the
        // export carried the code fragment too.
        case "read_file", "write_file", "edit_file", "edit_code", "create_file",
             "file_overview", "read_file_metadata", "fs_read_metadata", "watch_folder", "fs_watch_folder",
             "create_new_file", "overwrite_file", "edit_code_single", "edit_code_batch":
            if let p = firstString(dict, keys: ["path", "file_path"]) {
                return basename(p)
            }
        case "list_directory", "spotlight_search", "fs_smart_search", "batch_move_files", "fs_organize_batch", "project_tree", "codebase_map":
            if let p = firstString(dict, keys: ["path", "directory", "dir"]) {
                return shortPath(p)
            }
        // The three `code_search_*` splits all take `pattern`, which this already tries.
        case "grep", "grep_search", "ripgrep", "code_search", "glob_files",
             "code_search_text", "code_search_symbol", "code_search_files":
            if let q = firstString(dict, keys: ["pattern", "query", "regex"]) {
                return truncate(q, 50)
            }
        case "web_search":
            if let q = firstString(dict, keys: ["query", "q"]) {
                return truncate(q, 50)
            }
        case "run_shell", "execute_shell", "bash", "shell", "batch_command", "run_command", "start_background_task":
            if let cmd = firstString(dict, keys: ["command", "cmd", "script"]) {
                return truncate(cmd, 50)
            }
        case "ask_user":
            if let q = firstString(dict, keys: ["question", "prompt"]) {
                return truncate(q, 60)
            }
        case "call_agent":
            if let t = firstString(dict, keys: ["task", "goal", "prompt"]) {
                return truncate(t, 50)
            }
        // `recall_conversation_history` no longer exists — the tool was dropped from dispatch as
        // redundant with the RAG pipeline, and its struct deleted 2026-07-31. This case and its
        // label/icon entries are kept deliberately: stored conversations from before the removal
        // still contain calls to it, and this view renders history. Deleting these would make
        // those old turns fall back to a generic label for no gain.
        case "recall_conversation_history":
            if let q = firstString(dict, keys: ["query", "topic"]) {
                return truncate(q, 50)
            }
        case "git", "git_tool":
            if let a = firstString(dict, keys: ["action", "operation", "command"]) {
                return a
            }
        case "find_definition":
            if let s = firstString(dict, keys: ["symbol", "name", "identifier"]) {
                return truncate(s, 40)
            }
        case "diff_files":
            // Surface both filenames joined so "Diffed foo.swift ↔ bar.swift" reads at a glance.
            let a = firstString(dict, keys: ["file_a", "file_path_a", "path_a"])
            let b = firstString(dict, keys: ["file_b", "file_path_b", "path_b"])
            switch (a, b) {
            case (let a?, let b?): return "\(basename(a)) ↔ \(basename(b))"
            case (let a?, nil):    return basename(a)
            case (nil, let b?):    return basename(b)
            default:               break
            }
        default:
            break
        }

        // Fallback for a tool with no case above — a third-party MCP tool, or one added to the
        // catalogue without a row here.
        //
        // ⚠️ THREE properties this must have. The first two were learned from the split tools
        // falling through; the third from [CR25].
        //  1. DETERMINISTIC. `for (_, v) in dict` iterates a bridged dictionary in an order that
        //     is per-instance, so the SAME stored row could label differently between launches.
        //     Sorted keys make the label a function of the params alone.
        //  2. NEVER a payload. `content`/`old_string`/`new_string` carry whole files and code
        //     fragments; surfacing one puts source into a 40-char chip and into the Markdown
        //     export. An identifying value or nothing is the right choice — a row with no label
        //     still renders its verb and object. ⚠️ The empty label is the DECISION here, not a
        //     gap in it: `testAnUnknownToolWithOnlyPayloadParamsLabelsNothing` asserts it in so
        //     many words. If some tool genuinely needs identity, widen `identifyingParamKeys` —
        //     never relax this set.
        //  3. [CR25] NEVER a credential. Property 2 one step further, and the reason is the
        //     EXPORT: `ConversationExporter.toolRowLine` calls this function and has no redaction
        //     pass of its own, so for the one surface here that the user hands to someone else,
        //     this is the last thing standing between a param value and a third party. Two
        //     carriers are closed — a secret-NAMED key (skipped outright) and a URL's
        //     query/fragment/userinfo (`webURLLabel` rebuilds from host and path only). Note that
        //     property 1 is what made the second one necessary: sorting is a TOTAL order, so
        //     `api_key` beat `topic` every single time rather than merely sometimes.
        if let identifying = firstString(dict, keys: identifyingParamKeys) {
            if let web = webURLLabel(identifying) { return web }
            return pathShaped(identifying) ? basename(identifying) : truncate(identifying, 40)
        }
        for key in dict.keys.sorted()
        where !payloadParamKeys.contains(key) && !isSecretParamName(key) {
            if let s = dict[key] as? String, !s.isEmpty {
                // ⚠️ [CR25] `webURLLabel` HERE TOO, not only on the identifying branch above.
                // `http_request` DECLARES `url`, but its decoder also accepts `endpoint`/`uri`/
                // `address` (NetworkTools.swift:115) and a third-party tool may name its URL
                // parameter anything at all — `webhook`, `callback`, `href`. Those values reach
                // the sweep, where `truncate(s, 40)` would carry 40 characters of query string
                // into the export. A URL is a URL wherever it is found.
                return webURLLabel(s) ?? truncate(s, 40)
            }
            if let n = dict[key] as? NSNumber {
                return n.stringValue
            }
        }
        return ""
    }

    /// Keys that identify WHAT a tool acted on, tried in order before anything else.
    ///
    /// ⚠️ [CR25] `endpoint`/`uri`/`address` are here because `http_request`'s DECLARED schema says
    /// `url` while its `Decodable` accepts all four (NetworkTools.swift:115). Without them a model
    /// that emitted `endpoint` fell to the sorted sweep, where `method` outranks it alphabetically
    /// — so the row named the VERB ("GET") instead of the host it called.
    ///
    /// ⚠️ Nothing in this list may be a credential name. This branch runs BEFORE the sweep and
    /// deliberately does NOT consult `isSecretParamName` (that check would then run on every row
    /// render for a list that is a fixed literal right here). The disjointness is therefore held
    /// by a test — `testNeitherKeyListMayCarryACredentialName` — and not by code on the render path.
    private static let identifyingParamKeys = [
        "file_path", "path", "query", "pattern", "command", "cmd",
        "url", "endpoint", "uri", "address",
        "symbol", "name", "directory", "dir", "action"
    ]

    /// Keys whose values are CONTENT rather than identity — never a chip label.
    ///
    /// ⚠️ [CR25] `headers`: `NetworkTools` decodes `http_request`'s headers as an object OR as a
    /// JSON STRING, deliberately, because models emit both (:136-147). In the object form the
    /// sweep skips it anyway — `dict[key] as? String` fails on a bridged `NSDictionary`. In the
    /// string form that cast SUCCEEDS, and the label became `{"Authorization":"Bearer sk-…`. A
    /// header blob is never identity, so refusing it costs a row nothing.
    ///
    /// ⚠️ [CR25] `script`/`applescript`/`appleScript`/`sourceCode`: `run_applescript`
    /// (NativeSystemTools.swift:183) has no case in the switch above, so its `script` param
    /// reached the sweep and put 40 characters of raw AppleScript into the chip and the export —
    /// the language whose ordinary idiom is `do shell script "…" password "…"`. This set is read
    /// ONLY by the sweep, so `run_shell`/`execute_shell` are unaffected: they read `script`
    /// through their own `case` and never consult it.
    private static let payloadParamKeys: Set<String> = [
        "content", "old_string", "new_string", "text", "body", "answer",
        "data", "source", "code", "edits",
        "script", "applescript", "appleScript", "sourceCode", "headers"
    ]

    /// [CR25] Param names whose VALUE is a credential. The sorted sweep skips them outright.
    ///
    /// ⚠️ DERIVED from `TelemetrySanitizer.standardSecretKeysForEgress`, never hand-typed here.
    /// That list's own doc says it is the single place to add a secret key — "Adding a key here
    /// strengthens both" — and a second copy of the same strings inside a view file is exactly the
    /// drift this project keeps writing drift tests to punish.
    ///
    /// Matched by NORMALIZED CONTAINS (lowercased, with `_`, `-` and `.` stripped) rather than by
    /// equality, because a third-party MCP schema will not spell it the canonical way: this is
    /// what catches `x-api-key`, `X_API_KEY`, `openaiApiKey`, `githubToken`. The false positives
    /// are real and ACCEPTED rather than worked around — `author` and `authority` contain `auth`,
    /// `tokenizer` contains `token` — because the sweep is a last resort that is already permitted
    /// to return "" (property 2). A dropped label is the safe side of this trade; a surfaced
    /// credential is not. If a real tool trips it, add that key to `identifyingParamKeys`, which
    /// runs first — do not weaken the token rule.
    ///
    /// ⚠️ This is still a rule about the NAME. It never inspects the value: no entropy test, no
    /// "looks like a key" regex. See `webURLLabel` for why that line is drawn where it is.
    private static let secretParamNameTokens: Set<String> = Set(
        TelemetrySanitizer.standardSecretKeysForEgress.map { ToolArgFormatter.normalizedParamName($0) }
    )

    private static func normalizedParamName(_ key: String) -> String {
        key.lowercased().filter { $0 != "_" && $0 != "-" && $0 != "." }
    }

    private static func isSecretParamName(_ key: String) -> Bool {
        let normalized = normalizedParamName(key)
        return secretParamNameTokens.contains { normalized.contains($0) }
    }

    /// [CR25] Test-only reflections of the two key lists and the secret rule, so
    /// `TimelineLabelCredentialTests` can assert the disjointness the render path does not check.
    static var identifyingParamKeysForTesting: [String] { identifyingParamKeys }
    static var payloadParamKeysForTesting: Set<String> { payloadParamKeys }
    static func isSecretParamNameForTesting(_ key: String) -> Bool { isSecretParamName(key) }

    /// A value worth reducing to its last path component.
    private static func pathShaped(_ value: String) -> Bool {
        value.contains("/") && !value.contains(" ")
    }

    /// [CR25] An absolute URL reduced to `host[:port]/…/lastSegment`, or nil if the value is not
    /// one. Three defects in a single branch, all downstream of `pathShaped` being TRUE of every
    /// URL (it contains `/` and no space) and `basename` being the one branch with NO length cap:
    ///
    ///  • The HOST was thrown away. `https://api.github.com/repos/x/y/issues` labelled `issues`,
    ///    so neither the chip nor the exported Markdown said which machine was contacted. For an
    ///    `http_request` row the host is the most load-bearing fact there is — a call to
    ///    `evil.example.com/steal` exported as `steal`, which is worse than no label at all
    ///    because it reads as though it had told you something.
    ///  • The QUERY STRING survived verbatim and uncapped:
    ///    `…/weather?appid=SECRET&q=London` labelled `weather?appid=SECRET&q=London`, and
    ///    `ConversationExporter.inlineArgument` wrapped that in backticks in a file the user hands
    ///    to someone else. Its 80-char bound never fired — the string is 32. Nothing downstream
    ///    catches it either: `RemoteEgressSanitizer.credentialsOnly` matches known token prefixes,
    ///    `Bearer`, `user:pass@`, quoted JSON keys and `KEY=value` env assignments, and `appid=`
    ///    is none of those ("APPID" does not contain "API").
    ///  • `user:pass@host` basic-auth rode along inside the same string.
    ///
    /// ⚠️ THIS PARSES; IT DOES NOT PATTERN-MATCH — and that distinction is the standing project
    /// rule "key off the argument NAME, never the SHAPE". `pathShaped`'s slash heuristic IS a
    /// shape rule, and it is what produced all three defects above. The NAME still decides WHICH
    /// value is surfaced (`identifyingParamKeys`, `payloadParamKeys`, `isSecretParamName`); this
    /// decides only how to SHORTEN a value already chosen, and it decides against a DECLARED
    /// GRAMMAR — a scheme plus a non-empty authority — which either matches or does not.
    ///
    /// ⚠️ ANY SCHEME WITH A HOST, not an http(s) allowlist. `TelemetrySanitizer`'s own
    /// `sanitizeURLCredentials` was widened for exactly this reason: `postgres://`, `mongodb://`,
    /// `redis://`, `s3://` are precisely the URIs a `.env` is full of and an agent quotes back.
    /// Requiring a non-empty HOST is what keeps the grammar honest — a Windows path `C:/x/y.txt`
    /// parses with scheme `C` and host nil, `mailto:` and `todo:` have no host either, and a POSIX
    /// path has no scheme. All four return nil here and are still basenamed exactly as before.
    ///
    /// ⚠️ The label is built from `host`, `port` and `path` ONLY. Nothing below reads `query`,
    /// `fragment`, `user`, `password` or `absoluteString`, so no credential can reach a label by
    /// any route this function later grows. That is a stronger guarantee than nil-ing those fields
    /// on a `var components` and serializing it — do not "simplify" it back to that.
    private static func webURLLabel(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              components.scheme != nil,
              let host = components.host, !host.isEmpty
        else { return nil }

        let authority = components.port.map { "\(host):\($0)" } ?? host
        let segments = components.path.split(separator: "/")
        guard let last = segments.last else { return truncate(authority, 40) }
        return truncate(segments.count > 1 ? "\(authority)/…/\(last)" : "\(authority)/\(last)", 40)
    }

    // MARK: - Tables

    private static let verbOverrides: [String: String] = [
        "read_file":                   "Read",
        "write_file":                  "Wrote",
        "edit_file":                   "Edited",
        "edit_code":                   "Edited",
        "create_file":                 "Created",
        "list_directory":              "Explored",
        "spotlight_search":            "Searched",
        "fs_smart_search":             "Searched",
        "read_file_metadata":          "Inspected",
        "fs_read_metadata":            "Inspected",
        "watch_folder":                "Watched",
        "fs_watch_folder":             "Watched",
        "batch_move_files":            "Organized",
        "fs_organize_batch":           "Organized",
        "execute_shell":               "Ran",
        "run_shell":                   "Ran",
        "bash":                        "Ran",
        "shell":                       "Ran",
        // ⚠️ `batch_command` STAYS — a timeline row PERSISTED before the split still carries that
        // toolName, and dropping it would relabel every historical row to the generic fallback.
        "batch_command":               "Ran",
        "run_command":                 "Ran",
        "start_background_task":       "Started",
        "grep":                        "Searched",
        "grep_search":                 "Searched",
        "ripgrep":                     "Searched",
        "code_search":                 "Searched",
        "glob_files":                  "Found",
        "web_search":                  "Searched",
        "ask_user":                    "Asked",
        "call_agent":                  "Delegated",
        "recall_conversation_history": "Recalled",
        "git":                         "Git",
        "git_tool":                    "Git",
        "find_definition":             "Located",
        "file_overview":               "Analyzed",
        "project_tree":                "Mapped",
        "codebase_map":                "Mapped",
        "diff_files":                  "Diffed",
        // The Code profile's intent-splits. Without these `verbLabel` falls back to a generic
        // verb and `objectLabel` to "tool"/"tools", so a group of three file creations in a Code
        // profile was headed "Create 3 tools" while the same work in a Chat profile read
        // "Created 3 files".
        "create_new_file":             "Created",
        "overwrite_file":              "Overwrote",
        "edit_code_single":            "Edited",
        "edit_code_batch":             "Edited",
        "code_search_text":            "Searched",
        "code_search_symbol":          "Searched",
        "code_search_files":           "Found"
    ]

    private static let objectOverrides: [String: (singular: String, plural: String)] = [
        "read_file":        ("file", "files"),
        "write_file":       ("file", "files"),
        "edit_file":        ("file", "files"),
        "edit_code":        ("file", "files"),
        "create_file":      ("file", "files"),
        "list_directory":   ("directory", "directories"),
        "spotlight_search": ("search", "searches"),
        "fs_smart_search":  ("search", "searches"),
        "read_file_metadata": ("file", "files"),
        "fs_read_metadata": ("file", "files"),
        "batch_move_files": ("file", "files"),
        "execute_shell":    ("command", "commands"),
        "run_shell":        ("command", "commands"),
        "bash":             ("command", "commands"),
        "shell":            ("command", "commands"),
        "batch_command":    ("command", "commands"),
        "run_command":      ("command", "commands"),
        "start_background_task": ("task", "tasks"),
        "grep":             ("search", "searches"),
        "grep_search":      ("search", "searches"),
        "ripgrep":          ("search", "searches"),
        "code_search":      ("match", "matches"),
        "glob_files":       ("match", "matches"),
        "web_search":       ("search", "searches"),
        "ask_user":         ("question", "questions"),
        "call_agent":       ("agent", "agents"),
        "git":              ("operation", "operations"),
        "git_tool":         ("operation", "operations"),
        "find_definition":  ("symbol", "symbols"),
        "file_overview":    ("file", "files"),
        "project_tree":     ("codebase", "codebases"),
        "codebase_map":     ("codebase", "codebases"),
        "diff_files":       ("diff", "diffs"),
        "create_new_file":  ("file", "files"),
        "overwrite_file":   ("file", "files"),
        "edit_code_single": ("file", "files"),
        "edit_code_batch":  ("file", "files"),
        "code_search_text": ("match", "matches"),
        "code_search_symbol": ("symbol", "symbols"),
        "code_search_files": ("file", "files")
    ]

    // [tc-12] `icon(tool:)` and its 29-entry `iconOverrides` table were DELETED here on
    // 2026-09-12. They had zero callers — production or test — under a doc comment claiming they
    // were "the single vocabulary for every per-tool glyph, so rendering paths can't drift": a
    // vocabulary no renderer consulted. The 2026-09-12 tc-1 pass had just added seven Code-profile
    // split tools to that table, which is how dead it was.
    //
    // Deleted rather than WIRED on purpose: hanging a glyph off `actionRowButton` would put a new
    // icon on every row of every agent timeline — a visual change nobody asked for, justified by a
    // row whose own evidence records no user-visible failure. The vocabulary is recoverable from
    // git if a surface ever wants it.
    //
    // ⚠️ `verbOverrides` / `objectOverrides` are LIVE (`verb`, `objectLabel`) and keep their
    // `edit_file` entry deliberately, even though no NATIVE tool is named that: MCP servers
    // commonly expose `edit_file`, and those tables are what stop a third-party row's group title
    // reading "Edited 3 tools". Same reasoning as the `recall_conversation_history` entries.

    // MARK: - Helpers

    /// [tc-8] The shared entry point `resolveChip` uses so ONE parse serves the label and the
    /// chip. `TimelineFileViewerAction.parsedParams` was byte-equivalent to this.
    static func parsedParamsForRow(_ json: String) -> [String: Any]? { parseParams(json) }

    private static func parseParams(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = dict[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Returns a shortened path: keep basename + one parent directory max.
    private static func shortPath(_ path: String) -> String {
        let ns = path as NSString
        let last = ns.lastPathComponent
        let parent = (ns.deletingLastPathComponent as NSString).lastPathComponent
        if parent.isEmpty || parent == "/" { return last }
        return "\(parent)/\(last)"
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count > max ? String(s.prefix(max - 1)) + "…" : s
    }
}

// MARK: - [TL-4] Render-skip contract

extension AgentTimelineView: Equatable {
    /// `revision` proxies `events` (bumped on every timeline mutation via
    /// `ChatMessage.timelineEvents.didSet`), so the array itself is not compared.
    /// `finalContentText` is deliberately ignored WHILE STREAMING: it mirrors the
    /// growing prose (changes every token) but both grouping dedup passes are
    /// `!isStreaming`-gated — comparing it live would re-run body per token and
    /// defeat the memoization on the exact path it exists for. The streaming
    /// footer self-ticks via `TimelineView(.periodic)`, so skipping body never
    /// freezes the elapsed counter.
    static func == (lhs: AgentTimelineView, rhs: AgentTimelineView) -> Bool {
        lhs.revision == rhs.revision
            && lhs.isStreaming == rhs.isStreaming
            && lhs.compactReasoning == rhs.compactReasoning
            && lhs.scrollable == rhs.scrollable
            // Without this a Resume — which flips `lifecycleState` to `.streaming` and back to
            // `.final` without necessarily bumping `revision` in the same pass — could leave the
            // interrupted header on a run that has since finished cleanly.
            && lhs.isInterrupted == rhs.isInterrupted
            && lhs.streamingContext?.startedAt == rhs.streamingContext?.startedAt
            && (lhs.isStreaming || lhs.finalContentText == rhs.finalContentText)
    }
}


// MARK: - Unrecognized Event Row

/// Rendered for a timeline event written by a NEWER build of Devgentic.
///
/// ⚠️ Shown rather than hidden on purpose. The event's bytes ARE preserved on disk — this build
/// simply has no renderer for it — so hiding it would make the timeline silently under-report what
/// the run did, and would make an unrecognised capability card's whole nested sub-timeline vanish
/// with no indication. The wording says "this version" because the data is not lost, only
/// undrawable here.
struct UnrecognizedEventRow: View {
    let caseName: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "questionmark.square.dashed")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .frame(width: 14, alignment: .center)
            Text("This version can't display this step (\(caseName)). It's kept and will appear in a newer version.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }
}
