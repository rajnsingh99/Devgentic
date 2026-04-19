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

    /// Initialize from a ChatMessage (existing usage in chat bubbles).
    init(message: ChatMessage) {
        self.events = message.timelineEvents
        self.isStreaming = message.isStreaming
    }

    /// Initialize from raw timeline events (used by workflow per-node detail views).
    init(events: [TimelineEvent], isStreaming: Bool = false) {
        self.events = events
        self.isStreaming = isStreaming
    }

    var body: some View {
        // Compute grouped nodes inline every body pass. O(n) for n events per message
        // (typically < 30) — cheap enough that caching isn't worth the @State-in-body
        // hazard that an earlier implementation hit. SwiftUI's Identifiable diff handles
        // the ForEach efficiently across updates.
        let nodes = Self.buildGroupedNodes(from: events, isStreaming: isStreaming)
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(nodes) { node in
                    TimelineNodeGroupView(node: node)
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// Builds grouped timeline nodes from raw events.
    /// Homogeneous / heterogeneous tool runs of size 2+ collapse into `.actionGroup`.
    /// Single tools render as `.action` (no collapsible header).
    /// `ask_user` always renders as `.action` (interactive moments shouldn't hide in a group).
    static func buildGroupedNodes(from events: [TimelineEvent], isStreaming: Bool) -> [TimelineNode] {
        var events = events

        // Deduplication: if not streaming and last event is narrative (thought/reasoning),
        // hide it — it usually duplicates the final outcome shown immediately below.
        if !isStreaming, let last = events.last {
            switch last {
            case .thought, .reasoning:
                events.removeLast()
            default:
                break
            }
        }

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
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true

    var body: some View {
        switch node {
        case .thought(_, let text):
            Text(text)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText.opacity(0.9))
                .lineSpacing(3)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)

        case .capabilityMilestone(_, let kind, let detail):
            CapabilityMilestoneRow(kind: kind, detail: detail)

        case .warning(_, let category, let text):
            WarningRow(category: category, text: text)

        case .action(let event):
            ActionDetailView(event: event)
                .padding(.horizontal, 4)

        case .actionGroup(let actions):
            VStack(alignment: .leading, spacing: 6) {
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
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(actions) { action in
                            ActionDetailView(event: action)
                        }
                    }
                    .padding(.leading, 14)
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
        guard let dict = parseParams(params), !dict.isEmpty else { return "" }

        switch tool {
        case "read_file", "write_file", "edit_file", "fs_read_metadata", "fs_watch_folder":
            if let p = firstString(dict, keys: ["path", "file_path"]) {
                return basename(p)
            }
        case "list_directory", "fs_smart_search", "fs_organize_batch":
            if let p = firstString(dict, keys: ["path", "directory", "dir"]) {
                return shortPath(p)
            }
        case "grep", "grep_search", "ripgrep":
            if let q = firstString(dict, keys: ["pattern", "query", "regex"]) {
                return truncate(q, 50)
            }
        case "web_search":
            if let q = firstString(dict, keys: ["query", "q"]) {
                return truncate(q, 50)
            }
        case "run_shell", "execute_shell", "bash", "shell":
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
        "list_directory":              "Explored",
        "fs_smart_search":             "Searched",
        "fs_read_metadata":            "Inspected",
        "fs_watch_folder":             "Watched",
        "fs_organize_batch":           "Organized",
        "execute_shell":               "Ran",
        "run_shell":                   "Ran",
        "bash":                        "Ran",
        "shell":                       "Ran",
        "grep":                        "Searched",
        "grep_search":                 "Searched",
        "ripgrep":                     "Searched",
        "web_search":                  "Searched",
        "ask_user":                    "Asked",
        "call_agent":                  "Delegated",
        "recall_conversation_history": "Recalled"
    ]

    private static let objectOverrides: [String: (singular: String, plural: String)] = [
        "read_file":        ("file", "files"),
        "write_file":       ("file", "files"),
        "edit_file":        ("file", "files"),
        "list_directory":   ("directory", "directories"),
        "fs_smart_search":  ("search", "searches"),
        "fs_read_metadata": ("file", "files"),
        "execute_shell":    ("command", "commands"),
        "run_shell":        ("command", "commands"),
        "bash":             ("command", "commands"),
        "shell":            ("command", "commands"),
        "grep":             ("search", "searches"),
        "grep_search":      ("search", "searches"),
        "ripgrep":          ("search", "searches"),
        "web_search":       ("search", "searches"),
        "ask_user":         ("question", "questions"),
        "call_agent":       ("agent", "agents")
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
