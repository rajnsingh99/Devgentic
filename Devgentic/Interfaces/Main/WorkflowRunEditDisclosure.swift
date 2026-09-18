// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunEditDisclosure.swift
//  Devgentic
//
//  Whether a starting workflow run must DISCLOSE that it is executing the on-disk graph while the
//  user's canvas holds edits that never reached disk. [WF-CS4]
//
//  ⚠️ THIS DISCLOSES; IT DOES NOT GATE, PROMPT, OR SAVE. That is the whole design, and each of the
//  three alternatives was rejected against something already decided in this codebase:
//
//  • AUTO-SAVING before dispatch contradicts a recorded USER DECISION stated in four places —
//    `WorkflowCanvasState` ("The canvas has no autosave (user decision)"),
//    `MainApplicationViewModel` ("the ONLY thing that writes them to disk is an explicit Save"),
//    `WorkflowGuidelineView` ("There is no autosave"), and `architecture_readme.md` invariant 35.
//    It would also destroy the Revert baseline (`markSaved()` re-bases `initialLayout`, after which
//    "revert to my last deliberate save" is gone), rewrite the profile row and reorder the user's
//    recently-used list on every run, commit EVERY dirty canvas rather than this one
//    (`persistDirtyWorkflowCanvases` has no per-profile variant), and — worst — write an EMPTIED
//    canvas over a populated graph for anyone who used Clear Canvas, with no history to recover it.
//
//  • PROMPTING at the run trigger cannot be done safely from here. Two run origins are UNATTENDED
//    (`.scheduled` and `.chatOps`, which bind `WorkflowRunAttendance.isAttended = false`), a SwiftUI
//    dialog is not a HITL request and is therefore NOT mirrored to Slack/Telegram/Discord by
//    `RemoteMirrorService`, and the ChatOps path carries no container deadline at all — so a prompt
//    there parks a remote user's run forever with nothing able to answer it.
//
//  • RUNNING THE IN-MEMORY GRAPH changes documented, user-facing semantics (the Guide states "Run
//    executes the last SAVED graph"), and is a product change rather than a defect fix.
//
//  So the run keeps its existing semantics and stops being SILENT about them — which is exactly the
//  filed defect ("ux-lie"), no more and no less.
//
//  Kept pure (`nonisolated static` over plain values) so the rule is unit-testable with no view
//  model — `MainApplicationViewModel` cannot be constructed in a unit test (it claims `HITLPresenter`
//  globally), which is why `WorkflowRunRegistry` exists at all. Same shape as `RunAdmissionPolicy`.
//

import Foundation

enum WorkflowRunEditDisclosure {

    /// True when any workflow THIS RUN WILL EXECUTE holds unsaved canvas edits, so the graph on
    /// screen is not the graph about to run.
    ///
    /// ⚠️ `runProfileIDs` is the run's TRANSITIVE set — the root workflow plus every sub-workflow it
    /// nests, resolved via `WorkflowLayoutStore.resolveNestedLayouts`. Scoping to the root alone was
    /// the first shape of this fix and it reproduced WF-CS4 verbatim one level down: a sub-workflow
    /// node loads its OWN profile's layout from disk (`WorkflowExecutor` passes `layout: nil` for
    /// children, deliberately), so a dirty CHILD canvas silently runs stale exactly like a dirty
    /// root one — and the child path never reaches `WorkflowRunBootstrap.begin` at all, so this is
    /// the only place that can see it.
    ///
    /// ⚠️ Still scoped to the RUN, never app-wide. An unrelated workflow's dirty canvas is not this
    /// run's problem, and disclosing it would train the user to ignore the notice.
    ///
    /// ⚠️ The caller must pass `MainApplicationViewModel.unsavedWorkflowCanvasProfileIDs` — which
    /// PULLS from the live canvas states — and never `dirtyWorkflowCanvasIDs`, whose own declaration
    /// warns it "is pushed from views and would silently under-report if a push were ever missed. Do
    /// not swap the quit decision onto it." A missed push here would restore the silence this exists
    /// to remove. It is also the only safe probe: `workflowCanvasState(for:)` CREATES and
    /// permanently caches a state on a miss, so asking it "is X dirty?" would materialise an empty
    /// canvas for every workflow ever run.
    nonisolated static func shouldDisclose(
        runProfileIDs: Set<UUID>,
        unsavedCanvasProfileIDs: [UUID]
    ) -> Bool {
        unsavedCanvasProfileIDs.contains { runProfileIDs.contains($0) }
    }

    /// Shown in the run's own timeline, live and in the persisted record. Must not name internal ids.
    ///
    /// Phrased about the RUN, not about the user's editing: the run is the thing that is now
    /// misleading, and the canvas edits themselves are safe (they outlive every view teardown in the
    /// App-scoped cache and are drained at quit — see WF-LC1).
    static let userFacingReason = String(
        localized: "This run used the last saved version of this workflow. Your unsaved canvas edits were not part of it — save the canvas and run again to include them."
    )

    /// `[WF_RUN]`-tagged, with the run correlation ids and the CONSEQUENCE, per the logging standard.
    nonisolated static func logReason(
        runRecordID: UUID,
        workflowProfileID: UUID,
        conversationID: UUID,
        origin: String
    ) -> String {
        "[WF_RUN] Run \(runRecordID) (origin \(origin), profile \(workflowProfileID), conv \(conversationID)) started while its canvas holds UNSAVED edits. CONSEQUENCE: the run executes the last-saved graph from disk — the on-screen edits are not in it — and the run now says so in its timeline and in its persisted record instead of leaving the user to infer it from results that do not match the canvas. The edits themselves are safe: they live in the App-scoped canvas cache and are drained at quit."
    }
}
