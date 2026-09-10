// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProfileReferenceIndex.swift
//  Devgentic
//
//  Created on 08/08/26.
//
//  What else in the app points at a given profile.
//
//  ⚠️ Register A30. `BackendProfileService.deleteProfile` cascaded to exactly one thing — the
//  profile's own workflow layout — and left every other reference dangling. The delete confirmation
//  said only "This action cannot be undone", so a user deleting an agent had no way to know a
//  nightly scheduled task depended on it.
//
//  ⚠️ This enumerates references so the user can be TOLD before deleting. It is not a cascade-delete
//  list: the two referrers are handled differently on purpose, and the difference is the point.
//
//  • **Scheduled tasks** are stopped, not deleted (`SchedulerService.disableTaskWithMissingProfile`).
//    A task is user-authored work — prompt, cron, conversation binding — and deleting it as a side
//    effect of deleting a profile is data loss nobody asked for.
//
//  • **Workflow nodes are left exactly as they are, deliberately.** `WorkflowValidator` already
//    reports an unresolvable profile node as a blocking `.error` ("Profile not found — it may have
//    been deleted."), and `WorkflowExecutor` runs that same validation pre-flight and refuses to
//    start. So the workflow is already prevented from running with a hole in it, from every entry
//    point. Clearing the node's `profileID` would be strictly worse: it would degrade the node to
//    "nothing selected" and destroy the only record of what it used to reference.
//

import Foundation

/// One thing that references a profile, in terms a user recognises.
struct ProfileReference: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A scheduled task bound to this profile. Will be stopped on delete.
        case scheduledTask
        /// A workflow with a node pointing at this profile. Will refuse to run until repointed.
        case workflow
    }

    let id: UUID
    let kind: Kind
    /// The task's or workflow's own name — what the user will look for.
    let displayName: String
}

@MainActor
enum ProfileReferenceIndex {

    /// Everything that points at `profileID`, excluding the profile itself.
    ///
    /// ⚠️ `DownloadRecordSD.profileID` is deliberately NOT included: it is a historical record of a
    /// download that happened, not a live reference, and a dangling id there breaks nothing.
    static func references(to profileID: UUID, in profiles: [BackendProfileModel]) -> [ProfileReference] {
        scheduledTaskReferences(to: profileID) + workflowReferences(to: profileID, in: profiles)
    }

    /// Whether the scheduled-task half of the answer can be trusted.
    ///
    /// ⚠️ register B24 — `scheduledTasks` is empty both when there are none AND when
    /// `loadAllTasks()` has not finished (or threw at launch, which leaves it empty for the whole
    /// session). Reporting "nothing else uses this profile" in the second case is precisely the
    /// silence A30 was filed to end, re-created by the fix's own data source. `SchedulerService`
    /// already tracks `hasLoadedTasks` and consults it everywhere else.
    static var scheduledTasksAreKnown: Bool {
        SchedulerService.shared.hasLoadedTasks
    }

    private static func scheduledTaskReferences(to profileID: UUID) -> [ProfileReference] {
        SchedulerService.shared.scheduledTasks
            .filter { $0.profileID == profileID }
            .map { ProfileReference(id: $0.id, kind: .scheduledTask, displayName: $0.displayName) }
    }

    /// Workflows with at least one node bound to this profile.
    ///
    /// ⚠️ Reads each workflow's LAYOUT rather than its `WorkflowConfig.agentProfileIDs`. The layout
    /// is what the executor actually runs; `agentProfileIDs` is a parallel list that nothing keeps
    /// in step, so trusting it would both miss real references and invent ones that are not there.
    private static func workflowReferences(
        to profileID: UUID,
        in profiles: [BackendProfileModel]
    ) -> [ProfileReference] {
        profiles
            .filter { $0.profileType == .workflow && $0.id != profileID }
            .filter { workflow in
                WorkflowLayoutStore.shared.load(for: workflow.id)
                    .nodes.contains { $0.profileID == profileID }
            }
            .map { ProfileReference(id: $0.id, kind: .workflow, displayName: $0.displayName) }
    }

    /// The sentence shown in the delete confirmation, or nil when nothing references the profile.
    ///
    /// Deliberately states the OUTCOME for each kind rather than just a count: "2 things use this"
    /// tells the user there is a consequence without telling them what it is, which is the same
    /// failure as the original "cannot be undone".
    static func deletionWarning(for references: [ProfileReference]) -> String? {
        guard !references.isEmpty else { return nil }

        let tasks = references.filter { $0.kind == .scheduledTask }
        let workflows = references.filter { $0.kind == .workflow }

        var lines: [String] = []
        if !tasks.isEmpty {
            lines.append(String(
                localized: "\(tasks.count) scheduled task(s) will be stopped: \(names(tasks)). Their prompts and schedules are kept."))
        }
        if !workflows.isEmpty {
            lines.append(String(
                localized: "\(workflows.count) workflow(s) will refuse to run until the node is repointed: \(names(workflows))."))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The COMPLETE confirmation body for deleting `profile` — the identity line plus whatever
    /// else breaks. This is the one every delete entry point must use.
    ///
    /// ⚠️ register B10 — extracted rather than copied. A30 built this message inline in the sidebar
    /// alert, and the three detail-view trash buttons kept the pre-fix "This action cannot be
    /// undone", so the warning landed on the ONE path A26's own note calls the least discoverable.
    /// Pasting the sidebar's twelve lines into three more views would have made four copies of a
    /// message that then drift — this module's most-repeated defect. One function, four callers.
    /// - Parameter tasksAreKnown: injectable so both branches are testable without driving the
    ///   `SchedulerService` singleton. Defaults to the live answer.
    static func deletionMessage(
        for profile: BackendProfileModel,
        in profiles: [BackendProfileModel],
        tasksAreKnown: Bool? = nil
    ) -> String {
        let identity = String(localized: "Delete '\(profile.displayName)'? This can't be undone.")
        var parts = [identity]

        if let warning = deletionWarning(for: references(to: profile.id, in: profiles)) {
            parts.append(warning)
        }

        // ⚠️ Only when nothing was found — if references exist we already have something concrete
        // to show, and hedging on top of it would just dilute the specific warning.
        if !(tasksAreKnown ?? scheduledTasksAreKnown) {
            parts.append(String(
                localized: "Scheduled tasks could not be checked, so any that use this profile are not listed here."))
        }

        return parts.joined(separator: "\n\n")
    }

    /// Caps the list so one profile used by thirty tasks does not produce an unreadable dialog.
    private static func names(_ references: [ProfileReference], limit: Int = 5) -> String {
        let shown = references.prefix(limit).map(\.displayName).joined(separator: ", ")
        let remaining = references.count - min(references.count, limit)
        return remaining > 0
            ? shown + String(localized: " and \(remaining) more")
            : shown
    }
}
