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

    @State private var isHovering: Bool = false

    private var isError: Bool {
        event.severity == .error || event.eventType == .parseError || event.eventType == .error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(alignment: .top, spacing: 8) {
                // Error indicator — left edge stripe
                if isError {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.errorColor)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .shadow(color: theme.errorColor.opacity(0.5), radius: 3, x: 0, y: 0)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.accentColor.opacity(0.5))
                        .frame(width: 3)
                        .padding(.vertical, 2)
                }

                // Timestamp
                Text(timeString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)) // Fixed size: monospaced design
                    .foregroundStyle(isHovering ? theme.primaryText : theme.tertiaryText)
                    .frame(width: 72, alignment: .leading)
                    .padding(.top, 1)

                // Type badge
                typeBadge

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.content ?? "—")
                        .font(.system(.caption, weight: isHovering ? .medium : .regular))
                        .foregroundStyle(isError ? theme.errorColor : theme.primaryText)
                        .lineLimit(isExpanded ? nil : 2)

                    // Expandable detail
                    if event.detailJSON != nil {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isExpanded.toggle() }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold)) // Fixed size: badge chip ≤9pt
                                Text("details")
                                    .font(.system(.caption2, weight: .medium))
                            }
                            .foregroundStyle(isHovering ? theme.accentColor : theme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer(minLength: 4)

                // Severity dot
                Circle()
                    .fill(severityColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                    .shadow(color: severityColor.opacity(isHovering ? 0.6 : 0.2), radius: 3, x: 0, y: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    if isError {
                        theme.errorColor.opacity(0.05)
                    }
                    if isHovering {
                        theme.surfaceOverlayStrong.opacity(0.5)
                    }
                }
            )

            // Expanded detail JSON
            if isExpanded, let details = event.detailJSON {
                Text(formatJSON(details))
                    .font(.system(size: 11, design: .monospaced)) // Fixed size: monospaced design
                    .foregroundStyle(theme.secondaryText)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.surfaceOverlayStrong)
                            .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.dividerColor, lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            // Subtle row divider
            Divider()
                .background(theme.dividerColor.opacity(0.5))
                .padding(.leading, isError || isHovering ? 15 : 12)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
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
