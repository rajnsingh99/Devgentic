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
        logger.notice("[REPORTONLY] Stripped all \(tools.count) profile tool(s) from this run's loadout. CONSEQUENCE: the run can call only injected tools that change nothing (final_answer, ask_user, get_conversation_history, load_skill, recall), so it can report on the task's output but cannot act on it — which matters because that output is whatever a command chose to print.")
        return []
    }

    // MARK: - Injected tools

    /// Injected tools that change state OUTLIVING the run, and so are withheld from a report-only run.
    ///
    /// ⚠️⚠️ WHY (readiness CR-17, 2026-10-10). Stripping the PROFILE's tools was the whole of
    /// report-only, but `remember` and `forget` are INJECTED — appended by `AgentConnect` after the
    /// profile is trimmed — and need no confirmation. So a woken run reading untrusted background-task
    /// output (a test or build log, verbatim) could be steered to `remember` injected text, which
    /// `codeProjectKnowledge` then puts into the system prompt of EVERY future Code run in that
    /// project — or to `forget` real entries. A one-turn prompt injection became a persistent one.
    ///
    /// Names come from the tools themselves, never typed here.
    static let stateChangingInjectedToolNames: Set<String> = [
        RememberTool(projectPath: "", conversationID: nil).name,
        ForgetTool(projectPath: "").name,
    ]

    /// Injected tools a report-only run keeps: they answer, ask, or read — nothing persists.
    ///
    /// ⚠️ Together with `stateChangingInjectedToolNames` this must cover EVERY injected tool —
    /// `ReportOnlyRunTests` fails when a new one is added without being put in one set or the other,
    /// so the decision "may an unwatched run call this?" cannot be skipped.
    static let readOnlyInjectedToolNames: Set<String> = [
        FinalAnswerTool().name,
        AskUserTool(richFields: true).name,
        ConversationHistoryTool(chatHistory: [], correlation: "").name,
        LoadSkillTool(manifests: []).name,
        RecallTool(projectPath: "").name,
    ]

    /// The injected tools a run is allowed, given what kind of run it is.
    static func allowedInjectedTools(_ tools: [AgentTool]) -> [AgentTool] {
        guard isActive else { return tools }
        let withheld = tools.filter { stateChangingInjectedToolNames.contains($0.name) }.map(\.name)
        guard !withheld.isEmpty else { return tools }
        logger.notice("[REPORTONLY] Withheld \(withheld.sorted().joined(separator: ", ")) from this run. CONSEQUENCE: an unwatched run reading untrusted task output cannot write or delete project memory — what it saved would reach the system prompt of every later Code run in this project. The user's next attended turn has them again.")
        return tools.filter { !stateChangingInjectedToolNames.contains($0.name) }
    }
}
