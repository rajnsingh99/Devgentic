// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MessageStreamStarting.swift
//  Devgentic
//
//  The seam at the send path's one chokepoint.
//
//  Every run in the app — typed chat, ChatOps, scheduled tasks, QuickAccess, Orb, regenerate,
//  resume — reaches the backend through `ActiveStreamManager.startMessageStream`. That makes it
//  the right place to assert what a surface is handing over, and for a long time it was
//  impossible to: `ActiveStreamManager` is `final`, so there was no way to observe the boundary
//  from a test without constructing the whole object graph and driving a live backend.
//
//  The cost of that was not theoretical. `SchedulerCoordinator` shipped DESCENDING history to
//  this method (`architecture_readme.md` §7 invariant #8) and no test could have caught it,
//  because no test could see what the scheduler passed. The `[HISTORY]` guard-rail inside
//  `startMessageStream` catches it at RUNTIME; this protocol is what lets a test catch it at
//  BUILD time, per surface, before anything runs.
//
//  ⚠️ DELIBERATELY NARROW. This is not "an interface for ActiveStreamManager" — that type also
//  owns mirror delegates, the interaction center, run snapshots and conversation-wide
//  cancellation, and a protocol carrying all of it would just be the class again with extra
//  steps. It carries the two members a surface needs to OWN A RUN: start one, and cancel the one
//  it started. A caller that needs more depends on the concrete type, deliberately.
//
//  Adopt it where a surface's hand-off is worth pinning. `SchedulerCoordinator` does; the others
//  can move one at a time without a flag day, since `ActiveStreamManager` satisfies both shapes.
//

import Foundation

/// Starting and cancelling one run, as seen by the surface that owns it.
@MainActor
protocol MessageStreamStarting: AnyObject {

    /// Starts a run and returns the assistant message it will stream into.
    ///
    /// ⚠️ THERE IS NO `history` PARAMETER, and that is the point. The manager DERIVES the
    /// model-facing history from its own state — the store, its live streams, and `userMessage`.
    /// A surface cannot hand over a pagination window, a private transcript, or a descending
    /// store dump, because it hands over none. `architecture_readme.md` §7 invariant #8 is
    /// satisfied by construction rather than by review.
    ///
    /// - Parameter userMessage: the user's turn. Carries its own `id` and `conversationId`, so
    ///   neither is passed separately — and the `id` is what lets the duplicate-query strip stop
    ///   comparing on TEXT.
    /// - Parameter promptOverride: model-facing text when it must differ from what was persisted
    ///   and displayed. Orb decorates its query with a spoken-response hint; declaring it here
    ///   keeps that divergence explicit instead of accidental. `nil` sends the message's own text.
    /// - Parameter updating: stream into an EXISTING assistant message (regenerate / resume)
    ///   rather than creating one. When set, the derived history is cut strictly before it.
    @discardableResult
    func startMessageStream(
        withConfig config: BackendRequestConfig,
        userMessage: ChatMessage,
        promptOverride: String?,
        files: [FileSystemItem],
        updating existingMessage: ChatMessage?,
        workflowExecutionState: WorkflowExecutionState?,
        resumeState: TimelineReconstruction?,
        onComplete: @escaping () -> Void
    ) -> ChatMessage

    /// Cancels the run streaming into `messageId`.
    func cancelStream(for messageId: UUID)
}
