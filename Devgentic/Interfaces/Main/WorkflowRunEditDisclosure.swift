// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowRunEditDisclosure.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Decides whether a starting workflow run must disclose that it executes the on-disk graph while the user's canvas
/// holds unsaved edits. It only discloses: it does not auto-save, prompt or run the in-memory graph, since the canvas
/// has no autosave and unattended runs cannot answer a prompt.
enum WorkflowRunEditDisclosure {

    /// True when any workflow this run will execute holds unsaved canvas edits, so the graph on screen is not the graph
    /// about to run. `runProfileIDs` is the transitive set (root plus nested sub-workflows). Callers pass
    /// `MainApplicationViewModel.unsavedWorkflowCanvasProfileIDs`, which pulls from live canvas states.
    nonisolated static func shouldDisclose(
        runProfileIDs: Set<UUID>,
        unsavedCanvasProfileIDs: [UUID]
    ) -> Bool {
        unsavedCanvasProfileIDs.contains { runProfileIDs.contains($0) }
    }

    /// Shown in the run's own timeline, live and persisted; must not name internal ids. Phrased about the run, not the
    /// user's editing, since the canvas edits themselves are safe.
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
