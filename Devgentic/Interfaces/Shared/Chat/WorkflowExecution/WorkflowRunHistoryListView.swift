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
            // The count capsule read as a bare "12" — a number with no noun. Merged into
            // the title, and marked a header so the list can be jumped to via the rotor.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Run History, \(runHistory.count) run\(runHistory.count == 1 ? "" : "s")")
            .accessibilityAddTraits(.isHeader)

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

// MARK: - Spoken form

/// What VoiceOver says for a run card.
///
/// Extracted for the same reason as `TableSpeech`: a SwiftUI accessibility label can't be
/// read back from a hosted view (the tree is built lazily when a real assistive client
/// attaches), so testing this function is the only way to pin the contract.
enum RunCardSpeech {

    /// The whole card as ONE utterance.
    ///
    /// Every fact is already on screen, but scattered across four rows of icon+text pairs,
    /// so VoiceOver read the card as a pile of disconnected fragments:
    /// "checkmark.circle.fill, 12.4s, text.bubble, <input>, square.on.square, 3 nodes, Failed".
    /// Ordered by what identifies a run: what happened, then what was asked, then the result.
    static func label(for record: WorkflowRunRecord, totalNodes: Int, failedNodes: Int) -> String {
        var parts: [String] = []
        let startedAt = record.timestamp.formatted(date: .omitted, time: .shortened)

        if record.status == .running {
            // A spoken elapsed time is stale the instant it's said, and re-announcing it
            // every second would make the list unusable. The start time doesn't move.
            parts.append(String(localized: "Running since \(startedAt)"))
        } else {
            parts.append("\(record.status.label), \(DurationFormat.seconds(record.duration)), \(startedAt)")
        }

        if !record.userInput.isEmpty {
            parts.append(String(localized: "Input: \(spokenPreview(record.userInput))"))
        }
        // Error wins over output: a failed run's error is what you need, and the card
        // shows one or the other, never both.
        if let error = record.error, !error.isEmpty {
            parts.append(String(localized: "Error: \(spokenPreview(error))"))
        } else if !record.finalOutput.isEmpty {
            parts.append(String(localized: "Output: \(spokenPreview(record.finalOutput))"))
        }

        var nodes = "\(totalNodes) node\(totalNodes == 1 ? "" : "s")"
        if failedNodes > 0 { nodes += ", \(failedNodes) failed" }
        parts.append(nodes)

        return parts.joined(separator: ". ")
    }

    /// Mirrors the card's visual truncation. The card shows 1–2 lines; reading a full
    /// multi-kilobyte output aloud for one row of a list is its own accessibility failure.
    static func spokenPreview(_ text: String, limit: Int = 120) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

// MARK: - Run Card

private struct WorkflowRunCardView: View {
    let record: WorkflowRunRecord
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    // Status vocabulary delegates to the canonical RunStatus extension
    // (WorkflowRunDisplayData) so the list can't drift from the picker / cards.
    private var statusColor: Color { record.status.color(theme) }
    private var statusIcon: String { record.status.icon }
    private var statusLabel: String { record.status.label }

    private var durationText: String { DurationFormat.seconds(record.duration) }

    private var nodeStats: (total: Int, failed: Int) {
        let total = record.nodeResults.count
        let failed = record.nodeResults.filter { $0.status == .failed }.count
        return (total, failed)
    }

    private var cardAccessibilityLabel: String {
        let stats = nodeStats
        return RunCardSpeech.label(for: record, totalNodes: stats.total, failedNodes: stats.failed)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Row 1: Status + run duration
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 13))
                        .foregroundColor(statusColor)
                        .shadow(color: statusColor.opacity(0.35), radius: 2)

                    if record.status == .running {
                        TimelineView(.periodic(from: record.timestamp, by: 1.0)) { context in
                            Text(DurationFormat.seconds(context.date.timeIntervalSince(record.timestamp)))
                                .font(theme.fontCaption.weight(.bold).monospacedDigit())
                                .foregroundColor(theme.primaryText)
                        }
                    } else {
                        Text(durationText)
                            .font(theme.fontCaption.weight(.bold).monospacedDigit())
                            .foregroundColor(theme.primaryText)
                    }

                    Spacer()
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
                            .foregroundColor(theme.errorColor.opacity(0.7))
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor.opacity(0.8))
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)

                    if stats.failed > 0 {
                        Text("\(stats.failed) failed")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.errorColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(theme.errorColor.opacity(0.12))
                            )
                    }

                    Spacer()

                    Text(statusLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill(statusColor.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(cardBackground)
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(cardBorder, lineWidth: isSelected ? 1.5 : 0.5)
            )
            .shadow(color: isSelected ? statusColor.opacity(0.08) : Color.black.opacity(0.04), radius: isSelected ? 6 : 1, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering && !reduceMotion ? 1.012 : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
        // `.ignore` rather than `.combine`: combining would still read every icon and
        // fragment, just glued together. This replaces them with one composed sentence —
        // and it takes the decorative glyphs out of the tree for free.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cardAccessibilityLabel)
        // Which run you're viewing was conveyed only by border weight, fill and shadow.
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var cardBackground: Color {
        if isSelected { return theme.accentColor.opacity(0.08) }
        if isHovering { return theme.surfaceOverlay }
        return Color.clear
    }

    private var cardBorder: Color {
        if isSelected { return theme.accentColor.opacity(0.15) }
        return theme.surfaceOverlayStrong
    }
}
