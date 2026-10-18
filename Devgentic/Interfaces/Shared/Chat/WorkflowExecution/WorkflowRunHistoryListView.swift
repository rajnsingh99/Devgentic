// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunHistoryListView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A run history list for the workflow empty/ready state, with a card per run showing user input, output preview,
/// node count and status. Width-aligned with the chat input via `ViewLayout.maxContentWidth`.
struct WorkflowRunHistoryListView: View {
    let runHistory: [WorkflowRunRecord]
    /// Write-only from this list: `WorkflowDedicatedView.emptyExecutionState` renders it only while nothing is selected,
    /// and a tap replaces the list with the timeline in the same update.
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
                        WorkflowRunCardView(record: record) {
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

// MARK: - Card body and spoken form

/// What a run card's third row shows, and in what register. Keyed on the run status, not `error != nil`: every cancel
/// path leaves an `error` behind, so a Stop would otherwise read as a fault. Partial output is kept visible.
enum RunCardBody: Equatable {
    /// A genuine failure — red glyph, error-coloured text.
    case failure(String)
    /// A terminal reason that is NOT a fault (a Stop, a quit). Neutral register.
    case reason(String)
    case output(String)
    case none

    /// The display bound for a card's payload strings. `lineLimit` is only a layout constraint (the full string is still
    /// measured per card per pass), so bound the string itself. Not applied inside `of(status:error:finalOutput:)`, which
    /// returns the true strings; callers that display call this.
    nonisolated static func bounded(_ text: String, limit: Int = 200) -> String {
        // `prefix` on a String is O(limit), not O(n) — the point is to never walk the tail.
        var result = ""
        result.reserveCapacity(limit)
        for character in text {
            if result.count == limit { return result + "…" }
            result.append(character)
        }
        return result
    }

    /// This body's payload, bounded for display. `.none` carries nothing to bound.
    nonisolated var displayText: String? {
        switch self {
        case .failure(let message), .reason(let message), .output(let message):
            return RunCardBody.bounded(message)
        case .none:
            return nil
        }
    }

    /// Pure and `nonisolated` (WF-UI5): a SwiftUI view's `if` chain is unreachable from a test, and
    /// this decision is exactly the one that was wrong.
    nonisolated static func of(
        status: WorkflowRunRecord.RunStatus,
        error: String?,
        finalOutput: String
    ) -> RunCardBody {
        let reason = error.flatMap { $0.isEmpty ? nil : $0 }
        if status == .cancelled {
            // Output FIRST — a stopped run's partial answer is the useful half, and the reason is
            // already stated by the amber badge above.
            if !finalOutput.isEmpty { return .output(finalOutput) }
            if let reason { return .reason(reason) }
            return .none
        }
        if let reason { return .failure(reason) }
        if !finalOutput.isEmpty { return .output(finalOutput) }
        return .none
    }
}

/// What VoiceOver says for a run card. A separate type so the contract can be tested, since an accessibility label
/// cannot be read back from a hosted view.
enum RunCardSpeech {

    /// The whole card as one utterance, ordered by what identifies a run: what happened, what was asked, the result.
    /// `notRunNodes` are nodes that never ran because something upstream failed, spoken separately from `failedNodes`.
    static func label(for record: WorkflowRunRecord, totalNodes: Int, failedNodes: Int,
                      notRunNodes: Int = 0) -> String {
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
            parts.append(String(localized: "Input: \(spokenPreview(RunCardBody.bounded(record.userInput)))"))
        }
        // Uses the same decision as the visible row, so VoiceOver and the card cannot contradict each other about a stopped
        // run.
        switch RunCardBody.of(status: record.status, error: record.error,
                              finalOutput: record.finalOutput) {
        case .failure(let message):
            parts.append(String(localized: "Error: \(spokenPreview(RunCardBody.bounded(message)))"))
        case .reason(let message):
            // Not "Error:" — a Stop is not a fault, and the status word above already said
            // "Cancelled", so this states the reason without re-classifying it.
            parts.append(String(localized: "Reason: \(spokenPreview(RunCardBody.bounded(message)))"))
        case .output(let preview):
            parts.append(String(localized: "Output: \(spokenPreview(RunCardBody.bounded(preview)))"))
        case .none:
            break
        }

        var nodes = "\(totalNodes) node\(totalNodes == 1 ? "" : "s")"
        if failedNodes > 0 { nodes += ", \(failedNodes) failed" }
        if notRunNodes > 0 { nodes += ", \(notRunNodes) not run" }
        parts.append(nodes)

        return parts.joined(separator: ". ")
    }

    #if DEBUG
    /// The longest string `spokenPreview` has been given in this process. Reset by tests.
    nonisolated(unsafe) static var longestSpokenPreviewInputForTesting = 0
    #endif

    /// Trims to a spoken length; reading a full multi-kilobyte output aloud for one list row is an accessibility failure.
    /// Callers pass `RunCardBody.bounded(_:)` output so this never walks a full-size value.
    static func spokenPreview(_ text: String, limit: Int = 120) -> String {
        #if DEBUG
        // Test seam: records the largest input this has been handed, since the cap always bounds the output.
        longestSpokenPreviewInputForTesting = max(longestSpokenPreviewInputForTesting, text.count)
        #endif
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

// MARK: - Run Card

/// A run card. It has no selected state: the list is only shown while nothing is selected (see
/// `WorkflowRunHistoryListView.selectedRunID`).
private struct WorkflowRunCardView: View {
    let record: WorkflowRunRecord
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

    /// A cascade skip is recorded as `.failed` by the engine, so counting raw `.failed`
    /// reported "5 failed" for a 6-node workflow where exactly one node broke and four never
    /// ran. The timeline and the auto-focus already excluded them; this card did not.
    private var nodeStats: (total: Int, failed: Int, notRun: Int) {
        let total = record.nodeResults.count
        let failed = record.nodeResults.filter(\.isGenuineFailure).count
        let notRun = record.nodeResults.filter(\.didNotRun).count
        return (total, failed, notRun)
    }

    var body: some View {
        // Both derived once per pass: `nodeStats` filters `nodeResults` twice, and the accessibility label modifier argument
        // is built eagerly.
        let stats = nodeStats
        let accessibilityLabel = RunCardSpeech.label(for: record, totalNodes: stats.total,
                                                     failedNodes: stats.failed, notRunNodes: stats.notRun)

        return Button(action: onSelect) {
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
                        Text(RunCardBody.bounded(record.userInput))
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // Row 3: output preview, a terminal reason, or a genuine failure — decided by
                // `RunCardBody`, which keys on STATUS rather than on `error != nil` (register XUI-5).
                switch RunCardBody.of(status: record.status, error: record.error,
                                      finalOutput: record.finalOutput) {
                case .failure(let message):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(theme.errorColor.opacity(0.7))
                        Text(RunCardBody.bounded(message))
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor.opacity(0.8))
                            .lineLimit(2)
                    }
                case .reason(let message):
                    // Neutral register: a Stop is not a fault, so no warning glyph and no error tint.
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 9))
                            .foregroundColor(theme.secondaryText)
                        Text(RunCardBody.bounded(message))
                            .font(.system(size: 11))
                            .foregroundColor(theme.secondaryText)
                            .lineLimit(2)
                    }
                case .output(let preview):
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 9))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.top, 2)
                        Text(RunCardBody.bounded(preview))
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                case .none:
                    EmptyView()
                }

                // Bottom strip: Node count + status badge
                HStack(spacing: 8) {
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

                    // Neutral, not red: these nodes never ran. Shown so sighted users see the same split VoiceOver speaks.
                    if stats.notRun > 0 {
                        Text("\(stats.notRun) not run")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(theme.surfaceOverlayStrong.opacity(0.6))
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
                    .stroke(isHovering ? theme.accentColor.opacity(0.35) : theme.surfaceOverlayStrong, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.08 : 0.04), radius: isHovering ? 3 : 1, y: 1)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.75)) {
                isHovering = hovering
            }
        }
        // `.ignore` rather than `.combine`, replacing the fragments with one composed sentence and removing the decorative
        // glyphs from the tree.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var cardBackground: Color {
        if isHovering { return theme.surfaceOverlay.opacity(0.85) }
        return theme.surfaceOverlay.opacity(0.35)
    }
}
