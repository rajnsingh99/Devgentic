// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InteractionCenter.swift
//  Devgentic
//
//  [HITL Standardization — P1]
//  Single source of truth for pending Human-in-the-Loop requests across ALL interfaces
//  (chat, code, workflow, scheduled). Replaces the two divergent containers
//  (`ChatMessage.pendingInteraction` single-optional + `WorkflowExecutionState.pendingInteractions`)
//  with one insertion-ordered, operationID-keyed queue.
//
//  Presentation contract (locked decisions):
//   - D1: `current(for:)` exposes a strict-FIFO single item so the shared banner shows
//         exactly one request at a time; the next slides in once the current resolves.
//   - D2: `items(for:)` exposes every pending request so the workflow canvas can badge
//         each waiting node while the banner shows only the current one.
//
//  Wiring (P2 shipped): ActiveStreamManager's HITL bridge calls `enqueue` for every
//  park kind; the `.hitl*Resolved` notification handlers drive `resolve`, and
//  conversation teardown drives `resolveAll`. This class also owns the stale-park
//  watchdog: a local notification fires if a request sits unanswered past the
//  threshold (parks are deadline-free by design — the watchdog is the signal).
//

import Foundation
import AppKit
import Observation

/// Where an OUT-OF-BAND human-in-the-loop request should be presented.
///
/// The stream pipeline injects an `InteractionCenter` into `ActiveStreamManager`, which
/// works because every request there originates inside a run. MCP breaks that assumption:
/// a server's `sampling/createMessage` or `elicitation/create` arrives on the client
/// connection at a moment of the server's choosing, from code that has no stream in scope.
///
/// This is the explicit seam for those callers. `MainApplicationViewModel` claims it;
/// QuickAccess deliberately does not, so a secondary window can never steal the
/// presentation target from the main one.
@MainActor
enum HITLPresenter {
    private(set) static weak var center: InteractionCenter?

    static func claim(_ center: InteractionCenter) {
        self.center = center
    }
}

@Observable @MainActor
final class InteractionCenter {

    /// Insertion-ordered pending requests across every conversation / interface.
    private(set) var pending: [PendingHITL] = []

    /// [HITL ergonomics] One stale-park watchdog per pending operation: fires a
    /// local notification if the request is still unanswered after the threshold,
    /// so a forgotten banner doesn't wait silently forever (parks have no deadline
    /// by design — this is the signal, not a timeout).
    @ObservationIgnored private var staleWatchdogs: [UUID: Task<Void, Never>] = [:]

    /// How long a request may sit unanswered before the stale notification fires.
    private static let staleNotificationDelay: TimeInterval = 180

    /// [HITL/E2] Bumped to draw attention to the always-visible banner — e.g. when the user taps an
    /// "awaiting input" workflow node. The banner observes this and pulses; the value itself is opaque.
    private(set) var attentionPulse: Int = 0

    /// Requests a one-shot attention pulse on the banner (used by the node "Needs your input" badge).
    func pulseBanner() { attentionPulse &+= 1 }

    // MARK: - Mutation

    /// Adds a pending request. Idempotent on `operationID` — re-enqueueing the same
    /// operation replaces the existing entry rather than duplicating it.
    func enqueue(_ item: PendingHITL) {
        if let index = pending.firstIndex(where: { $0.id == item.id }) {
            pending[index] = item
        } else {
            pending.append(item)
        }
        startStaleWatchdog(for: item)
    }

    /// Removes the request for a resolved / cancelled / timed-out operation. No-op if absent.
    func resolve(operationID: UUID) {
        pending.removeAll { $0.id == operationID }
        cancelStaleWatchdog(for: operationID)
    }

    /// Removes every pending request for a conversation (Stop button / conversation teardown).
    func resolveAll(conversationID: UUID) {
        let removedIDs = pending.filter { $0.origin.conversationID == conversationID }.map(\.id)
        pending.removeAll { $0.origin.conversationID == conversationID }
        for id in removedIDs { cancelStaleWatchdog(for: id) }
    }

    // MARK: - Stale-Park Watchdog

    private func startStaleWatchdog(for item: PendingHITL) {
        cancelStaleWatchdog(for: item.id)
        staleWatchdogs[item.id] = Task { [weak self] in
            // Cancellation here means the request was answered in time — the
            // nil-return IS the intended silence, unlike the executor sleeps.
            guard (try? await Task.sleep(
                nanoseconds: UInt64(Self.staleNotificationDelay * 1_000_000_000)
            )) != nil else { return }
            guard let self, self.item(withID: item.id) != nil else { return }
            self.staleWatchdogs[item.id] = nil
            Self.dispatchStaleNotification(for: item)
        }
    }

    private func cancelStaleWatchdog(for operationID: UUID) {
        staleWatchdogs[operationID]?.cancel()
        staleWatchdogs[operationID] = nil
    }

    /// Mirrors ActiveStreamManager's completion-notification contract: skip when
    /// the app is frontmost (the banner + cross-conversation chip are already
    /// visible), honor the per-conversation notification toggle.
    nonisolated private static func dispatchStaleNotification(for item: PendingHITL) {
        Task.detached(priority: .utility) {
            // [C6] Suppress when the user is actively viewing — app frontmost OR the
            // non-activating QuickAccess panel is key. Without the panel term, a HITL banner
            // the user is reading in the panel would still fire a "still waiting" notification.
            let userIsViewing = await MainActor.run { NSApp.isActive || (AppDelegate.shared?.isQuickAccessPanelKey ?? false) }
            guard !userIsViewing else { return }

            let minutes = max(1, Int(Date().timeIntervalSince(item.timestamp) / 60))
            // [L4] Do NOT put origin.title in the body — a conversation's title is often the raw
            // first user message (always so for QuickAccess chats), which would surface the user's
            // own prompt on the lock screen. A generic body is enough; the tap still deep-links to
            // the right conversation.
            let payload = AppNotificationPayload(
                title: "Still waiting for you",
                body: "A conversation has been waiting \(minutes) min for \(item.kind.staleNoun).",
                conversationID: item.origin.conversationID
            )
            await NotificationDispatcher.shared.dispatch(payload)
        }
    }

    // MARK: - Queries

    /// The single oldest pending request for a conversation — drives the one-at-a-time
    /// FIFO banner (D1). Returns nil when nothing is pending.
    func current(for conversationID: UUID) -> PendingHITL? {
        pending.first { $0.origin.conversationID == conversationID }
    }

    /// All pending requests for a conversation, in insertion order — drives the workflow
    /// node "awaiting input" badges (D2) and remote mirroring.
    func items(for conversationID: UUID) -> [PendingHITL] {
        pending.filter { $0.origin.conversationID == conversationID }
    }

    /// The pending request with this operationID, across all conversations (operationID is unique).
    /// [D1] Lets a remote reply resolve by the exact operation, and dispatch by its kind.
    func item(withID operationID: UUID) -> PendingHITL? {
        pending.first { $0.id == operationID }
    }

    /// Whether any request is pending for a conversation.
    func hasPending(for conversationID: UUID) -> Bool {
        pending.contains { $0.origin.conversationID == conversationID }
    }
}

// MARK: - Stale-Notification Copy

extension PendingInteraction {
    /// Human phrase for what the run is waiting on — the Mac's stale notification, the remote
    /// reminder and the remote "still working" refusal all use it.
    var staleNoun: String {
        switch self {
        case .toolConfirmation: return "your approval"
        case .clarification:    return "your answer"
        case .planReview:       return "your plan review"
        case .gate:             return "your go-ahead at a gate"
        }
    }
}
