//
//  WorkflowRunHistoryListView.swift
//  Devgentic
//
//  Created by Raj Singh on 12/04/26.
//
//  Rich run history list for the workflow empty/ready state.
//  Shows per-run cards with user input, output preview, node count,
//  and status. Width-aligned with chat input via ViewLayout.maxContentWidth.
//

import SwiftUI

struct WorkflowRunHistoryListView: View {
    let runHistory: [WorkflowRunRecord]
    @Binding var selectedRunID: UUID?
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Label("Run History", systemImage: "clock.arrow.circlepath")
                    .font(theme.fontSubheadline.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text("\(runHistory.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.surfaceOverlay))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            // Run cards
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(runHistory) { record in
                        WorkflowRunCardView(
                            record: record,
                            isSelected: selectedRunID == record.id
                        ) {
                            selectedRunID = record.id
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Run Card

private struct WorkflowRunCardView: View {
    let record: WorkflowRunRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var statusColor: Color {
        switch record.status {
        case .completed: return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .running:   return .blue
        }
    }

    private var statusIcon: String {
        switch record.status {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .running:   return "circle.fill"
        }
    }

    private var statusLabel: String {
        switch record.status {
        case .completed: return "Completed"
        case .failed:    return "Failed"
        case .cancelled: return "Cancelled"
        case .running:   return "Running"
        }
    }

    private var durationText: String {
        let d = record.duration
        if d < 1 { return "<1s" }
        if d < 60 { return "\(String(format: "%.1f", d))s" }
        return "\(Int(d / 60))m \(Int(d.truncatingRemainder(dividingBy: 60)))s"
    }

    private var nodeStats: (total: Int, failed: Int) {
        let total = record.nodeResults.count
        let failed = record.nodeResults.filter { $0.status == .failed }.count
        return (total, failed)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Row 1: Status + timestamp + duration
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 13))
                        .foregroundColor(statusColor)

                    Text(record.timestamp, style: .relative)
                        .font(theme.fontCaption)
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Text(durationText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(theme.surfaceOverlay)
                        )
                }

                // Row 2: User input preview
                if !record.userInput.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText)
                        Text(record.userInput)
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Row 3: Output preview or error
                if let error = record.error, !error.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(.red.opacity(0.7))
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.8))
                            .lineLimit(2)
                    }
                } else if !record.finalOutput.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.top, 2)
                        Text(record.finalOutput)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                }

                // Bottom strip: Node count + status badge
                HStack(spacing: 8) {
                    let stats = nodeStats
                    Label("\(stats.total) node\(stats.total == 1 ? "" : "s")", systemImage: "square.on.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    if stats.failed > 0 {
                        Text("\(stats.failed) failed")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.red.opacity(0.1))
                            )
                    }

                    Spacer()

                    Text(statusLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(statusColor.opacity(0.1))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(cardBorder, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var cardBackground: Color {
        if isSelected { return theme.accentColor.opacity(0.08) }
        if isHovering { return theme.surfaceOverlay }
        return theme.controlBackground
    }

    private var cardBorder: Color {
        if isSelected { return theme.accentColor.opacity(0.15) }
        return theme.surfaceOverlayStrong
    }
}
