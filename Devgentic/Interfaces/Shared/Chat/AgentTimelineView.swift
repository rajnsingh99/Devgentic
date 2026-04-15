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

    /// Cached grouped nodes — avoids O(n) re-grouping on every body evaluation during streaming.
    @State private var cachedNodes: [TimelineNode] = []

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
        if !cachedNodes.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(cachedNodes) { node in
                    TimelineNodeGroupView(node: node)
                }
            }
            .padding(.vertical, 12)
        }

        // Rebuild cached nodes when events change (count is a cheap proxy).
        let _ = updateNodesIfNeeded()
    }

    // MARK: - Grouping Logic

    /// Triggers cache rebuild when the event count changes.
    /// Uses a side-effect in body to keep cache in sync without a separate onChange.
    private func updateNodesIfNeeded() {
        let currentCount = events.count
        // Rebuild if count changed or streaming state toggled (deduplication logic differs)
        if cachedNodes.isEmpty || currentCount != cachedNodeEventCount(cachedNodes, isStreaming: isStreaming) {
            cachedNodes = Self.buildGroupedNodes(from: events, isStreaming: isStreaming)
        }
    }

    /// Returns the expected event count for the current cached state.
    private func cachedNodeEventCount(_ nodes: [TimelineNode], isStreaming: Bool) -> Int {
        var count = 0
        for node in nodes {
            switch node {
            case .thought: count += 1
            case .actionGroup(let actions): count += actions.count
            case .capabilityMilestone: count += 1
            }
        }
        // Account for the deduplication removal of last thought when not streaming
        if !isStreaming, let last = events.last, case .thought = last {
            count += 1 // The cached version has one fewer
        }
        return count
    }

    /// Builds grouped timeline nodes from raw events.
    /// Extracted as static for testability. Called from the view body cache.
    static func buildGroupedNodes(from events: [TimelineEvent], isStreaming: Bool) -> [TimelineNode] {
        var events = events

        // Deduplication: If not streaming and last event is a thought, hide it
        // as it usually duplicates the final outcome shown immediately below.
        if !isStreaming, let last = events.last, case .thought = last {
            events.removeLast()
        }

        var nodes: [TimelineNode] = []
        var currentActionGroup: [TimelineEvent] = []

        for event in events {
            switch event {
            case .thought(let id, let text):
                if !currentActionGroup.isEmpty {
                    nodes.append(.actionGroup(currentActionGroup))
                    currentActionGroup = []
                }
                nodes.append(.thought(id: id, text: text))

            case .toolExecution:
                currentActionGroup.append(event)

            case .mediaGeneration:
                currentActionGroup.append(event)

            case .capabilityMilestone(let id, let kind, let detail):
                if !currentActionGroup.isEmpty {
                    nodes.append(.actionGroup(currentActionGroup))
                    currentActionGroup = []
                }
                nodes.append(.capabilityMilestone(id: id, kind: kind, detail: detail))
            }
        }

        if !currentActionGroup.isEmpty {
            nodes.append(.actionGroup(currentActionGroup))
        }

        return nodes
    }
}

// MARK: - Models

enum TimelineNode: Identifiable {
    case thought(id: UUID, text: String)
    case actionGroup([TimelineEvent])
    case capabilityMilestone(id: UUID, kind: CapabilityMilestoneKind, detail: String)

    var id: UUID {
        switch self {
        case .thought(let id, _): return id
        case .actionGroup(let actions): return actions.first?.id ?? UUID()
        case .capabilityMilestone(let id, _, _): return id
        }
    }
}

// MARK: - Subviews

struct TimelineNodeGroupView: View {
    let node: TimelineNode
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool = true // Default expanded for fresh logs
    
