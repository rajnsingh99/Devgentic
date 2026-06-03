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
    func save(_ layout: WorkflowLayout, for profileID: UUID) {
        guard let context = mainContext else {
            logger.error("save(_:for:) called before container was configured — drop.")
            return
        }

        let predicate = #Predicate<WorkflowLayoutSD> { $0.workflowProfileID == profileID }
        var descriptor = FetchDescriptor<WorkflowLayoutSD>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.layout = layout    // setter refreshes blob + denormalized counts + updatedAt
            } else {
                context.insert(WorkflowLayoutSD(workflowProfileID: profileID, layout: layout))
            }
            try context.save()
        } catch {
            logger.error("Failed to save layout for \(profileID): \(error.localizedDescription)")
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
