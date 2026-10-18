// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowLayoutStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutStore")

/// What actually happened to a `save`; a caller cannot surface a refused write (e.g. over an unreadable canvas) it is
/// never told about.
enum WorkflowLayoutSaveOutcome: Equatable {

    /// The layout reached disk.
    case saved

    /// No container yet — the write was dropped.
    case notConfigured

    /// The stored canvas could not be decoded, so the write was refused to protect the original bytes. Carries the
    /// denormalized counts, which live outside the blob. Repair via `repairUnreadableLayout(_:for:reason:)`.
    case refusedUnreadable(nodeCount: Int, edgeCount: Int, annotationCount: Int)

    /// The stored blob was written by a NEWER build; re-encoding here would strip its fields
    /// permanently (WF-PE2). Byte-intact refusal; the canvas is read-only until the app updates.
    case refusedNewerVersion(blobVersion: Int, appVersion: Int)

    /// SwiftData raised on fetch or save.
    case failed(String)

    /// True only when the bytes are on disk.
    var didPersist: Bool { self == .saved }

    /// True for the two outcomes refused by design, which refuse identically on every attempt, unlike
    /// `.failed`/`.notConfigured`, which may succeed on retry. Both refusals return before any mutation, so a refused-only
    /// batch has nothing to roll back.
    var isRefusedByDesign: Bool {
        switch self {
        case .refusedUnreadable, .refusedNewerVersion: return true
        case .saved, .notConfigured, .failed: return false
        }
    }

    /// User-facing reason for a refused-by-design outcome at quit time; nil for every other case. Separate from the canvas's
    /// own copy, which carries view-local state; kept here so the wording is testable.
    var quitTimeRefusalReason: String? {
        switch self {
        case .refusedNewerVersion(let blobVersion, let appVersion):
            return String(localized: "This workflow was saved by a newer version of Devgentic (v\(blobVersion) format; this build writes v\(appVersion)). It's read-only here — update Devgentic to edit it.")
        case .refusedUnreadable:
            return String(localized: "This workflow's saved layout can't be read by this build, so edits are refused to keep the original bytes intact.")
        case .saved, .notConfigured, .failed:
            return nil
        }
    }
}

@MainActor
final class WorkflowLayoutStore {

    // MARK: - Singleton

    static let shared = WorkflowLayoutStore()
    private init() {}

    // MARK: - Write Generation

