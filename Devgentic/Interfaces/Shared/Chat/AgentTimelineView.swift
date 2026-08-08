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

    /// Initialize from a ChatMessage (existing usage in chat bubbles).
    init(message: ChatMessage) {
        self.events = message.timelineEvents
        self.revision = message.timelineRevision
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
        revision: UInt64 = 0,
        isStreaming: Bool = false,
        chatFidelity: Bool = false,
        streamingStartedAt: Date? = nil,
        finalContentText: String? = nil
    ) {
        self.events = events
        self.revision = revision
        self.isStreaming = isStreaming
        self.finalContentText = finalContentText
        if chatFidelity, isStreaming, let start = streamingStartedAt {
            self.streamingContext = StreamingContext(startedAt: start, isStreaming: true)
        } else {
            self.streamingContext = nil
        }
        self.compactReasoning = chatFidelity
    }

    @State private var isTimelineExpanded: Bool = false
    @State private var userToggled: Bool = false

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
        let showFooter = streamingContext?.shouldDisplay ?? false
        if !nodes.isEmpty || showFooter {
            VStack(alignment: .leading, spacing: 6) {
                // Summary Header (collapsible toggle)
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.75)) {
                        isTimelineExpanded.toggle()
                        userToggled = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isStreaming ? "sparkles" : "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(isStreaming ? theme.accentColor : theme.successColor)

                        Text(summaryTitle(nodesCount: nodes.count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.secondaryText.opacity(0.6))
                            .rotationEffect(.degrees(isTimelineExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceOverlay.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .help(isTimelineExpanded ? String(localized: "Collapse execution log") : String(localized: "Expand execution log"))
                .accessibilityLabel(isTimelineExpanded ? String(localized: "Collapse execution log") : String(localized: "Expand execution log"))

                // Expanded Nodes Content
                if isTimelineExpanded || isStreaming {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(nodes) { node in
                            TimelineNodeGroupView(
                                node: node,
                                compactReasoning: compactReasoning,
                                isStreaming: isStreaming,
                                expandedRowIDs: $expandedRowIDs
                            )
                        }
                        if let ctx = streamingContext, ctx.shouldDisplay {
                            StreamingTimelineFooter(context: ctx)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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

    private func summaryTitle(nodesCount: Int) -> String {
        if isStreaming {
            return String(localized: "Agent is thinking & executing… (\(nodesCount) step\(nodesCount == 1 ? "" : "s"))")
        } else {
            let toolCount = events.filter { event in
                switch event {
                case .toolExecution: return true
                default: return false
                }
            }.count

            if toolCount > 0 {
                return String(localized: "Executed \(nodesCount) step\(nodesCount == 1 ? "" : "s") (\(toolCount) tool\(toolCount == 1 ? "" : "s"))")
            } else {
                return String(localized: "Thought for \(nodesCount) step\(nodesCount == 1 ? "" : "s")")
            }
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
    /// Structured Plan & Execute card (step checklist with nested sub-timelines).
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
        case .action(let e):                   return e.id
        case .actionGroup(let a):              return a.first?.id ?? UUID()
        case .capabilityMilestone(let id, _, _): return id
        case .warning(let id, _, _):           return id
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

        case .unrecognized(_, let caseName):
            UnrecognizedEventRow(caseName: caseName)

        case .planCard(let data):
            PlanProgressCard(data: data, isStreaming: isStreaming)

        case .reflectionCard(let data):
            ReflectionAttemptsCard(data: data, isStreaming: isStreaming)

        case .action(let event):
            ActionDetailView(event: event, expandedRowIDs: $expandedRowIDs)
                .padding(.horizontal, 4)

        case .actionGroup(let actions):
            VStack(alignment: .leading, spacing: 2) {
                // Group header
                Button {
                    if reduceMotion {
                        isExpanded.toggle()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            isExpanded.toggle()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        // Glowing anchor dot
                        Circle()
                            .fill(theme.accentColor)
                            .frame(width: 6, height: 6)
                            .shadow(color: theme.accentColor.opacity(0.6), radius: 3)
                            .overlay(
                                Circle()
                                    .stroke(theme.accentColor.opacity(0.4), lineWidth: 2)
                                    .scaleEffect(isExpanded ? 1.4 : 1.0)
                                    .opacity(isExpanded ? 0 : 1)
                            )
                            .padding(.leading, 8)

                        Text(generateGroupTitle(actions))
                            .font(theme.fontSubheadline.weight(.medium))
                            .foregroundColor(theme.primaryText.opacity(0.9))

                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .padding(.trailing, 8)
                    }
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHoveringHeader ? theme.surfaceOverlay.opacity(0.6) : Color.clear)
                    )
                    .scaleEffect(isHoveringHeader ? 1.01 : 1.0)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isHoveringHeader = hovering
                    }
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(actions) { action in
                            ActionDetailView(event: action, expandedRowIDs: $expandedRowIDs)
                        }
                    }
                    .padding(.leading, 28)
                    .padding(.top, 4)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [theme.accentColor.opacity(0.4), theme.accentColor.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 2)
                            .padding(.leading, 10) // Centered with the 6pt dot which sits at leading 8
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
    private static let chipEligibleTools: Set<String> = [
        "write_file", "overwrite_file", "create_new_file",
        "edit_code_single", "edit_code_batch", "read_file"
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

    static func resolve(data: ToolExecutionData,
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

        guard let params = parsedParams(data.params) else {
            return skip("tool params are not decodable JSON, so the target file is unknown")
        }
        // Both spellings exist: native tools take `path`, split tools `file_path`.
        guard let rawPath = (params["path"] as? String) ?? (params["file_path"] as? String),
              !rawPath.isEmpty else {
            return skip("no 'path'/'file_path' argument — nothing to open")
        }
        let filePath = (rawPath as NSString).expandingTildeInPath
        let fileName = (filePath as NSString).lastPathComponent

        switch data.name {
        case "write_file", "overwrite_file", "create_new_file":
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
        case "edit_code_single", "edit_code_batch":
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
/// not just when a different event takes its place.
private struct TimelineChipKey: Equatable {
    let id: UUID
    let isExecuting: Bool
    let isSuccess: Bool?
}

struct ActionDetailView: View {
    let event: TimelineEvent
    @Environment(\.appTheme) private var theme
    /// Optional lookup: contexts that render timelines without a chat VM in the
    /// environment simply show no Code Viewer chip instead of crashing.
    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel: ChatHistoryViewModel?
    /// Disclosure lives in `AgentTimelineView`, keyed by `data.id` — per-row `@State` was
    /// being reset out from under the user by view-identity churn.
    @Binding var expandedRowIDs: Set<UUID>
    @State private var isHovering: Bool = false
    /// "+N −M" for successful writes with a pre-write snapshot; computed off-main once.
    @State private var writeDiffStat: (added: Int, deleted: Int)? = nil

    /// Resolution is NOT done in `body`: it JSON-parses the tool params, and a body-side
    /// call re-parsed once per row per render pass across the whole timeline. Resolved once
    /// per row in `.task(id:)` and cached here instead.
    @State private var resolvedAction: TimelineFileViewerAction?
    /// True while a `.fromDisk` row is being read after a click.
    @State private var isOpeningFromDisk = false

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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    if let stat {
                        if isNoOpWrite {
                            Text(String(localized: "No changes"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                        } else if !hasBaseline {
                            Text(String(localized: "Wrote \(stat.added) lines — no baseline"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.tertiaryText)
                                .help(String(localized: "The file couldn't be captured before the write (too large, or not readable as text), so what this replaced can't be shown."))
                                .accessibilityLabel(String(localized: "Wrote \(stat.added) lines; no baseline, so the replaced content is unknown"))
                        } else {
                            HStack(spacing: 3) {
                                Text("+\(stat.added)").foregroundColor(theme.successColor)
                                Text("−\(stat.deleted)").foregroundColor(theme.errorColor)
                            }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        }
                    }

                    // No "Show diff" toggle: the diff IS the row's output, so the row's own
                    // chevron discloses it — the same one control a read row uses.

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
                            Text(String(localized: "Previous version"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(theme.secondaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.surfaceOverlay.opacity(0.6)))
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
                            HStack(spacing: 3) {
                                if isOpeningFromDisk {
                                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                                } else {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                Text(String(localized: "Open in viewer"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
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
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    diffLine(line)
                }
                if effect.isTruncated {
                    // Never let a partial change read as the whole one.
                    Text(String(localized: "Diff truncated — open the previous version to see everything."))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.surfaceOverlay.opacity(0.5)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.secondaryText.opacity(0.12), lineWidth: 1)
            )
        }
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
        let path = action.filePath
        Task {
            let content = await Task.detached(priority: .userInitiated) {
                try? String(contentsOfFile: path, encoding: .utf8)
            }.value
            isOpeningFromDisk = false
            guard let content, !content.isEmpty else {
                timelineLogger.warning("[CodeViewer] Timeline open of '\(path)' failed — unreadable or gone since the agent read it; nothing opened.")
                return
            }
            viewModel.openTimelineFileInCodeViewer(
                fileName: action.fileName,
                filePath: path,
                content: content
            )
        }
    }

    /// One resolution + one stat computation per row, keyed by the event id — off the
    /// render path entirely.
    private func resolveChip(for data: ToolExecutionData) async {
        let action = TimelineFileViewerAction.resolve(data: data)
        resolvedAction = action

        guard let action, action.isWrite,
              let pre = action.preWriteContent,
              let content = action.inlineContent else { return }
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

    var body: some View {
        if case .toolExecution(let data) = event {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    actionRowButton(data: data)
                    fileViewerChip(data: data)
                }

                // Disclosed by the row's own chevron, exactly like a read's content —
                // collapsed by default, one tap to reveal.
                if isOutputExpanded(data), let detail = rowDetail(data) {
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
            }
            // Keyed on the completion state too: a row resolves to no chip while the tool
            // is still executing, and must re-resolve once it finishes.
            .task(id: TimelineChipKey(id: data.id, isExecuting: data.isExecuting, isSuccess: data.isSuccess)) {
                await resolveChip(for: data)
            }
        }
    }

    @ViewBuilder
    private func expandedOutput(_ out: String) -> some View {
        Text(out)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(theme.primaryText.opacity(0.72))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.surfaceOverlay.opacity(0.3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
                    )
            )
            .padding(.leading, 6)
            .transition(.opacity)
    }

    private func actionRowButton(data: ToolExecutionData) -> some View {
                // ONE predicate for the chevron, the hit target and the hover affordance.
                // A row is not disclosable while it executes (no output yet, no effect yet),
                // and letting it highlight + scale under the pointer advertised a tap that
                // silently did nothing for the whole duration of every tool call.
                let isDisclosable = rowDetail(data) != nil && !data.isExecuting
                let isExpanded = isOutputExpanded(data)
                return Button {
                    guard isDisclosable else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expandedRowIDs.contains(data.id) {
                            expandedRowIDs.remove(data.id)
                        } else {
                            expandedRowIDs.insert(data.id)
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
                            Text(DurationFormat.milliseconds(dur))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.tertiaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(theme.surfaceOverlay.opacity(0.5)))
                        }

                        Spacer(minLength: 4)

                        statusIcon(data: data)

                        if isDisclosable {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(theme.tertiaryText)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                // Decorative: its rotation is the sighted cue for the state
                                // that `.accessibilityValue` announces below.
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering && isDisclosable ? theme.surfaceOverlay.opacity(0.7) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .scaleEffect(isHovering && isDisclosable ? 1.01 : 1.0)
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
                .onHover { hovering in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        isHovering = hovering
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
                    .padding(4)
                    .background(Circle().fill(success ? theme.streamingIndicator.opacity(0.12) : theme.surfaceOverlay))
            } else if success {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(theme.successColor.opacity(0.85))
                    .padding(4)
                    .background(Circle().fill(theme.successColor.opacity(0.12)))
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
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(theme.errorColor.opacity(0.12))
                )
            }
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [milestoneColor.opacity(0.12), milestoneColor.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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

            Text(category.displayName.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.orange.opacity(0.95))
                .tracking(0.4)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.orange.opacity(0.18)))

            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.primaryText.opacity(0.85))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 0.5)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var isAnimating = false

    private static let collapsedLineLimit = 3
    private static let expandThresholdChars = 220

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.accentColor.opacity(0.85))
                .frame(width: 14, alignment: .center)
                .padding(.top, 3)
                .symbolEffect(.pulse, options: .repeating, isActive: isAnimating && !reduceMotion)

            VStack(alignment: .leading, spacing: 4) {
                Text(flattenedText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.secondaryText.opacity(0.9))
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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.accentColor.opacity(0.85))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
        )
        .onAppear { isAnimating = true }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.streamingIndicator.opacity(0.95))
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
        .padding(.horizontal, 4)
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

    /// SF Symbol for a tool. Single vocabulary for every per-tool glyph, so rendering
    /// paths can't drift. Superset of the old `ToolChipView.iconForTool` switch, which
    /// went with the dynamic island in 2026-07.
    static func icon(tool: String) -> String {
        iconOverrides[tool] ?? "hammer.fill"
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
        // `recall_conversation_history` no longer exists — the tool was dropped from dispatch as
        // redundant with the RAG pipeline, and its struct deleted 2026-07-31. This case and its
        // label/icon entries are kept deliberately: stored conversations from before the removal
        // still contain calls to it, and this view renders history. Deleting these would make
        // those old turns fall back to a generic label for no gain.
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

    private static let iconOverrides: [String: String] = [
        "read_file":                   "doc.text.fill",
        "file_overview":               "doc.text.magnifyingglass",
        "write_file":                  "square.and.pencil",
        "edit_file":                   "pencil.circle.fill",
        "edit_code":                   "pencil.circle.fill",
        "create_file":                 "doc.badge.plus",
        "delete_file":                 "trash.fill",
        "list_directory":              "folder.fill",
        "codebase_map":                "map.fill",
        "fs_smart_search":             "magnifyingglass",
        "fs_read_metadata":            "info.circle.fill",
        "fs_watch_folder":            "eye.fill",
        "fs_organize_batch":           "square.grid.3x3.fill",
        "grep":                        "magnifyingglass",
        "grep_search":                 "magnifyingglass",
        "ripgrep":                     "magnifyingglass",
        "code_search":                 "magnifyingglass",
        "glob_files":                  "doc.on.doc",
        "web_search":                  "globe",
        "execute_shell":               "terminal.fill",
        "run_shell":                   "terminal.fill",
        "bash":                        "terminal.fill",
        "shell":                       "terminal.fill",
        "batch_command":               "terminal.fill",
        "ask_user":                    "person.fill.questionmark",
        "call_agent":                  "person.line.dotted.person.fill",
        "recall_conversation_history": "clock.arrow.circlepath",
        "git_tool":                    "arrow.triangle.branch",
        "find_definition":             "curlybraces",
        "diff_files":                  "plusminus"
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
            Text("This version can't display this step (\(caseName)). It's kept and will appear in a newer version.")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
    }
}
