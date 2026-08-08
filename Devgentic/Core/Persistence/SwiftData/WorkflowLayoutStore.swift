//
//  WorkflowLayoutStore.swift
//  Devgentic
//
//  SwiftData-backed persistence for workflow canvas layouts.
//  Migrated from UserDefaults (was previously a private class inside
//  `WorkflowCanvasView.swift`).
//
//  Public API is preserved (`load`, `save`, `delete`) so existing call sites
//  (canvas view, executor, dedicated view) don't need to change beyond removing
//  the old inline definition.
//
//  Concurrency: `@MainActor`-isolated, matching `BackendProfileStore` and
//  `DownloadHistoryStore`. Off-main callers (notably `WorkflowExecutor`, which
//  is an actor) must hop with `await MainActor.run`.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "WorkflowLayoutStore")

/// What actually happened to a `save`.
///
/// ⚠️ `save` used to return `Void`. That was fine while every write succeeded, but once
/// `WorkflowLayoutSD` began REFUSING writes over an unreadable canvas the refusal had nowhere to go:
/// the model logged it, the store returned, and the canvas kept accepting edits that were silently
/// discarded for the rest of the session. A caller cannot surface what it is never told.
enum WorkflowLayoutSaveOutcome: Equatable {

    /// The layout reached disk.
    case saved

    /// No container yet — the write was dropped.
    case notConfigured

    /// The stored canvas could not be decoded, so the write was refused to protect the original
    /// bytes. Carries the denormalized counts, which live outside the blob and say what the row
    /// used to hold — that is the evidence a UI should put in front of the user.
    /// Repair via `repairUnreadableLayout(_:for:reason:)`.
    case refusedUnreadable(nodeCount: Int, edgeCount: Int, annotationCount: Int)

    /// SwiftData raised on fetch or save.
    case failed(String)

    /// True only when the bytes are on disk.
    var didPersist: Bool { self == .saved }
}

@MainActor
final class WorkflowLayoutStore {

    // MARK: - Singleton

    static let shared = WorkflowLayoutStore()
    private init() {}

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

    /// Loads the layout for a given workflow profile. Returns `.empty` on miss
    /// (no row, no container, or decode failure) — the canvas treats an empty
    /// layout as a fresh workflow.
    func load(for profileID: UUID) -> WorkflowLayout {
        guard let context = mainContext else {
            logger.error("load(for:) called before container was configured — returning .empty.")
            return .empty
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first?.layout ?? .empty
        } catch {
            logger.error("Failed to fetch layout for \(profileID): \(error.localizedDescription) — returning .empty.")
            return .empty
        }
    }

    /// Upserts the layout for a workflow profile. If a row already exists it's
    /// updated in place (the `@Attribute(.unique)` constraint enforces 1:1);
    /// otherwise a new row is inserted.
    ///
    /// ⚠️ Returns the outcome rather than `Void`: a write over an unreadable canvas is REFUSED by
    /// `WorkflowLayoutSD`, and a caller that is not told keeps letting the user edit a canvas whose
    /// every save is being thrown away. `@discardableResult` so the fire-and-forget callers that
    /// genuinely do not care still compile, but a UI save path should check `didPersist`.
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

        do {
            if let existing = try context.fetch(descriptor).first {
                // Ask BEFORE writing. The setter refuses silently (by design — it must not throw
                // from a property), so the refusal is only observable by checking first.
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
                existing.layout = layout    // setter refreshes blob + denormalized counts + updatedAt
            } else {
                context.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            }
            try context.save()
            return .saved
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to save layout for \(profileID): \(error.localizedDescription). "
                + "CONSEQUENCE: this canvas edit is not on disk and will be lost on reload."
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Reports whether this profile's stored canvas is unreadable, so a view can say so instead of
    /// presenting an empty canvas as the user's own.
    ///
    /// Exists because `hasUnreadableLayout` lives on the `@Model` and every UI layer goes through
    /// this store — without it the flag has no reachable consumer.
    func isLayoutUnreadable(for profileID: UUID) -> Bool {
        guard let context = mainContext else { return false }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)??.hasUnreadableLayout ?? false
    }

    /// The denormalized counts for this profile's stored layout.
    ///
    /// These live OUTSIDE the blob and were written by the last SUCCESSFUL save, so they remain
    /// trustworthy when the blob itself is not — which is what lets the canvas say "it last held
    /// 5 nodes" rather than something vague. Zeroes when there is no row.
    func storedCounts(for profileID: UUID) -> (nodes: Int, edges: Int, annotations: Int) {
        guard let context = mainContext else { return (0, 0, 0) }
        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1
        guard let row = try? context.fetch(descriptor).first else { return (0, 0, 0) }
        return (row.nodeCount, row.edgeCount, row.annotationCount)
    }

    /// Discards an unreadable canvas and replaces it — the only sanctioned way past the refusal.
    ///
    /// ⚠️ DESTRUCTIVE and irreversible: the undecodable bytes are gone afterwards. Deliberately not
    /// reachable from `save`, so it can only happen when a caller has explicitly decided to. Callers
    /// should confirm with the user first, quoting the counts from `.refusedUnreadable`.
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

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.replaceUnreadableLayout(layout, reason: reason)
            } else {
                context.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            }
            try context.save()
            logger.warning(
                "[PERSISTENCE] Unreadable canvas REPAIRED — profile \(profileID), reason: \(reason). "
                + "CONSEQUENCE: the previous undecodable bytes are overwritten and unrecoverable; "
                + "saves for this profile work normally again."
            )
            return .saved
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to repair layout for \(profileID): "
                + "\(error.localizedDescription). CONSEQUENCE: the canvas remains unreadable and "
                + "every save stays refused."
            )
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes the layout row for a workflow profile (if any). Called from the
    /// cascade hook in `BackendProfileService.deleteProfile` so a deleted
    /// workflow profile doesn't leave an orphan layout behind.
    func delete(for profileID: UUID) {
        guard let context = mainContext else {
            logger.error("delete(for:) called before container was configured — drop.")
            return
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                context.delete(existing)
                try context.save()
                logger.info("Deleted layout for profile \(profileID).")
            }
        } catch {
            logger.error("Failed to delete layout for \(profileID): \(error.localizedDescription)")
        }
    }
}
