// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PromptStore.swift
//  Devgentic
//
//  Created by Raj Singh on 27/08/25.
//
//  Migrated to SwiftData on 26/03/26.
//  Result-based API (2026-04-21): errors flow up to the service instead of
//  being silently swallowed, so the UI can distinguish "empty library" from
//  "persistence broken."
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "PromptStore")

enum PromptStoreError: LocalizedError, Equatable {
    case containerUnavailable
    case fetchFailed(String)
    case saveFailed(String)
    case notFound(UUID)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return "Prompt storage is unavailable."
        case .fetchFailed(let reason):
            return "Couldn't load prompts: \(reason)"
        case .saveFailed(let reason):
            return "Couldn't save prompt: \(reason)"
        case .notFound(let id):
            return "Prompt \(id.uuidString) was not found."
        }
    }
}

protocol PromptStoreProtocol {
    @MainActor func fetchPrompts() -> Result<[DevPrompt], PromptStoreError>
    @MainActor func addPrompt(from model: DevPrompt) -> Result<Void, PromptStoreError>
    @MainActor func updatePrompt(from model: DevPrompt) -> Result<Void, PromptStoreError>
    @MainActor func deletePrompt(withId id: UUID) -> Result<Void, PromptStoreError>
}

class PromptStore: PromptStoreProtocol {

    static let shared = PromptStore()

    /// The shared model container, injected during app init via the SwiftData container.
    private var modelContainer: ModelContainer?

    @MainActor
    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    private init() {}

    /// Call this once from the App init to inject the container.
    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    @MainActor
    func fetchPrompts() -> Result<[DevPrompt], PromptStoreError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }

        do {
            let descriptor = FetchDescriptor<PromptModel>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let models = try context.fetch(descriptor)

            // Normalize legacy/imported categories to their canonical casing
            // (e.g. "general" → "General") so the sidebar badge and the
            // category chip render the same string. Only rewrites when a
            // case-insensitive match exists — truly unknown strings are left
            // untouched so user-authored custom categories survive.
            var normalizedCount = 0
            for model in models {
                if PromptCategory(rawValue: model.category) != nil {
                    continue  // Already canonical — no-op.
                }
                if let canonical = PromptCategory.allCases.first(where: {
                    $0.rawValue.caseInsensitiveCompare(model.category) == .orderedSame
                }) {
                    model.category = canonical.rawValue
                    normalizedCount += 1
                }
                // else: unknown string (custom/user-authored) — leave as-is.
            }
            if normalizedCount > 0 {
                logger.info("Normalized \(normalizedCount) prompt categories to canonical casing.")
                try? context.save()
            }

            let prompts = models.map { $0.toDevPrompt() }
            logger.info("Successfully fetched \(prompts.count) prompts.")
            return .success(prompts)
        } catch {
            logger.error("Failed to fetch prompts: \(error.localizedDescription)")
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    @MainActor
    func addPrompt(from model: DevPrompt) -> Result<Void, PromptStoreError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }

        let newModel = PromptModel(
            id: model.id,
            title: model.title,
            text: model.text,
            category: model.category,
            createdAt: model.createdAt,
            lastUsedAt: model.lastUsedAt,
            isUserDefined: model.isUserDefined,
            tags: model.tags,
            isPinned: model.isPinned
        )
        context.insert(newModel)
        logger.info("Adding new prompt '\(model.title)'.")
        return saveContext()
    }

    @MainActor
    func updatePrompt(from model: DevPrompt) -> Result<Void, PromptStoreError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }

        let targetID = model.id
        let predicate = #Predicate<PromptModel> { $0.id == targetID }
        var descriptor = FetchDescriptor<PromptModel>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.apply(from: model)
                logger.info("Updating prompt '\(model.title)'.")
                return saveContext()
            } else {
                logger.warning("Prompt not found for update (ID: \(model.id.uuidString)). Adding instead.")
                return addPrompt(from: model)
            }
        } catch {
            logger.error("Failed to fetch prompt for update: \(error.localizedDescription)")
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    @MainActor
    func deletePrompt(withId id: UUID) -> Result<Void, PromptStoreError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }

        let predicate = #Predicate<PromptModel> { $0.id == id }
        var descriptor = FetchDescriptor<PromptModel>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let toDelete = try context.fetch(descriptor).first {
                context.delete(toDelete)
                logger.info("Deleting prompt with ID \(id.uuidString).")
                return saveContext()
            }
            return .failure(.notFound(id))
        } catch {
            logger.error("Failed to fetch prompt for deletion: \(error.localizedDescription)")
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    @MainActor
    private func saveContext() -> Result<Void, PromptStoreError> {
        guard let context = mainContext else { return .failure(.containerUnavailable) }
        do {
            try context.save()
            return .success(())
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