    /// Bumped on every write that changes a stored layout (save, repair, delete), so a cache of other workflows' layouts can
    /// tell that one changed. A single counter keeps the comparison cheap enough for `revalidate()`, which runs on every
    /// node drag.
    private(set) var writeGeneration: Int = 0

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    /// Called once from `DevgenticApp` after the shared `ModelContainer` is built.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("WorkflowLayoutStore configured with SwiftData ModelContainer.")
    }

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    // MARK: - Public API (matches the old UserDefaults-backed signature)

    // Why: resolved by the caller, not the validator: the validator is pure and re-runs on every canvas edit, so
    // loading there would fetch on every keystroke.
    /// Loads every workflow layout reachable from `layout` through sub-workflow nodes, keyed by workflow profile ID, for
    /// `WorkflowValidator`'s nesting and cycle rules. The visited set exists for termination: a self-containing workflow
    /// would recurse forever while loading.
    func resolveNestedLayouts(from layout: WorkflowLayout) -> [UUID: WorkflowLayout] {
        var resolved: [UUID: WorkflowLayout] = [:]
        var visited = Set<UUID>()
        var queue = Self.subWorkflowProfileIDs(in: layout)

        while let profileID = queue.popLast() {
            guard visited.insert(profileID).inserted else { continue }
            let sub = load(for: profileID)
            resolved[profileID] = sub
            queue.append(contentsOf: Self.subWorkflowProfileIDs(in: sub))
        }
        return resolved
    }

    /// Every workflow this layout references, with the node that references it. The single definition of what other
    /// workflows a graph runs; any future node kind that references a workflow must be added here only.
    nonisolated static func workflowReferences(in layout: WorkflowLayout) -> [(profileID: UUID, nodeName: String)] {
        layout.nodes.compactMap { node in
            if case .profile(let id, .workflow) = node.kind { return (id, node.displayName) }
            return nil
        }
    }

    /// Profile IDs of every workflow this layout references (sub-workflow nodes).
    nonisolated static func subWorkflowProfileIDs(in layout: WorkflowLayout) -> [UUID] {
        workflowReferences(in: layout).map(\.profileID)
    }

    func load(for profileID: UUID) -> WorkflowLayout {
        loadWithOutcome(for: profileID).layout
    }

    /// The layout, plus whether the read succeeded. `load(for:)` collapses 'no saved row' and 'the fetch threw' into
    /// `.empty`; any caller that writes or decides what to delete must consult `didFail` first, or a transient failure
    /// overwrites the real graph and its credentials.
    func loadWithOutcome(for profileID: UUID) -> (layout: WorkflowLayout, didFail: Bool) {
        guard let context = mainContext else {
            logger.error("load(for:) called before container was configured — returning .empty. CONSEQUENCE: the caller cannot distinguish this from an empty workflow; a writer must treat it as a FAILED read and refuse to save over it.")
            return (.empty, true)
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            // A missing row is a SUCCESSFUL read of a workflow that has never been saved — not a
            // failure. Only a throw is a failure.
            return (try context.fetch(descriptor).first?.layout ?? .empty, false)
        } catch {
            logger.error("Failed to fetch layout for \(profileID): \(error.localizedDescription) — returning .empty with didFail. CONSEQUENCE: the canvas renders blank; any save or owned-row reconcile for this workflow must be refused until a read succeeds, or a transient error becomes permanent deletion.")
            return (.empty, true)
        }
    }

    /// Upserts the layout for a workflow profile: updates the existing row in place (`@Attribute(.unique)`), else inserts a
    /// new one. Returns the outcome; a write over an unreadable canvas is refused, so UI save paths should check
    /// `didPersist`.
    @discardableResult
    func save(_ layout: WorkflowLayout, for profileID: UUID) -> WorkflowLayoutSaveOutcome {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] save(_:for:) called before the container was configured — profile "
                + "\(profileID). CONSEQUENCE: this canvas edit is dropped and never reaches disk."
            )
            return .notConfigured
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        // Fetched outside the mutate-then-save scope so a fetch throw (nothing to undo) differs from a save throw (a pending
        // mutation that another store's next save on the shared `mainContext` would flush).
        let existing: WorkflowLayoutSD?
        do {
            existing = try context.fetch(descriptor).first
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to fetch the layout row for \(profileID) before saving: "
                + "\(error.localizedDescription). CONSEQUENCE: nothing was written or mutated; this "
                + "canvas edit is not on disk and stays in memory for another attempt."
            )
            return .failed(error.localizedDescription)
        }

        if let existing {
            // Ask BEFORE writing. The setter refuses silently (by design — it must not throw
            // from a property), so the refusal is only observable by checking first.
            if existing.hasNewerVersionLayout {
                let blobVersion = existing.newerBlobVersion ?? -1
                logger.error(
                    "[PERSISTENCE] Canvas save REFUSED — profile \(profileID): the stored layout "
                    + "was written by a NEWER build (blob v\(blobVersion), this build writes "
                    + "v\(WorkflowLayoutSD.layoutBlobVersion)); re-encoding would permanently strip "
                    + "every newer-version field. CONSEQUENCE: layoutData is left byte-intact and "
                    + "saves are refused on this build; viewing and running still work. The user "
                    + "needs the app update that wrote this layout."
                )
                return .refusedNewerVersion(
                    blobVersion: blobVersion,
                    appVersion: WorkflowLayoutSD.layoutBlobVersion
                )
            }
            if existing.hasUnreadableLayout {
                logger.error(
                    "[PERSISTENCE] Canvas save REFUSED — profile \(profileID): the stored layout "
                    + "could not be decoded, so this save would replace \(existing.nodeCount) "
                    + "node(s)/\(existing.edgeCount) edge(s)/\(existing.annotationCount) "
                    + "annotation(s) the user cannot see. CONSEQUENCE: layoutData is left "
                    + "byte-intact and EVERY save for this profile will be refused until "
                    + "repairUnreadableLayout(_:for:reason:) is called; the caller must tell the "
                    + "user rather than letting them keep editing."
                )
                return .refusedUnreadable(
                    nodeCount: existing.nodeCount,
                    edgeCount: existing.edgeCount,
                    annotationCount: existing.annotationCount
                )
            }
            // Captured before the mutation so a save throw can restore it; decoding is safe because unreadable and newer-version
            // rows were refused above.
            let priorLayout = existing.layout
            existing.layout = layout    // setter refreshes blob + denormalized counts + updatedAt
            do {
                try SharedContextSave.save(context, "workflow layout: save \(profileID)")
                writeGeneration &+= 1
                return .saved
            } catch {
                // Un-mutate this row only, never `context.rollback()`, which would discard every pending change on the shared
                // mainContext. Re-running the setter restores blob, counts and cache together (`updatedAt` is re-stamped).
                existing.layout = priorLayout
                logger.error(
                    "[PERSISTENCE] Failed to save layout for \(profileID): \(error.localizedDescription). "
                    + "CONSEQUENCE: this canvas edit is not on disk and will be lost on reload. The "
                    + "in-memory row was ROLLED BACK to its pre-save state, so the failed layout "
                    + "cannot ride out on the shared context's next unrelated save."
                )
                return .failed(error.localizedDescription)
            }
        } else {
            // The first save of a profile goes through a throwaway context, so a failed save leaves nothing pending by
            // construction; retracting an insert on the shared context does not work, as SwiftData still returns it from a fetch.
            guard let container = modelContainer else { return .notConfigured }
            let scratch = ModelContext(container)
            scratch.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            do {
                try SharedContextSave.save(scratch, "workflow layout: first save \(profileID)", scope: .throwaway)
                writeGeneration &+= 1
                return .saved
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to save the FIRST layout for \(profileID): "
                    + "\(error.localizedDescription). CONSEQUENCE: this canvas edit is not on disk "
                    + "and will be lost on reload. The insert was staged on a throwaway context, so "
                    + "nothing is left pending to ride out on the shared context's next save."
                )
                return .failed(error.localizedDescription)
            }
        }
    }

    /// Reports whether this profile's stored canvas is unreadable, so a view can say so instead of presenting an empty
    /// canvas as the user's own.
    func isLayoutUnreadable(for profileID: UUID) -> Bool {
        guard let context = mainContext else { return false }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)??.hasUnreadableLayout ?? false
    }

    /// The denormalized counts for this profile's stored layout; they live outside the blob and come from the last
    /// successful save, so they stay trustworthy when the blob is not. Zeroes when there is no row.
    func storedCounts(for profileID: UUID) -> (nodes: Int, edges: Int, annotations: Int) {
        guard let context = mainContext else { return (0, 0, 0) }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return (0, 0, 0) }
        return (row.nodeCount, row.edgeCount, row.annotationCount)
    }

    /// Discards an unreadable canvas and replaces it, the only sanctioned way past the refusal. Destructive and
    /// irreversible, and not reachable from `save`; callers should confirm with the user first, quoting the counts from
    /// `.refusedUnreadable`.
    @discardableResult
    func repairUnreadableLayout(
        _ layout: WorkflowLayout,
        for profileID: UUID,
        reason: String
    ) -> WorkflowLayoutSaveOutcome {
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] repairUnreadableLayout called before the container was configured — "
                + "profile \(profileID). CONSEQUENCE: the canvas stays unreadable and unsaveable."
            )
            return .notConfigured
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        // Why: the existing row stays on mainContext: a throwaway context's update does not refresh the `@Transient`
        // decoded-layout cache.
        // Failure paths touch only their own work, never `context.rollback()` on the shared mainContext, which discards others'
        // pending changes: an existing row is restored field by field, a missing one inserted on a throwaway context.
        let existing: WorkflowLayoutSD?
        do {
            existing = try context.fetch(descriptor).first
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to fetch the layout row for \(profileID) before repairing it: "
                + "\(error.localizedDescription). CONSEQUENCE: nothing was written or mutated; the "
                + "canvas stays unreadable and every save stays refused."
            )
            return .failed(error.localizedDescription)
        }

        if let existing {
            let prior = existing.storedState
            existing.replaceUnreadableLayout(layout, reason: reason)
            do {
                try SharedContextSave.save(context, "workflow layout: repair \(profileID)")
            } catch {
                existing.restore(prior)
                logger.error(
                    "[PERSISTENCE] Failed to repair layout for \(profileID): "
                    + "\(error.localizedDescription). CONSEQUENCE: the canvas remains unreadable and "
                    + "every save stays refused. Only THIS row was put back to its stored bytes; other "
                    + "subsystems' pending changes on the shared context are untouched."
                )
                return .failed(error.localizedDescription)
            }
        } else {
            guard let container = modelContainer else { return .notConfigured }
            let scratch = ModelContext(container)
            scratch.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            do {
                try SharedContextSave.save(scratch, "workflow layout: repair-insert \(profileID)", scope: .throwaway)
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to write the repaired layout for \(profileID) (no row existed): "
                    + "\(error.localizedDescription). CONSEQUENCE: the canvas is not on disk. The insert "
                    + "was staged on a throwaway context, so nothing is left pending on the shared one."
                )
                return .failed(error.localizedDescription)
            }
        }
        logger.warning(
            "[PERSISTENCE] Unreadable canvas REPAIRED — profile \(profileID), reason: \(reason). "
            + "CONSEQUENCE: the previous undecodable bytes are overwritten and unrecoverable; "
            + "saves for this profile work normally again."
        )
        writeGeneration &+= 1
        return .saved
    }

    /// Deletes the layout row for a workflow profile (if any). Called from the
    /// cascade hook in `BackendProfileService.deleteProfile` so a deleted
    /// workflow profile doesn't leave an orphan layout behind.
    func delete(for profileID: UUID) {
        // The delete is staged on a throwaway context, so a failed save leaves no pending delete on the shared mainContext and
        // needs no rollback; its committed delete is visible to mainContext's next fetch.
        guard let container = modelContainer else {
            logger.error("[PERSISTENCE] delete(for:) called before the container was configured — profile \(profileID). CONSEQUENCE: the layout row (if any) is left in place as an orphan.")
            return
        }
        let scratch = ModelContext(container)

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try scratch.fetch(descriptor).first {
                scratch.delete(existing)
                try SharedContextSave.save(scratch, "workflow layout: delete \(profileID)", scope: .throwaway)
                // A deleted child is a CHANGE to what a parent's nesting validation sees.
                writeGeneration &+= 1
                logger.info("Deleted layout for profile \(profileID).")
            }
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to delete layout for \(profileID): \(error.localizedDescription). "
                + "CONSEQUENCE: the row is left in place as an orphan of the deleted profile. The delete "
                + "was staged on a throwaway context, so nothing is left pending to commit it later."
            )
        }
    }
}
