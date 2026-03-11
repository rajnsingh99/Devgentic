//
//  AgentTimelineView.swift
//  Devgentic
//

import SwiftUI

struct AgentTimelineView: View {
    @ObservedObject var message: ChatMessage
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        if !message.timelineEvents.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groupedNodes) { node in
                    TimelineNodeGroupView(node: node)
                }
            }
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Grouping Logic
    
    private var groupedNodes: [TimelineNode] {
        var events = message.timelineEvents
        
        // Deduplication: If not streaming and last event is a thought, hide it
        // as it usually duplicates the final outcome shown immediately below.
        if !message.isStreaming, let last = events.last, case .thought = last {
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
    
    var id: UUID {
        switch self {
        case .thought(let id, _): return id
        case .actionGroup(let actions): return actions.first?.id ?? UUID()
        }
    }
}

// MARK: - Subviews

struct TimelineNodeGroupView: View {
    let node: TimelineNode
    @Environment(\.appTheme) private var theme
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
                
        case .actionGroup(let actions):
            VStack(alignment: .leading, spacing: 8) {
                // Group Header
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
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
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }
    
    private func generateGroupTitle(_ actions: [TimelineEvent]) -> String {
        guard !actions.isEmpty else { return "Action Group" }
        
        // Single action case
        if actions.count == 1 {
            if case .toolExecution(_, let name, _, _, _, _) = actions[0] {
                return formatToolName(name)
            }
        }
        
        // Multiple actions - try to find common category
        let tools = actions.compactMap { (event: TimelineEvent) -> String? in
            if case .toolExecution(_, let name, _, _, _, _) = event { return name }
            return nil
        }
        
        let uniqueTools = Set(tools)
        if uniqueTools.count == 1, let first = uniqueTools.first {
            return "\(formatToolName(first)) \(actions.count) times"
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
        if case .toolExecution(_, let name, let params, let output, let isSuccess, let isExecuting) = event {
            VStack(alignment: .leading, spacing: 6) {
                // Tool Execution Row
                HStack(alignment: .top, spacing: 8) {
                    Text(name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(theme.fontCode.weight(.medium))
                        .foregroundColor(theme.secondaryText)
                    
                    if !params.isEmpty && params != "{}" {
                        ParameterPillsView(params: params)
                    }
                    
                    if isExecuting {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    } else if let success = isSuccess {
                        Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(success ? theme.successColor.opacity(0.8) : theme.errorColor)
                    }
                }
                
                // Indented Observation Result
                if let out = output, !out.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(out)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.primaryText.opacity(0.7))
                            .lineLimit(isOutputExpanded ? nil : 2)
                            .multilineTextAlignment(.leading)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceOverlay.opacity(0.4))
                            .cornerRadius(4)
                        
                        // Small "More" button for long outputs
                        if out.count > 150 {
                            Button {
                                withAnimation { isOutputExpanded.toggle() }
                            } label: {
                                Text(isOutputExpanded ? "Show less" : "Show more")
                                    .font(.system(size: 10, weight: .bold))
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
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.tertiaryText.opacity(0.1))
                    .foregroundColor(theme.secondaryText)
                    .cornerRadius(4)
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
