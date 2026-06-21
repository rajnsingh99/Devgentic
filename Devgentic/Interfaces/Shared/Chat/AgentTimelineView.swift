//
//  AgentTimelineView.swift
//  Devgentic
//

import SwiftUI

struct AgentTimelineView: View {
    /// The timeline events to render. Can come from a ChatMessage or directly from
    /// a workflow node's per-node timeline (`WorkflowExecutionState.nodeTimelines[nodeID]`).
    private let events: [TimelineEvent]
    private let isStreaming: Bool

    @Environment(\.appTheme) private var theme

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

    /// Initialize from a ChatMessage (existing usage in chat bubbles).
    init(message: ChatMessage) {
        self.events = message.timelineEvents
        self.isStreaming = message.isStreaming
        self.finalContentText = message.currentAgentContent?.textContent ?? message.content.textContent
        self.streamingContext = StreamingContext(
            startedAt: message.timestamp,
            isStreaming: message.isStreaming
        )
        self.compactReasoning = true
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
    init(
        events: [TimelineEvent],
        isStreaming: Bool = false,
        chatFidelity: Bool = false,
        streamingStartedAt: Date? = nil,
        finalContentText: String? = nil
    ) {
        self.events = events
        self.isStreaming = isStreaming
        self.finalContentText = finalContentText
        if chatFidelity, isStreaming, let start = streamingStartedAt {
            self.streamingContext = StreamingContext(startedAt: start, isStreaming: true)
        } else {
            self.streamingContext = nil
        }
        self.compactReasoning = chatFidelity
    }

    var body: some View {
        // Compute grouped nodes inline every body pass. O(n) for n events per message
        // (typically < 30) — cheap enough that caching isn't worth the @State-in-body
        // hazard that an earlier implementation hit. SwiftUI's Identifiable diff handles
        // the ForEach efficiently across updates.
        let nodes = Self.buildGroupedNodes(
            from: events,
            isStreaming: isStreaming,
            finalContentText: finalContentText
        )
        let showFooter = streamingContext?.shouldDisplay ?? false
        if !nodes.isEmpty || showFooter {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(nodes) { node in
                    TimelineNodeGroupView(node: node, compactReasoning: compactReasoning)
                }
                if let ctx = streamingContext, ctx.shouldDisplay {
                    StreamingTimelineFooter(context: ctx)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
        }
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

        // Deduplication pass 1: if not streaming and last event is narrative
        // (thought/reasoning), hide it — it usually duplicates the final outcome
        // shown immediately below.
        if !isStreaming, let last = events.last {
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
                nodes.append(.thought(id: id, text: text))

            case .reasoning(let id, let text):
                // Reasoning reuses the `.thought` timeline node for identical visual
                // treatment. The semantic split lives at the TimelineEvent layer so
                // analytics / scratchpad paths can distinguish model vs. system prose.
                flushActions()
                nodes.append(.thought(id: id, text: text))

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

            case .capabilityMilestone(let id, let kind, let detail):
                flushActions()
                nodes.append(.capabilityMilestone(id: id, kind: kind, detail: detail))

            case .warning(let id, let category, let text):
                flushActions()
                nodes.append(.warning(id: id, category: category, text: text))
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
            let shortStatus: (UUID, String)? = {
                switch event {
                case .thought(let id, let text) where isShortStatusText(text):
                    return (id, text)
                case .reasoning(let id, let text) where isShortStatusText(text):
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
}

// MARK: - Models

enum TimelineNode: Identifiable {
    case thought(id: UUID, text: String)
    /// A single tool invocation rendered inline (no collapsible header).
    case action(TimelineEvent)
    /// Two or more tool invocations collapsed into a header + expandable detail list.
    case actionGroup([TimelineEvent])
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)
    case warning(id: UUID, category: WarningCategory, text: String)

    var id: UUID {
        switch self {
        case .thought(let id, _):              return id
        case .action(let e):                   return e.id
        case .actionGroup(let a):              return a.first?.id ?? UUID()
        case .capabilityMilestone(let id, _, _): return id
        case .warning(let id, _, _):           return id
        }
    }
}

// MARK: - Subviews

struct TimelineNodeGroupView: View {
    let node: TimelineNode
    /// When true, thought/reasoning nodes render in a muted compact row.
    /// See `AgentTimelineView.compactReasoning` for the rationale.
    var compactReasoning: Bool = false

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true

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
                InterimReasoningRow(text: text)
            } else {
                WorkflowMarkdownView(text: text)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .capabilityMilestone(_, let kind, let detail):
            CapabilityMilestoneRow(kind: kind, detail: detail)

        case .warning(_, let category, let text):
            WarningRow(category: category, text: text)

        case .action(let event):
            ActionDetailView(event: event)
                .padding(.horizontal, 4)

        case .actionGroup(let actions):
            // Tight inner spacing (2pt) so the rail connects visually to the
            // chevron above. The outer timeline VStack still provides 10pt
            // separation between this group and sibling nodes.
            VStack(alignment: .leading, spacing: 2) {
                // Group header — click toggles the collapsible detail list.
                Button {
                    if reduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))

                        Text(generateGroupTitle(actions))
                            .font(theme.fontSubheadline.weight(.medium))
                            .foregroundColor(theme.secondaryText)

                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    // Rail is rendered as an overlay on the children VStack so it
                    // physically can't exceed the VStack's intrinsic height. An
                    // earlier HStack-with-Rectangle approach let the rail stretch
                    // into whatever vertical space the parent bubble offered —
                    // showing a long hanging tail past the last child whenever
                    // the bubble was taller than the timeline content.
                    //
                    // • `.padding(.leading, 22)` reserves rail space (8pt rail x
                    //   + 1pt width + 13pt gutter).
                    // • `.overlay(alignment: .leading)` pins the rail to the VStack's
                    //   left edge and height — it starts at y=0 (top of first row)
                    //   and ends at y=height (bottom of last row), no tail.
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(actions) { action in
                            ActionDetailView(event: action)
                        }
                    }
                    .padding(.leading, 22)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(theme.tertiaryText.opacity(0.35))
                            .frame(width: 1)
                            .padding(.leading, 8)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    /// Builds a Claude-Code-style group title by bucketing tool invocations by name,
    /// then rendering "<primary bucket>, <minor>, <minor>..." with natural pluralization.
    /// Mixed groups: "Read 6 files, edited 2 files, used a tool".
    private func generateGroupTitle(_ actions: [TimelineEvent]) -> String {
        guard !actions.isEmpty else { return "Action Group" }

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

struct ActionDetailView: View {
    let event: TimelineEvent
    @Environment(\.appTheme) private var theme
    @State private var isOutputExpanded: Bool = false

    var body: some View {
        if case .toolExecution(let data) = event {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    if let out = data.output, !out.isEmpty {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isOutputExpanded.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(ToolArgFormatter.verb(tool: data.name))
                            .font(theme.fontSubheadline)
                            .foregroundColor(theme.secondaryText)

                        let primaryArg = ToolArgFormatter.primaryLabel(tool: data.name, params: data.params)
                        if !primaryArg.isEmpty {
                            Text(primaryArg)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(theme.primaryText.opacity(0.9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        if let dur = data.durationMs, dur >= 100 {
                            Text(Self.formatDuration(dur))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                        }

                        Spacer(minLength: 4)

                        statusIcon(data: data)

                        if let out = data.output, !out.isEmpty, !data.isExecuting {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(isOutputExpanded ? 90 : 0))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOutputExpanded, let out = data.output, !out.isEmpty {
                    Text(out)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText.opacity(0.72))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(theme.surfaceOverlay.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(data: ToolExecutionData) -> some View {
        if data.isExecuting {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else if let success = data.isSuccess {
            if data.name == "ask_user" {
                Image(systemName: success ? "bubble.left.fill" : "arrow.uturn.left")
                    .font(.system(size: 10))
                    .foregroundColor(success ? theme.streamingIndicator.opacity(0.85) : theme.secondaryText.opacity(0.5))
            } else if success {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(theme.successColor.opacity(0.85))
            } else {
                HStack(spacing: 3) {
                    Image(systemName: data.failureCategory?.icon ?? "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(theme.errorColor)
                    if let cat = data.failureCategory {
                        Text(cat.displayName.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.errorColor.opacity(0.85))
                            .tracking(0.3)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(theme.errorColor.opacity(0.12))
                            )
                    }
                }
            }
        }
    }

    private static func formatDuration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        let s = Double(ms) / 1000.0
        return String(format: "%.1fs", s)
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
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(milestoneColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(milestoneColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var milestoneColor: Color {
        switch kind.colorCategory {
        case .planning:   return .blue
        case .reflection: return .purple
        case .delegation: return .green
        case .compaction: return .orange
        }
    }
}

// MARK: - Warning Row

struct WarningRow: View {
    let category: WarningCategory
    let text: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: category.icon)
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(.orange)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.orange.opacity(0.9))
                    .tracking(0.5)

                Text(text)
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Interim Reasoning Row

/// Compact display for `.thought`/`.reasoning` nodes inside a chat/code bubble.
/// Strips heading markers (so `# Summary` doesn't render as an H1 competing with
/// the final answer), renders at a muted scale, and collapses anything over a
/// few lines behind a "Show more" toggle.
struct InterimReasoningRow: View {
    let text: String

    @Environment(\.appTheme) private var theme
    @State private var isExpanded = false

    private static let collapsedLineLimit = 3
    private static let expandThresholdChars = 220

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 14, alignment: .center)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(flattenedText)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    // NB: no `.fixedSize(vertical: true)` — it overrides `lineLimit`
                    // by forcing the text to reserve space for every line of content.

                if needsExpandToggle {
                    Button(isExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentColor.opacity(0.75))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
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

    private var needsExpandToggle: Bool {
        flattenedText.count > Self.expandThresholdChars
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.streamingIndicator.opacity(0.95))
                .symbolEffect(.pulse, options: .repeating, isActive: context.isStreaming)

            // TimelineView re-renders once per second while visible and stops
            // when off-screen — cheaper than a Timer and auto-cleans on removal.
            TimelineView(.periodic(from: context.startedAt, by: 1.0)) { timeline in
                Text(Self.formatElapsed(from: context.startedAt, to: timeline.date))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Streaming, \(Self.formatElapsed(from: context.startedAt, to: Date()))")
    }

    private static func formatElapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return remaining == 0 ? "\(minutes)m" : "\(minutes)m \(remaining)s"
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
    static func primaryLabel(tool: String, params: String) -> String {
        // `final_answer` is a terminal signal — its `answer` arg is rendered as the
        // assistant's final message directly below this chip. Surfacing the answer
        // text in the chip duplicates it and leaks raw markdown (`###`, `**`, etc.)
        // into a non-rendering label. Keep the chip terse — just the "Final" verb.
        if tool == "final_answer" {
            return ""
        }

        guard let dict = parseParams(params), !dict.isEmpty else { return "" }

        switch tool {
        case "read_file", "write_file", "edit_file", "edit_code", "create_file",
             "file_overview", "fs_read_metadata", "fs_watch_folder":
            if let p = firstString(dict, keys: ["path", "file_path"]) {
                return basename(p)
            }
        case "list_directory", "fs_smart_search", "fs_organize_batch", "codebase_map":
            if let p = firstString(dict, keys: ["path", "directory", "dir"]) {
                return shortPath(p)
            }
        case "grep", "grep_search", "ripgrep", "code_search", "glob_files":
            if let q = firstString(dict, keys: ["pattern", "query", "regex"]) {
                return truncate(q, 50)
            }
        case "web_search":
            if let q = firstString(dict, keys: ["query", "q"]) {
                return truncate(q, 50)
            }
        case "run_shell", "execute_shell", "bash", "shell", "batch_command":
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
        case "recall_conversation_history":
            if let q = firstString(dict, keys: ["query", "topic"]) {
                return truncate(q, 50)
            }
        case "git_tool":
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

        // Fallback: first scalar string or number value.
        for (_, v) in dict {
            if let s = v as? String, !s.isEmpty {
                return truncate(s, 40)
            }
            if let n = v as? NSNumber {
                return n.stringValue
            }
        }
        return ""
    }

    // MARK: - Tables

    private static let verbOverrides: [String: String] = [
        "read_file":                   "Read",
        "write_file":                  "Wrote",
        "edit_file":                   "Edited",
        "edit_code":                   "Edited",
        "create_file":                 "Created",
        "list_directory":              "Explored",
        "fs_smart_search":             "Searched",
        "fs_read_metadata":            "Inspected",
        "fs_watch_folder":             "Watched",
        "fs_organize_batch":           "Organized",
        "execute_shell":               "Ran",
        "run_shell":                   "Ran",
        "bash":                        "Ran",
        "shell":                       "Ran",
        "batch_command":               "Ran",
        "grep":                        "Searched",
        "grep_search":                 "Searched",
        "ripgrep":                     "Searched",
        "code_search":                 "Searched",
        "glob_files":                  "Found",
        "web_search":                  "Searched",
        "ask_user":                    "Asked",
        "call_agent":                  "Delegated",
        "recall_conversation_history": "Recalled",
        "git_tool":                    "Git",
        "find_definition":             "Located",
        "file_overview":               "Analyzed",
        "codebase_map":                "Mapped",
        "diff_files":                  "Diffed"
    ]

    private static let objectOverrides: [String: (singular: String, plural: String)] = [
        "read_file":        ("file", "files"),
        "write_file":       ("file", "files"),
        "edit_file":        ("file", "files"),
        "edit_code":        ("file", "files"),
        "create_file":      ("file", "files"),
        "list_directory":   ("directory", "directories"),
        "fs_smart_search":  ("search", "searches"),
        "fs_read_metadata": ("file", "files"),
        "execute_shell":    ("command", "commands"),
        "run_shell":        ("command", "commands"),
        "bash":             ("command", "commands"),
        "shell":            ("command", "commands"),
        "batch_command":    ("command", "commands"),
        "grep":             ("search", "searches"),
        "grep_search":      ("search", "searches"),
        "ripgrep":          ("search", "searches"),
        "code_search":      ("match", "matches"),
        "glob_files":       ("match", "matches"),
        "web_search":       ("search", "searches"),
        "ask_user":         ("question", "questions"),
        "call_agent":       ("agent", "agents"),
        "git_tool":         ("operation", "operations"),
        "find_definition":  ("symbol", "symbols"),
        "file_overview":    ("file", "files"),
        "codebase_map":     ("codebase", "codebases"),
        "diff_files":       ("diff", "diffs")
    ]

    // MARK: - Helpers

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
