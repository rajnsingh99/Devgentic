// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AgentTimelineView.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0
    @AppStorage(AppSettings.showTimelineThoughtsKey) private var showThoughts: Bool = false

    /// Optional text of the final content shown below the timeline. Used to
    /// deduplicate narrative events that would otherwise repeat the same text.
    /// Populated from `ChatMessage.content.textContent` in the message-based init.
    private let finalContentText: String?

    /// Optional streaming context that drives the bottom progress footer (pulsing icon +
    /// live elapsed + final token count). Populated only by the message-based init —
    /// workflow per-node timelines have their own indicators and leave this nil.
    private let streamingContext: StreamingContext?

    /// When true, `.thought`/`.reasoning` nodes render as a muted compact row.
    /// Workflow per-node views keep this false because their thought is often the node's final output.
    private let compactReasoning: Bool

    /// [TL-4] Change marker for `events` — proxies the whole array in `Equatable` so
    /// SwiftUI can skip body (and the grouping rebuild) when the timeline didn't change.
    /// Bumped by `ChatMessage.timelineEvents.didSet` on EVERY mutation path.
    private let revision: UInt64

    /// How the run actually ended, when the caller knows it (`ChatMessage.terminalOutcome`).
    /// nil means unknown; the header then reports success or degraded but never "Stopped".
    private let terminalOutcome: ExecutionOutcome?

    /// `message.lifecycleState.isInterrupted`, or false for the workflow per-node inits, which
    /// render a node's events and have no message lifecycle of their own.
    private let isInterrupted: Bool

    /// The conversation this timeline belongs to, when the caller knows it.
    /// Forwarded to `ActionDetailView` so an "Open in viewer" whose disk read outlives a conversation switch is dropped.
    /// nil means the per-conversation check cannot run; the switch-in-flight check in `shouldDeliverOpen` still applies.
    private let conversationID: UUID?

    /// When true, the expanded nodes container has a bounded height and scrolls vertically.
    /// Callers that already own the vertical scroll container (e.g. `WorkflowExecutionTimelineView`) set it to false.
    private let scrollable: Bool

    /// Set for a continuation (a report drawn inside the turn above it, see `TranscriptGrouping`).
    /// The header then reads "↳ <lead> · N steps" and the Thoughts toggle is left to the turn's own header.
    private let continuationLead: String?

    /// Initialize from a ChatMessage (existing usage in chat bubbles).
    init(message: ChatMessage, scrollable: Bool = true, continuationLead: String? = nil) {
        self.continuationLead = continuationLead
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

    /// Creates a timeline from raw events (used by workflow per-node detail views). `chatFidelity` renders thoughts
    /// compactly and shows the streaming footer; `streamingStartedAt` drives its elapsed counter. `finalContentText`
    /// dedups a trailing reasoning event that repeats the answer.
    init(
        events: [TimelineEvent],
        revision: UInt64 = 0,
        isStreaming: Bool = false,
        chatFidelity: Bool = false,
        streamingStartedAt: Date? = nil,
        finalContentText: String? = nil,
        conversationID: UUID? = nil,
        scrollable: Bool = false,
        terminalOutcome: ExecutionOutcome? = nil,
        isInterrupted: Bool = false
    ) {
        self.continuationLead = nil
        self.events = events
        self.revision = revision
        self.terminalOutcome = terminalOutcome
        self.isInterrupted = isInterrupted
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

    // Why: row view identity is not stable (grouping and run end rebuild the subtree), so per-row @State would reset; keep
    // expansion state here.
    /// Which tool rows the user has expanded, keyed by the tool event's stable id.
    @State private var expandedRowIDs: Set<UUID> = []

    var body: some View {
        // Grouping is O(n) over up to `ChatMessage.maxTimelineEvents` events. The chat bubble wraps this view in
        // `.equatable()` so the rebuild is skipped unless revision, streaming flag or final text changed.
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
        // Read once; the glyph, tint and title (used twice by `body`) all derive from these locals.
        let summaryValue = summary
        let titleText = continuationLead.map { Self.continuationTitle(lead: $0, stepsCount: nodes.count) }
            ?? summaryTitle(nodesCount: nodes.count, summary: summaryValue, showThoughts: showThoughts)
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
                    if hasThoughts && continuationLead == nil {
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
    /// The streaming auto-expand is only a default: once the user toggles, their choice applies even during a run.
    /// `nonisolated static` and pure so the rule is unit-testable.
    nonisolated static func showsTimelineBody(isTimelineExpanded: Bool,
                                              isStreaming: Bool,
                                              userToggled: Bool) -> Bool {
        if userToggled { return isTimelineExpanded }
        // `.onAppear` runs after the first render, so `|| isStreaming` supplies the auto-expand default for that first pass.
        return isTimelineExpanded || isStreaming
    }

    /// What the collapsed header may claim about a finished run.
    /// `message.terminalOutcome` decides when the caller has one; otherwise the events decide.
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
            // A circle rather than `.degraded`'s triangle so the two states stay distinguishable in the same slot.
            case .interrupted: return "exclamationmark.circle"
            }
        }
    }

    /// Returns the status, failed-tool count and total tool count from a single flatten of the events. `isInterrupted` is
    /// only consulted when `outcome` is nil, because an outcome means the run reached an end and reported it.
    static func summarize(events: [TimelineEvent],
                          outcome: ExecutionOutcome? = nil,
                          isInterrupted: Bool = false) -> (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int) {
        // Counts flattened events, not top-level ones: capability cards nest tool rows inside step/attempt arrays.
        var failed = 0
        var toolCount = 0
        for event in events.flatMap(\.flattenedIncludingNested) {
            guard case .toolExecution(let data) = event else { continue }
            toolCount += 1
            // A skipped `ask_user` (`.cancelled`) is not a failure; other `ask_user` failures and cancelled writes still count.
            let isDeclinedPrompt = data.name == "ask_user" && data.failureCategory == .cancelled
            if data.isSuccess == false, !isDeclinedPrompt { failed += 1 }
        }
        // The run's own outcome leads; the tool-failure count can only escalate from there. `.failed` and
        // `.completedWithWarnings` map to `.degraded`; cancellation comes only from the outcome, never from a tool row.
        switch outcome {
        case .cancelled:
            return (.cancelled, failed, toolCount)
        case .failed, .completedWithWarnings, .timedOut:
            return (.degraded, failed, toolCount)
        case .completed, nil:
            // The outcome still LEADS where there is one; this only fills the gap it leaves.
            if outcome == nil, isInterrupted {
                return (.interrupted, failed, toolCount)
            }
            return (failed > 0 ? .degraded : .succeeded, failed, toolCount)
        }
    }

    // Why: each read re-flattens up to `maxTimelineEvents` events plus nested capability-card events; pass the value instead
    // of re-reading.
    /// Computed summary of the timeline; read it once per body pass into a local.
    private var summary: (status: TimelineSummaryStatus, failedTools: Int, toolCount: Int) {
        Self.summarize(events: events, outcome: terminalOutcome, isInterrupted: isInterrupted)
    }

    private func summaryTint(for status: TimelineSummaryStatus) -> Color {
        switch status {
        case .succeeded: return theme.successColor
        case .degraded:  return theme.warningColor
        case .cancelled: return theme.tertiaryText
        // `warningColor` matches `InterruptedRunChip`, rendered on the next line for this state.
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
    /// A continuation's header: the stub's lead-in, then the step count.
    static func continuationTitle(lead: String, stepsCount: Int) -> String {
        guard stepsCount > 0 else { return "↳ \(lead)" }
        return "↳ \(lead) · \(stepsCount) step\(stepsCount == 1 ? "" : "s")"
    }

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

        // Runs before the zero-tool early return so an interrupted run that died before its first tool is not reported as clean.
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
            if terminalOutcome?.isFailureLike == true {
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

    /// Tool calls that only observe a background task.
    /// `stop_background_task` is excluded because it changes state and stays visible.
    private static let backgroundPollTools: Set<String> = ["get_task_output"]

    /// Drops poll rows for tasks that already have a `.backgroundTask` card.
    /// Presentation only: the events stay in `timelineEvents`, so history, resume and export are unaffected.
    /// Polls are kept when no card exists for the task.
    static func foldBackgroundTaskPolls(_ events: [TimelineEvent]) -> [TimelineEvent] {
        let carded: Set<String> = Set(events.compactMap {
            if case .backgroundTask(let data) = $0 { return data.taskID }
            return nil
        })
        guard !carded.isEmpty else { return events }

        return events.filter { event in
            guard case .toolExecution(let data) = event,
                  backgroundPollTools.contains(data.name) else { return true }
            // A `get_task_output` with no `task_id` is the list-everything form; with a card on
            // screen it is the same noise, so it folds too.
            guard let id = taskID(inParams: data.params) else { return false }
            return !carded.contains(id)
        }
    }

    // Why: parse the JSON; a substring match would also fire on a command whose text mentions a task id.
    /// Returns the task id from tool params, or nil.
    private static func taskID(inParams params: String) -> String? {
        guard let data = params.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["task_id"] as? String
    }

    /// Builds grouped timeline nodes from raw events.
    /// Runs of 2+ tools collapse into `.actionGroup`; single tools and `ask_user` always render as `.action`.
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

        // Dedup pass 1: when not streaming, hides a trailing thought/reasoning event that duplicates the final outcome below.
        // Applies only when a real final outcome exists below, so a run with no answer keeps its narrative.
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

        // Dedup pass 2: strips narrative events whose text exactly matches the final content.
        // Pass 1 misses this when a trailing "Composing final response…" thought follows the reasoning.
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

        // Pass 3: merges consecutive short status thoughts (< 100 chars, single line) into one " · "-joined row.
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
                // Reasoning reuses the `.thought` node for identical visuals; the model/system split lives at the TimelineEvent layer.
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
                // Never grouped: a grouped row collapses to a one-line summary, and this is the only place a running task is visible.
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
    // Why: render it instead of dropping it, otherwise the timeline under-reports the run and a card's nested sub-timeline
    // vanishes.
    /// An event written by a newer build that this build has no renderer for.
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
    /// The owning conversation, forwarded to `ActionDetailView` for the destination check; nil when the caller supplied none.
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
            // Chat/code bubbles show the final answer separately, so surviving thoughts are interim reasoning and render
            // de-emphasised. Workflow per-node views (`compactReasoning == false`) keep the full markdown.
            if compactReasoning {
                // `isLive` gates the sparkle's repeating animation so finished runs do not hold an animation loop.
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
    /// Where the viewer gets its content. `.inline`: the params carry the exact bytes (write tools). `.fromDisk`: read at
    /// click time, because `ToolExecutionData.output` is capped and header-decorated.
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

    /// Tools whose successful rows get a file-viewer chip: write tools open the post-write file, `read_file` opens what
    /// was read. Exposed for the drift test that ties this set to `SnapshotToolContract`.
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

    /// Resolves the viewer action from an already-parsed params dictionary. `params` nil means the params were not
    /// decodable JSON, which is reported differently from a decoded dictionary with no path.
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
        // Must match the executor's resolution: `FilePathResolver` anchors relative paths to HOME, not the process working
        // directory.
        let filePath = FilePathResolver.resolve(rawPath)
        let fileName = (filePath as NSString).lastPathComponent

        switch data.name {
        // `create_file` has the same full-post-state shape as the others and no append mode.
        case "write_file", "overwrite_file", "create_new_file", "create_file":
            guard let content = params["content"] as? String, !content.isEmpty else {
                return skip("write to '\(fileName)' carried no 'content' argument")
            }
            if data.name == "write_file", isAppendMode(params) {
                guard let pre = data.preWriteContent else {
                    guard missingBaseline == .recordFragment else {
                        return skip("append to '\(fileName)' has no pre-write snapshot, so the post-write file can't be reconstructed (file was unreadable or over the snapshot cap at capture time)")
                    }
                    // The appended fragment is exactly what was added, so `removed: 0` is true; the baseline stays "none" because the
                    // XML has no append marker.
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
            // Reads the file at click time rather than using `data.output`, which is capped and header-decorated.
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

/// `.task(id:)` key for chip resolution; changes when the tool completes, which is also when `params` is rewritten.
/// Internal so the cache rule in `ActionDetailView.primaryArgLabel` can be unit-tested.
struct TimelineChipKey: Equatable {
    let id: UUID
    let isExecuting: Bool
    let isSuccess: Bool?
}

struct ActionDetailView: View {
    let event: TimelineEvent
    /// The conversation this row was rendered for, when the caller supplied one.
    /// `openInViewer` compares it with the current conversation after its disk read; nil falls back to the in-flight check.
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

    // Why: resolving parses the full params JSON (a whole file for writes); doing it in `body` re-parses on every render pass.
    /// The resolved file-viewer action for this row, computed once in `.task` and cached here.
    @State private var resolvedAction: TimelineFileViewerAction?
    /// The row's primary-argument label with the key it was resolved for.
    /// `primaryArgLabel(cached:for:tool:params:)` falls back to a fresh parse on a key mismatch.
    @State private var primaryArgCache: (key: TimelineChipKey, label: String)?
    /// True while a `.fromDisk` row is being read after a click.
    @State private var isOpeningFromDisk = false
    /// Why the last "Open in viewer" failed, rendered under the row.
    @State private var openFailureReason: String?

    private func rowDetail(_ data: ToolExecutionData) -> TimelineRowDetail? {
        TimelineRowDetail.resolve(data)
    }

    private func isOutputExpanded(_ data: ToolExecutionData) -> Bool {
        expandedRowIDs.contains(data.id)
    }

    /// Always-visible pills for a file-touching row: the change stat, an inline diff, and affordances that open the Code
    /// Viewer. The stat and diff render from the persisted `data.effect`; "Previous version" and "Open in viewer" need
    /// `resolvedAction`, which is nil after a reload.
    @ViewBuilder
    private func fileViewerChip(data: ToolExecutionData) -> some View {
        let effect = data.effect
        let isNoOpWrite: Bool = {
            if let effect { return effect.linesAdded == 0 && effect.linesRemoved == 0 }
            return writeDiffStat.map { $0.added == 0 && $0.deleted == 0 } ?? false
        }()
        let stat: (added: Int, deleted: Int)? = effect.map { ($0.linesAdded, $0.linesRemoved) } ?? writeDiffStat
        // A persisted effect with `diff == nil` has no measured baseline (file too large or not UTF-8), so its
        // `linesRemoved: 0` is a placeholder, not a measurement.
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

    /// The change this row made, rendered from the persisted `ToolExecutionData.effect`.
    /// The same value the agent holds in episodic memory, so the row and the model describe a write identically.
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

            // Why: `currentChatMessages` still names the outgoing conversation during a switch, so the in-flight flag is checked
            // before the displayed identity.
            // Drops the open when the conversation changed while the disk read was in flight.
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

    /// Whether a completed disk read may still open a tab. Drops it while a conversation load is in flight, or when the
    /// origin differs from the current conversation; a nil origin outside a load delivers. `nonisolated static` and pure
    /// so the rule is unit-testable.
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

    /// The row label: the cached one when it was resolved for exactly `key`, a fresh parse otherwise.
    /// A miss is expected on the first body pass and after completion rewrites `params`. `nonisolated static` and pure.
    nonisolated static func primaryArgLabel(
        cached: (key: TimelineChipKey, label: String)?,
        for key: TimelineChipKey,
        tool: String,
        params: String
    ) -> String {
        if let cached, cached.key == key { return cached.label }
        return ToolArgFormatter.primaryLabel(tool: tool, params: params)
    }

    /// Whether this row needs its own measured diff, or already has the answer persisted.
    /// `fileViewerChip` reads `writeDiffStat` only for a row with no `effect`. `nonisolated static` and pure.
    nonisolated static func needsMeasuredWriteDiff(hasPersistedEffect: Bool,
                                                   action: TimelineFileViewerAction?) -> Bool {
        guard !hasPersistedEffect, let action, action.isWrite else { return false }
        return action.preWriteContent != nil && action.inlineContent != nil
    }

    /// One resolution + one stat computation + one label parse per row, keyed by the event
    /// id and completion state — off the render path entirely.
    private func resolveChip(for data: ToolExecutionData) async {
        // Label first, before any suspension: it is the cheapest and every row shows it.
        // One parse of the params is shared by the label and the chip resolution.
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
            case "list_directory", "project_tree", "batch_move_files":
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Color.blue.opacity(0.85))
                    .frame(width: 13, height: 13)
            case "grep", "grep_search", "ripgrep", "code_search", "glob_files",
                 "code_search_text", "code_search_symbol", "code_search_files", "web_search", "spotlight_search":
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
            // Resolved once per body pass: `TimelineRowDetail.resolve` scans up to 32 KB of tool output, and `LazyVStack`
            // re-runs this on scroll-in.
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

                            // Cached per key by `resolveChip`; parsed inline only on a miss (see `primaryArgLabel`).
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
                    // `.allowsHitTesting` rather than `.disabled`, which dims the label of a `.plain` button on macOS.
                    .allowsHitTesting(isDisclosable)
                    // SwiftUI has no "expanded" trait for a hand-rolled disclosure and the label is the same in both states.
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
            // Keyed on completion state: a row has no chip while executing and re-resolves when the tool finishes (when `params`
            // is rewritten).
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
                // A settled row with no reported outcome (closed by a user stop, skip, or process death) shows a muted
                // `slash.circle`, matching `CapabilityStatusIcon`; it is not a failure.
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
    /// A spinner in place of the icon, for a milestone still under way — the manual-compaction
    /// row (`ManualCompactionRow`) uses it while the summary is being written.
    var inProgress: Bool = false
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if inProgress {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: kind.icon)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(milestoneColor)
                }
            }
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
/// Strips heading markers, renders at a muted scale, and offers a collapsible tree hierarchy.
struct InterimReasoningRow: View {
    let text: String
    /// Whether the run producing this reasoning is still going.
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
                        DevgenticActivityIndicator(style: .gyroscope, size: 11, tint: theme.accentColor)
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

    /// Flattens markdown for compact display: drops heading markers, list bullets and emphasis, and collapses blank lines.
    /// Inline code is kept because paths and identifiers carry meaning.
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

    /// The footer is a progress indicator shown only while streaming; afterwards the bubble's `TokenUsageBadge` carries
    /// the summary.
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
            DevgenticActivityIndicator(style: .gyroscope, size: 12, tint: theme.streamingIndicator.opacity(0.95))

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
        // `.ignore` with a label that has no elapsed time, so VoiceOver does not re-announce the footer every second.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Streaming response")
    }
}

// MARK: - Tool Arg Formatter

/// Extracts the display-ready verb, object label and primary argument for a tool invocation.
/// Drives group-header summaries ("Read 3 files") and per-row labels; the tool-name lookups stay local to this file.
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

    /// The primary argument to surface in the row: filename for file ops, query for searches, command prefix for shell, etc.
    /// An empty string means no useful label. Parses the String form and delegates to `primaryLabel(tool:dict:)`.
    static func primaryLabel(tool: String, params: String) -> String {
        primaryLabel(tool: tool, dict: parseParams(params))
    }

    // Why: parse the params once and share the result; a detached parse would suspend before the cache is set and parse again.
    /// Returns the primary-argument label from an already-parsed params dictionary.
    static func primaryLabel(tool: String, dict: [String: Any]?) -> String {
        // `final_answer` is rendered as the assistant message below the chip; keep the chip to the "Final" verb to avoid
        // duplicating raw markdown.
        if tool == "final_answer" {
            return ""
        }

        guard let dict, !dict.isEmpty else { return "" }

        switch tool {
        // The Code profile's intent-split tools must be listed here, otherwise the fallback labels the row with an arbitrary
        // string param (often file content).
        case "read_file", "write_file", "edit_file", "edit_code", "create_file",
             "file_overview", "read_file_metadata", "watch_folder",
             "create_new_file", "overwrite_file", "edit_code_single", "edit_code_batch":
            if let p = firstString(dict, keys: ["path", "file_path"]) {
                return basename(p)
            }
        case "list_directory", "spotlight_search", "batch_move_files", "project_tree":
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
        // Retained so stored conversations that still contain this removed tool render with a proper label.
        case "recall_conversation_history":
            if let q = firstString(dict, keys: ["query", "topic"]) {
                return truncate(q, 50)
            }
        case "git":
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

        // Why: this feeds ConversationExporter, which has no redaction of its own; secret-named keys are skipped and URLs are
        // reduced by `webURLLabel`.
        // Fallback for a tool with no case above (third-party MCP tools or catalogue additions without a row here). The
        // label must be deterministic (sorted keys), never a payload value, and never a credential.
        if let identifying = firstString(dict, keys: identifyingParamKeys) {
            if let web = webURLLabel(identifying) { return web }
            return pathShaped(identifying) ? basename(identifying) : truncate(identifying, 40)
        }
        for key in dict.keys.sorted()
        where !payloadParamKeys.contains(key) && !isSecretParamName(key) {
            if let s = dict[key] as? String, !s.isEmpty {
                // `webURLLabel` applies here too: a URL can arrive under any param name and its query string must not reach the export.
                return webURLLabel(s) ?? truncate(s, 40)
            }
            if let n = dict[key] as? NSNumber {
                return n.stringValue
            }
        }
        return ""
    }

    // Why: a test holds the disjointness from the secret-key list, not code on the render path.
    /// Keys that identify what a tool acted on, tried in order before the sorted sweep.
    /// No entry may be a credential name; this branch does not consult `isSecretParamName`.
    private static let identifyingParamKeys = [
        "file_path", "path", "query", "pattern", "command", "cmd",
        "url", "endpoint", "uri", "address",
        "symbol", "name", "directory", "dir", "action"
    ]

    /// Keys whose values are content rather than identity; never used as a chip label.
    /// Covers header blobs and script bodies that could carry credentials; read only by the sorted sweep.
    private static let payloadParamKeys: Set<String> = [
        "content", "old_string", "new_string", "text", "body", "answer",
        "data", "source", "code", "edits",
        "script", "applescript", "appleScript", "sourceCode", "headers"
    ]

    // Why: false positives (`author`, `tokenizer`) are accepted; add such keys to `identifyingParamKeys` rather than
    // weakening the match.
    /// Param names whose value is a credential; the sorted sweep skips them. Derived from
    /// `TelemetrySanitizer.standardSecretKeysForEgress`, matched by normalized contains (case, `_`, `-`, `.` ignored).
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

    // Why: build the label from host, port and path only so no credential can reach it; do not rebuild it from a mutated
    // `URLComponents`.
    /// Reduces an absolute URL to `host[:port]/…/lastSegment`, or returns nil if the value is not a URL. Parses a scheme
    /// plus non-empty authority; it never reads query, fragment or userinfo.
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
        "read_file_metadata":          "Inspected",
        "watch_folder":                "Watched",
        "batch_move_files":            "Organized",
        "execute_shell":               "Ran",
        "run_shell":                   "Ran",
        "bash":                        "Ran",
        "shell":                       "Ran",
        // Retained so rows persisted with this tool name keep their label.
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
        "find_definition":             "Located",
        "file_overview":               "Analyzed",
        "project_tree":                "Mapped",
        "diff_files":                  "Diffed",
        // The Code profile's intent-split tools, labelled like their Chat-profile equivalents.
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
        "read_file_metadata": ("file", "files"),
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
        "find_definition":  ("symbol", "symbols"),
        "file_overview":    ("file", "files"),
        "project_tree":     ("codebase", "codebases"),
        "diff_files":       ("diff", "diffs"),
        "create_new_file":  ("file", "files"),
        "overwrite_file":   ("file", "files"),
        "edit_code_single": ("file", "files"),
        "edit_code_batch":  ("file", "files"),
        "code_search_text": ("match", "matches"),
        "code_search_symbol": ("symbol", "symbols"),
        "code_search_files": ("file", "files")
    ]

    // Parses a params JSON string into a dictionary for a row; `verbOverrides`/`objectOverrides` keep `edit_file`
    // because MCP servers expose it.

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
    /// `revision` proxies `events`, so the array is not compared.
    /// `finalContentText` is ignored while streaming (it changes every token and dedup is gated on `!isStreaming`).
    static func == (lhs: AgentTimelineView, rhs: AgentTimelineView) -> Bool {
        lhs.revision == rhs.revision
            && lhs.continuationLead == rhs.continuationLead
            && lhs.isStreaming == rhs.isStreaming
            && lhs.compactReasoning == rhs.compactReasoning
            && lhs.scrollable == rhs.scrollable
            // Compared so a Resume that flips `lifecycleState` without bumping `revision` cannot leave a stale interrupted header.
            && lhs.isInterrupted == rhs.isInterrupted
            && lhs.streamingContext?.startedAt == rhs.streamingContext?.startedAt
            && (lhs.isStreaming || lhs.finalContentText == rhs.finalContentText)
    }
}


// MARK: - Unrecognized Event Row

// Why: render it rather than hide it, or the timeline under-reports the run.
/// A row for a timeline event written by a newer build of Devgentic.
/// The wording says "this version" because the data is preserved on disk and only undrawable here.
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
