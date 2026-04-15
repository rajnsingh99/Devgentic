//
//  SpanTreeView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Redesigned: status indicators, error counts, readable durations, themed colors.
//

import SwiftUI

struct SpanTreeView: View {
    let spans: [Span]
    @Binding var selectedSpanID: String?
    @Environment(\.appTheme) private var theme

    var body: some View {
        List(spans, children: \.children, selection: $selectedSpanID) { span in
            SpanRow(span: span, theme: theme)
                .tag(span.spanID)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(theme.secondaryBackground.opacity(0.3))
    }
}

// MARK: - Span Row

private struct SpanRow: View {
    let span: Span
    let theme: any Theme

    var body: some View {
        HStack(spacing: 8) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            // Kind icon
            Image(systemName: iconName)
                .font(.system(.caption))
                .foregroundStyle(kindColor)
                .frame(width: 16)

            // Name — cleaned up, no "Trace:" prefix clutter
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(.caption, weight: isTopLevel ? .semibold : .regular))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                if let subtitle = kindLabel {
                    Text(subtitle)
                        .font(.system(.caption2))
                        .foregroundStyle(theme.tertiaryText)
                }
            }

            Spacer(minLength: 4)

            // Error count badge
            if errorCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)) // Fixed size: badge chip ≤9pt
                    Text("\(errorCount)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)) // Fixed size: monospaced design
                }
                .foregroundStyle(theme.errorColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(theme.errorColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

            // Duration
            if let duration = span.durationMs {
                Text(DurationFormat.format(ms: duration))
                    .font(.system(size: 10, design: .monospaced)) // Fixed size: monospaced design
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Computed

    private var displayName: String {
        // Strip the verbose "Trace: " prefix from multi-trace views
        if span.name.hasPrefix("Trace: ") {
            let stripped = String(span.name.dropFirst(7))
            // Add a sequence number if there are multiple traces
            return stripped
        }
        return span.name
    }

    private var isTopLevel: Bool {
        span.parentSpanID == nil || span.kind == .workflow
    }

    private var kindLabel: String? {
        switch span.kind {
        case .iteration: return "iteration"
        case .toolExecution: return "tool"
        case .llmCall: return "llm call"
        case .subtask: return "subtask"
        case .workflow: return nil // Top-level, no need
        }
    }

    private var errorCount: Int {
        var count = (span.events ?? []).filter { $0.severity == .error || $0.eventType == .parseError || $0.eventType == .error }.count
        for child in span.children ?? [] {
            count += countErrors(in: child)
        }
        return count
    }

    private func countErrors(in span: Span) -> Int {
        var count = (span.events ?? []).filter { $0.severity == .error || $0.eventType == .parseError || $0.eventType == .error }.count
        for child in span.children ?? [] {
            count += countErrors(in: child)
        }
        return count
    }

    private var statusColor: Color {
        switch span.status {
        case .completed: return .green
        case .error: return theme.errorColor
        case .running: return .orange
        }
    }

    private var iconName: String {
        switch span.kind {
        case .iteration: return "arrow.triangle.2.circlepath"
        case .toolExecution: return "hammer"
        case .llmCall: return "brain"
        case .workflow: return "flowchart"
        case .subtask: return "square.stack.3d.down.right"
        }
    }

    private var kindColor: Color {
        switch span.kind {
        case .iteration: return .blue
        case .toolExecution: return .orange
        case .llmCall: return .purple
        case .workflow: return theme.accentColor
        case .subtask: return .teal
        }
    }
}

// MARK: - Duration Formatting

enum DurationFormat {
    static func format(ms: Int) -> String {
        if ms < 1000 {
            return "\(ms)ms"
        } else if ms < 60_000 {
            let seconds = Double(ms) / 1000.0
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = ms / 60_000
            let remainingSeconds = (ms % 60_000) / 1000
            return "\(minutes)m \(remainingSeconds)s"
        }
    }
}