    var body: some View {
        switch node {
        case .thought(_, let text):
            Text(text)
                .font(theme.fontBody)
                .foregroundColor(theme.primaryText.opacity(0.9))
                .lineSpacing(4)
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)

        case .capabilityMilestone(_, let kind, let detail):
            CapabilityMilestoneRow(kind: kind, detail: detail)

        case .actionGroup(let actions):
            VStack(alignment: .leading, spacing: 8) {
                // Group Header
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
                        Image(systemName: "chevron.right")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        
                        Text(generateGroupTitle(actions))
                            .font(theme.fontSubheadline.weight(.medium))
                            .foregroundColor(theme.secondaryText)
                        
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                
                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(actions) { action in
                            ActionDetailView(event: action)
                        }
                    }
                    .padding(.leading, 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
    
    private func generateGroupTitle(_ actions: [TimelineEvent]) -> String {
        guard !actions.isEmpty else { return "Action Group" }
        
        // Single action case
        if actions.count == 1 {
            if case .toolExecution(let data) = actions[0] {
                return formatToolName(data.name)
            }
        }

        // Multiple actions — check if all use the same tool (common case).
        // Early-exit avoids building intermediate arrays/Sets for uniform groups.
        var firstName: String?
        var allSame = true
        for action in actions {
            if case .toolExecution(let data) = action {
                if let first = firstName {
                    if data.name != first { allSame = false; break }
                } else {
                    firstName = data.name
                }
            }
        }

        if allSame, let name = firstName {
            return "\(formatToolName(name)) \(actions.count) times"
        }

        return "Executed \(actions.count) tools"
    }
    
    private func formatToolName(_ name: String) -> String {
        // 1. Check for specific overrides for the most common tools
        let overrides: [String: String] = [
            "list_directory": "Explore directory",
            "read_file": "Read file",
            "write_file": "Write file",
            "execute_shell": "Run command",
            "web_search": "Search web",
            "grep_search": "Grep patterns",
            "recall_conversation_history": "Recall history"
        ]
        
        if let override = overrides[name] {
            return override
        }
        
        // 2. Rule-based: Handling verb_noun format
        let components = name.lowercased().split(separator: "_")
        if components.count >= 2 {
            let verb = String(components[0]).capitalized
            let rest = components.dropFirst().joined(separator: " ")
            
            // Common developer tool verbs we can format nicely
            let actionVerbs = ["List", "Read", "Write", "Run", "Search", "Get", "Post", "Delete", "Create", "Explore", "Fetch"]
            if actionVerbs.contains(verb) {
                return "\(verb) \(rest)"
            }
        }
        
        // 3. Fallback: Pretty-print the identifier
        return name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct ActionDetailView: View {
    let event: TimelineEvent
    @Environment(\.appTheme) private var theme
    @State private var isOutputExpanded: Bool = false
    
    var body: some View {
        if case .toolExecution(let data) = event {
            VStack(alignment: .leading, spacing: 6) {
                // Tool Execution Row
                HStack(alignment: .top, spacing: 8) {
                    Text(data.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(theme.fontCode.weight(.medium))
                        .foregroundColor(theme.secondaryText)

                    if !data.params.isEmpty && data.params != "{}" {
                        ParameterPillsView(params: data.params)
                    }
                    
                    if data.isExecuting {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if let success = data.isSuccess {
                        if data.name == "ask_user" {
                            // send = user answered, deny/skip = user skipped
                            Image(systemName: success ? "bubble.left.fill" : "arrow.uturn.left")
                                .font(.system(.caption2))
                                .foregroundColor(success ? theme.streamingIndicator.opacity(0.8) : theme.secondaryText.opacity(0.5))
                        } else {
                            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(.caption2))
                                .foregroundColor(success ? theme.successColor.opacity(0.8) : theme.errorColor)
                        }
                    }
                }

                // Indented Observation Result
                if let out = data.output, !out.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(out)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.primaryText.opacity(0.7))
                            .lineLimit(isOutputExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceOverlay.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        
                        // Small "More" button for long outputs
                        if out.count > 150 {
                            Button {
                                withAnimation { isOutputExpanded.toggle() }
                            } label: {
                                Text(isOutputExpanded ? "Show less" : "Show more")
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundColor(theme.accentColor.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 4)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
        }
    }
}

struct ParameterPillsView: View {
    let params: String
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        let items = parseParams(params)
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.tertiaryText.opacity(0.1))
                    .foregroundColor(theme.secondaryText)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
            }
        }
    }
    
    private func parseParams(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        
        // Extract meaningful values (first few keys)
        return dict.prefix(2).compactMap { key, value in
            let valStr = String(describing: value)
            if valStr.count > 25 {
                return "\(key): \(valStr.prefix(22))..."
            }
            return "\(key): \(valStr)"
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
        case .planning: return .blue
        case .reflection: return .purple
        case .delegation: return .green
        case .compaction: return .orange
        }
    }
}
