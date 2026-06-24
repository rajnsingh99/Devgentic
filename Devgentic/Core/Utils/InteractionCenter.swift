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
//  P1 status: the type exists and is owned by MainApplicationViewModel + injected into
//  ActiveStreamManager, but has NO writers yet (dead, zero behavior change). P2 wires the
//  ASM bridge to `enqueue`; the `.hitl*Resolved` notifications drive `resolve`.
//

import Foundation
import Observation

@Observable @MainActor
final class InteractionCenter {

    /// Insertion-ordered pending requests across every conversation / interface.
    private(set) var pending: [PendingHITL] = []

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
    }

    /// Removes the request for a resolved / cancelled / timed-out operation. No-op if absent.
    func resolve(operationID: UUID) {
        pending.removeAll { $0.id == operationID }
    }

    /// Removes every pending request for a conversation (Stop button / conversation teardown).
    func resolveAll(conversationID: UUID) {
        pending.removeAll { $0.origin.conversationID == conversationID }
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
