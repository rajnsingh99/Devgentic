//
//  EventTimelineView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Redesigned: compact table rows, error highlighting, better density.
//

import SwiftUI

struct EventTimelineView: View {
    let events: [SpanEvent]
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            if events.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(events) { event in
                        EventRow(event: event, theme: theme)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 24)) // Fixed size: icon frame ≥24pt
                .foregroundStyle(theme.tertiaryText)
            Text("No events to display")
                .font(theme.fontSubheadline)
                .foregroundStyle(theme.secondaryText)
            Text("Select a span or adjust filters")
                .font(.system(.caption))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Compact Event Row

private struct EventRow: View {
    let event: SpanEvent
    let theme: any Theme

    @State private var isExpanded: Bool = false

    private var isError: Bool {
        event.severity == .error || event.eventType == .parseError || event.eventType == .error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .top, spacing: 8) {
                // Error indicator — left edge stripe
                if isError {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.errorColor)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                }

                // Timestamp
                Text(timeString)
                    .font(.system(size: 10, design: .monospaced)) // Fixed size: monospaced design
                    .foregroundStyle(theme.tertiaryText)
                    .frame(width: 72, alignment: .leading)
                    .padding(.top, 1)

                // Type badge
                typeBadge

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.content ?? "—")
                        .font(.system(.caption))
                        .foregroundStyle(isError ? theme.errorColor : theme.primaryText)
                        .lineLimit(isExpanded ? nil : 2)

                    // Expandable detail
                    if event.detailJSON != nil {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold)) // Fixed size: badge chip ≤9pt
                                Text("details")
                                    .font(.system(.caption2))
                            }
                            .foregroundStyle(theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                // Severity dot
                Circle()
                    .fill(severityColor)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isError ? theme.errorColor.opacity(0.04) : Color.clear)

            // Expanded detail JSON
            if isExpanded, let details = event.detailJSON {
                Text(formatJSON(details))
                    .font(.system(size: 11, design: .monospaced)) // Fixed size: monospaced design
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.secondaryBackground.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            // Subtle row divider
            Divider()
                .background(theme.dividerColor.opacity(0.5))
                .padding(.leading, isError ? 15 : 12)
        }
    }

    // MARK: - Type Badge

    private var typeBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: typeIcon)
                .font(.system(size: 8)) // Fixed size: badge chip ≤9pt
            Text(typeLabel)
                .font(.system(size: 9, weight: .semibold)) // Fixed size: badge chip ≤9pt
        }
        .foregroundStyle(typeColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(typeColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .frame(width: 80, alignment: .leading)
    }

    private var typeLabel: String {
        switch event.eventType {
        case .thought: return "THOUGHT"
        case .llmRequest: return "LLM REQ"
        case .llmResponse: return "LLM RES"
        case .toolCall: return "TOOL"
        case .toolResult: return "RESULT"
        case .parseAttempt: return "PARSE"
        case .parseError: return "PARSE ERR"
        case .stateChange: return "STATE"
        case .memoryOp: return "MEMORY"
        case .userInteraction: return "USER"
        case .error: return "ERROR"
        case .metric: return "METRIC"
        }
    }

    private var typeIcon: String {
        switch event.eventType {
        case .thought: return "brain.head.profile"
        case .llmRequest, .llmResponse: return "brain"
        case .toolCall: return "hammer"
        case .toolResult: return "checkmark.circle"
        case .parseAttempt, .parseError: return "doc.text"
        case .stateChange: return "arrow.triangle.swap"
        case .memoryOp: return "memorychip"
        case .userInteraction: return "person"
        case .error: return "exclamationmark.triangle"
        case .metric: return "chart.bar"
        }
    }

    private var typeColor: Color {
        switch event.eventType {
        case .thought: return .blue
        case .llmRequest, .llmResponse: return .purple
        case .toolCall: return .orange
        case .toolResult: return .green
        case .parseAttempt: return .gray
        case .parseError, .error: return theme.errorColor
        case .stateChange: return .teal
        case .memoryOp: return .indigo
        case .userInteraction: return .cyan
        case .metric: return .mint
        }
    }

    // MARK: - Helpers

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: event.timestamp)
    }

    private var severityColor: Color {
        switch event.severity {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return theme.errorColor
        }
    }

    private func formatJSON(_ json: String) -> String {
        // Try to pretty-print if compact
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return str
    }
}
