// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ReportOnlyRun.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "ReportOnlyRun")

/// A run that may answer but may not act, used when the agent is woken to report a finished background task that
/// nobody is watching. Profile tools are stripped for the turn through task-locals, as `WorkflowRunAttendance` does;
/// the user can reply for a normal attended turn.
enum ReportOnlyRun {

    /// True for a run that may answer but may not act. Defaults to false so existing paths are unchanged and a new caller
    /// must opt in; the opposite default would silently disarm the toolset.
    @TaskLocal static var isActive: Bool = false

    /// The profile tools a run is allowed, given what kind of run it is. Called where each pipeline assembles its
    /// loadout, so report-only is honoured on every path.
    static func allowedProfileTools(_ tools: [Tool]) -> [Tool] {
        guard isActive else { return tools }
        // Logged because the stripping is otherwise unobservable and the run's safety rests on it; without it, "was that run
        // report-only?" cannot be answered from a log.
        logger.notice("[REPORTONLY] Stripped all \(tools.count) profile tool(s) from this run's loadout. CONSEQUENCE: the run can call only injected tools that change nothing (final_answer, ask_user, get_conversation_history, load_skill, recall), so it can report on the task's output but cannot act on it — which matters because that output is whatever a command chose to print.")
        return []
    }

    // MARK: - Injected tools

    // Why: `remember` and `forget` are injected after the profile is trimmed and need no confirmation, so untrusted
    // background output could steer them into persistent project knowledge.
    /// Injected tools that change state outliving the run, withheld from a report-only run; names come from the tools
    /// themselves.
    static let stateChangingInjectedToolNames: Set<String> = [
        RememberTool(projectPath: "", conversationID: nil).name,
        ForgetTool(projectPath: "").name,
    ]

    /// Injected tools a report-only run keeps: they answer, ask or read, and nothing persists. With
    /// `stateChangingInjectedToolNames` it must cover every injected tool; `ReportOnlyRunTests` fails if a new one is in
    /// neither set.
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
