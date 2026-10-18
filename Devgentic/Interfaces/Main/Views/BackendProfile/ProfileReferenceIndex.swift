// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProfileReferenceIndex.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Returns everything that points at `profileID`, excluding the profile itself. `DownloadRecordSD.profileID` is not
    /// included: it is a historical record, not a live reference.
    static func references(to profileID: UUID, in profiles: [BackendProfileModel]) -> [ProfileReference] {
        scheduledTaskReferences(to: profileID) + workflowReferences(to: profileID, in: profiles)
    }

    /// Whether the scheduled-task half of the answer can be trusted. `scheduledTasks` is empty both when there are none
    /// and when loading has not finished or failed, so "nothing uses this profile" is only claimed when
    /// `SchedulerService.hasLoadedTasks` is true.
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
    /// Reads each workflow's LAYOUT — the record of what the executor actually runs.
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

    /// The sentence shown in the delete confirmation, or nil when nothing references the profile. States the outcome
    /// for each kind of reference rather than just a count.
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

    /// The complete confirmation body for deleting `profile`: the identity line plus whatever else breaks; every delete
    /// entry point uses it. `tasksAreKnown` is injectable so both branches are testable without the `SchedulerService`
    /// singleton; it defaults to the live answer.
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

        // Only when nothing was found: if references exist the specific warning is enough, and hedging would dilute it.
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
