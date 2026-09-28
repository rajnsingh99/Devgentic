// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ManualCompactionRow.swift
//  Devgentic
//
//  The transcript's view of a MANUAL compaction ("Compact history" in the context gauge),
//  2026-09-25.
//
//  ⚠️ Why a row at the bottom and not an agent-timeline milestone. The timeline belongs to one
//  assistant message's RUN, and a manual compaction happens BETWEEN runs — there is no message to
//  hang it on, and appending it to the last reply would put it inside a finished run it was never
//  part of (and there may be no reply at all in a plain bot chat). So it is a standalone row at the
//  end of the transcript, drawn with the timeline's own `CapabilityMilestoneRow`.
//
//  ⚠️ Why it is needed at all. Before this, the only sign of a manual compaction was the spinner
//  INSIDE the gauge popover — close the popover and nothing said it was running — and the result,
//  the "History Checkpoint" card, lands where the summarized turns END (its timestamp decides what
//  it replaces), which is usually far above the fold. So a compaction finished invisibly.
//
//  ⚠️ LIVE ONLY, by decision. Nothing here is persisted: the checkpoint card is the durable record,
//  and a persisted event row would need a new message kind kept out of model history, exports and
//  search. The row leaves once the conversation moves on (a newer message arrives) or on dismiss.
//

import SwiftUI

/// Per-conversation state of a manual compaction. MainActor because the only writer is the gauge's
/// action and the only reader is the transcript.
@MainActor
@Observable
final class ManualCompactionActivity {

    static let shared = ManualCompactionActivity()

    enum Phase: Equatable {
        case running(startedAt: Date)
        case finished(HistoryCompactionService.ManualOutcome, finishedAt: Date)
    }

    private(set) var phases: [UUID: Phase] = [:]

    /// Conversations whose current run is AUTOMATIC — started by the app after a turn, not by the
    /// user — so the row can say so (owner decision 2026-09-27: automatic compaction is shown too).
    private(set) var automatic: Set<UUID> = []

    /// Returns false when one is already running here — the caller must not then report its own
    /// outcome over it (that outcome would be `.alreadyRunning`, which says nothing new).
    @discardableResult
    func begin(_ conversationID: UUID, automatic isAutomatic: Bool = false, now: Date = Date()) -> Bool {
        if case .running = phases[conversationID] { return false }
        phases[conversationID] = .running(startedAt: now)
        if isAutomatic { automatic.insert(conversationID) } else { automatic.remove(conversationID) }
        return true
    }

    func isAutomatic(_ conversationID: UUID?) -> Bool {
        conversationID.map { automatic.contains($0) } ?? false
    }

    func finish(_ conversationID: UUID, outcome: HistoryCompactionService.ManualOutcome, now: Date = Date()) {
        phases[conversationID] = .finished(outcome, finishedAt: now)
    }

    func dismiss(_ conversationID: UUID) {
        phases[conversationID] = nil
        automatic.remove(conversationID)
    }

    func phase(for conversationID: UUID?) -> Phase? {
        conversationID.flatMap { phases[$0] }
    }

    // MARK: - What the row says (pure, so tests do not need to render)

    struct Presentation: Equatable {
        let kind: CapabilityMilestoneKind
        let text: String
        let inProgress: Bool
        /// The checkpoint card to jump to, when there is one.
        let checkpointID: UUID?
    }

    /// nil = show nothing. A finished row stays only until the conversation moves on: once a
    /// message newer than the outcome exists, the row is history and the checkpoint card is the
    /// record.
    static func presentation(for phase: Phase?, newestMessageAt: Date?, automatic: Bool = false) -> Presentation? {
        switch phase {
        case .none:
            return nil
        case .running:
            return Presentation(kind: .compactionStarted,
                                text: automatic
                                    ? String(localized: "Compacting history automatically — summarizing older turns so the conversation fits…")
                                    : String(localized: "Compacting history — summarizing older turns…"),
                                inProgress: true, checkpointID: nil)
        case let .finished(outcome, finishedAt):
            if let newestMessageAt, newestMessageAt > finishedAt { return nil }
            switch outcome {
            case let .compacted(_, _, _, _, checkpointID):
                return Presentation(kind: .compactionCompleted, text: outcome.message,
                                    inProgress: false, checkpointID: checkpointID)
            case .failed:
                return Presentation(kind: .compactionFailed,
                                    text: outcome.message + " " + String(localized: "History is unchanged."),
                                    inProgress: false, checkpointID: nil)
            case .nothingToCompact, .alreadyRunning:
                return Presentation(kind: .compactionCompleted, text: outcome.message,
                                    inProgress: false, checkpointID: nil)
            }
        }
    }
}

/// The row itself, at the end of the transcript.
struct ManualCompactionRow: View {

    let conversationID: UUID?
    /// When the newest loaded message was written, so a finished row retires once the chat moves on.
    let newestMessageAt: Date?
    /// Whether the checkpoint card is in the loaded transcript, so "Show summary" can reach it.
    let canShowCheckpoint: (UUID) -> Bool
    let onShowCheckpoint: (UUID) -> Void

    @Environment(\.appTheme) private var theme

    private var activity: ManualCompactionActivity { .shared }

    var body: some View {
        if let conversationID,
           let presentation = ManualCompactionActivity.presentation(
               for: activity.phase(for: conversationID), newestMessageAt: newestMessageAt,
               automatic: activity.isAutomatic(conversationID)) {
            HStack(spacing: 8) {
                CapabilityMilestoneRow(kind: presentation.kind, detail: presentation.text,
                                       inProgress: presentation.inProgress)

                if let checkpointID = presentation.checkpointID, canShowCheckpoint(checkpointID) {
                    Button(String(localized: "Show summary")) { onShowCheckpoint(checkpointID) }
                        .buttonStyle(.borderless)
                        .font(.system(.caption, weight: .medium))
                }

                if !presentation.inProgress {
                    Button {
                        activity.dismiss(conversationID)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Dismiss"))
                    .accessibilityLabel(String(localized: "Dismiss"))
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, theme.spacingMedium)
            .padding(.top, 4)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}
