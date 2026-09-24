// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReportOnlyRun.swift
//  Devgentic
//
//  A run that may ANSWER but may not ACT.
//
//  ── Why this exists ─────────────────────────────────────────────────────────────────────
//
//  Tier 3 wakes the agent when a background task finishes, so the result is reported instead of
//  falling on the floor when the turn has already ended. That run has a property none of the
//  others do: **nobody is watching it**. It was not typed, nothing is waiting on it, and the user
//  may be in another app entirely.
//
//  An unconstrained run in that position is an autonomous agent. A model that sees a failed build
//  will start editing files, and the first the user knows of it is a diff they did not ask for —
//  against their own API key. Report-only makes the wake cheap, bounded, and unable to spiral: it
//  reads the outcome and says what happened. If more is wanted, the user replies, and that is an
//  ordinary attended turn with the full toolset.
//
//  ── Why a task-local ────────────────────────────────────────────────────────────────────
//
//  Tools come from the PROFILE (`config.tools`), and a profile is persisted and shared across
//  every run that uses it. Trimming one for a single turn would either mutate stored state or
//  require a parallel "transient profile" concept.
//
//  `WorkflowRunAttendance` already solved the same shape of problem — per-run facts that every
//  layer needs and no layer should have to thread through — with task-locals bound once in
//  `ActiveStreamManager.startMessageStream`. This follows it deliberately, so there is one pattern
//  for "what kind of run is this" rather than two.
//
//  ⚠️ `final_answer` is NOT removed by this, and must not be. It is an INJECTED control-plane tool
//  built by `AgentConnect` (see `NativeToolCatalog.injectedTools`), never a profile tool, so
//  emptying the profile's list leaves the one call the run exists to make. Stripping the profile
//  tools is what makes the run report-only; stripping `final_answer` would make it unable to
//  answer at all.
//

import Foundation
import os

private let logger = DGLogger(category: "ReportOnlyRun")

enum ReportOnlyRun {

    /// True for a run that may answer but may not act.
    ///
    /// ⚠️ Defaults to FALSE, so every existing path is unchanged and a new caller has to opt IN.
    /// The opposite default would silently disarm the toolset for any run that forgot to say it
    /// was attended — the kind of safe-looking default that removes a capability without anyone
    /// noticing.
    @TaskLocal static var isActive: Bool = false

    /// The profile tools a run is allowed, given what kind of run it is.
    ///
    /// Called at the one place each pipeline assembles its loadout, so "report-only" cannot be
    /// honoured on one path and ignored on the other.
    static func allowedProfileTools(_ tools: [Tool]) -> [Tool] {
        guard isActive else { return tools }
        // ⚠️ SAID OUT LOUD, because this is otherwise unobservable. Nothing on screen distinguishes
        // a report-only run from an ordinary one, and the woken run's whole safety argument rests on
        // this having happened — the task output it is reading is untrusted text. Without this line
        // "was that run actually report-only?" is unanswerable from a device log.
        logger.notice("[REPORTONLY] Stripped all \(tools.count) profile tool(s) from this run's loadout. CONSEQUENCE: the run can call only the injected control-plane tools (final_answer, ask_user, get_conversation_history), so it can report on the task's output but cannot act on it — which matters because that output is whatever a command chose to print.")
        return []
    }
}
