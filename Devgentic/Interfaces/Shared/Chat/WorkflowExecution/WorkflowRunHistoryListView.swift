// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    /// ⚠️ WRITE-ONLY from this list, by construction (register CF-61). The one call site is
    /// `WorkflowDedicatedView.emptyExecutionState`, which renders in the `else` of
    /// `if let data = displayData` — and `displayData` is non-nil exactly when this id resolves to
    /// a record in `runHistory`. So whenever the list is on screen nothing is selected, and a tap
    /// replaces the list with the timeline in the same update. The per-card selected styling and
    /// `.isSelected` trait that used to read it back were unreachable and have been deleted rather
    /// than left as a description of a state the code cannot produce.
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

/// What a run card's third row shows, and in what register (register XUI-5).
///
/// ⚠️ Keyed on the run STATUS, not on `error != nil`. EVERY cancel path leaves an `error` behind:
/// `WorkflowRunRecord.freeze` copies `state.workflowError`, which a Stop has already set to
/// "Cancelled" (`handleError` writes the message before the cancelled flag is latched), and
/// `WorkflowRunHistoryStore.reconcileOrphans` stamps "Interrupted" on a run reconciled after a quit.
/// Both land on a `.cancelled` STATUS, which is why that is the thing to test. Testing the error
/// alone drew a red warning triangle and two lines of error-coloured text beside the
/// card's own amber "Cancelled" badge, reporting the user's own Stop back to them as a fault. That
/// is the same conflation `NodeStatus.color`'s "amber, not red" rule already settled one layer down.
///
/// ⚠️ And because the branch was EXCLUSIVE, it also HID the partial output that `handleStreamEnd`
/// deliberately preserves so that stopping a run discards no evidence.
enum RunCardBody: Equatable {
    /// A genuine failure — red glyph, error-coloured text.
    case failure(String)
    /// A terminal reason that is NOT a fault (a Stop, a quit). Neutral register.
    case reason(String)
    case output(String)
    case none

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
    /// - Parameter notRunNodes: nodes that never ran because something upstream failed. Spoken
    ///   separately from `failedNodes`, which used to absorb them. Defaulted so the existing
    ///   contract tests keep compiling.
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
            parts.append(String(localized: "Input: \(spokenPreview(record.userInput))"))
        }
        // [XUI-5] Through the SAME decision the visible row uses. This used to test `error != nil`
        // independently, and `freeze` sets `error` on every cancel path — so once the row stopped
        // calling a Stop a failure, VoiceOver still announced "Error: Cancelled" for a run whose card
        // now showed a neutral stop glyph and its partial output. Fixing only the visual half would
        // have left the two descriptions of one card contradicting each other, which is the defect
        // `nodeTagLabel` exists to prevent one screen over.
        switch RunCardBody.of(status: record.status, error: record.error,
                              finalOutput: record.finalOutput) {
        case .failure(let message):
            parts.append(String(localized: "Error: \(spokenPreview(message))"))
        case .reason(let message):
            // Not "Error:" — a Stop is not a fault, and the status word above already said
            // "Cancelled", so this states the reason without re-classifying it.
            parts.append(String(localized: "Reason: \(spokenPreview(message))"))
        case .output(let preview):
            parts.append(String(localized: "Output: \(spokenPreview(preview))"))
        case .none:
            break
        }

        var nodes = "\(totalNodes) node\(totalNodes == 1 ? "" : "s")"
        if failedNodes > 0 { nodes += ", \(failedNodes) failed" }
        if notRunNodes > 0 { nodes += ", \(notRunNodes) not run" }
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

/// ⚠️ NO selected state (register CF-61). This card had `isSelected` styling — accent fill, a
/// 1.5pt accent border, a status-tinted shadow — and an `.isSelected` accessibility trait, none of
/// which could ever render: see the gate documented on `WorkflowRunHistoryListView.selectedRunID`.
/// If this list is ever shown BESIDE a selection, the styling comes back with the gate, not before.
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

    private var cardAccessibilityLabel: String {
        let stats = nodeStats
        return RunCardSpeech.label(for: record, totalNodes: stats.total,
                                   failedNodes: stats.failed, notRunNodes: stats.notRun)
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

                // Row 3: output preview, a terminal reason, or a genuine failure — decided by
                // `RunCardBody`, which keys on STATUS rather than on `error != nil` (register XUI-5).
                switch RunCardBody.of(status: record.status, error: record.error,
                                      finalOutput: record.finalOutput) {
                case .failure(let message):
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9))
                            .foregroundColor(theme.errorColor.opacity(0.7))
                        Text(message)
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
                        Text(message)
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
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                            .lineLimit(2)
                    }
                case .none:
                    EmptyView()
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

                    // Neutral, not red: these nodes never ran. The split was computed and SPOKEN
                    // from the day CH47 landed but never rendered, so the card still showed only
                    // "1 failed" for a 6-node cascade — sighted users saw less than VoiceOver did.
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
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
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
        .accessibilityAddTraits(.isButton)
    }

    private var cardBackground: Color {
        if isHovering { return theme.surfaceOverlay }
        return Color.clear
    }
}
