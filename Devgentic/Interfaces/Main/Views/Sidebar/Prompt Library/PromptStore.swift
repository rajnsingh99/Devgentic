//
//  PromptStore.swift
//  Devgentic
//
//  Created by Raj Singh on 27/08/25.
//
//  Migrated to SwiftData on 26/03/26.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "PromptStore")

protocol PromptStoreProtocol {
    func fetchPrompts() -> [DevPrompt]
    func addPrompt(from model: DevPrompt)
    func updatePrompt(from model: DevPrompt)
    func deletePrompt(withId id: UUID)
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
    func fetchPrompts() -> [DevPrompt] {
        guard let context = mainContext else { return [] }

        do {
            let descriptor = FetchDescriptor<PromptModel>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let models = try context.fetch(descriptor)
            let prompts = models.map { $0.toDevPrompt() }
            logger.info("Successfully fetched \(prompts.count) prompts.")
            return prompts
        } catch {
            logger.error("Failed to fetch prompts: \(error.localizedDescription)")
            return []
        }
    }

    @MainActor
    func addPrompt(from model: DevPrompt) {
        guard let context = mainContext else { return }

        let newModel = PromptModel(
            id: model.id,
            title: model.title,
            text: model.text,
            category: model.category,
            createdAt: model.createdAt,
            lastUsedAt: model.lastUsedAt,
            isUserDefined: model.isUserDefined,
            tags: model.tags
        )
        context.insert(newModel)
        logger.info("Adding new prompt '\(model.title)'.")
        saveContext()
    }

    @MainActor
    func updatePrompt(from model: DevPrompt) {
        guard let context = mainContext else { return }

        let targetID = model.id
        let predicate = #Predicate<PromptModel> { $0.id == targetID }
        var descriptor = FetchDescriptor<PromptModel>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let existing = try context.fetch(descriptor).first {
                existing.apply(from: model)
                logger.info("Updating prompt '\(model.title)'.")
                saveContext()
            } else {
                logger.warning("Prompt not found for update (ID: \(model.id.uuidString)). Adding instead.")
                addPrompt(from: model)
            }
        } catch {
            logger.error("Failed to fetch prompt for update: \(error.localizedDescription)")
        }
    }

    @MainActor
    func deletePrompt(withId id: UUID) {
        guard let context = mainContext else { return }

        let predicate = #Predicate<PromptModel> { $0.id == id }
        var descriptor = FetchDescriptor<PromptModel>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let toDelete = try context.fetch(descriptor).first {
                context.delete(toDelete)
                logger.info("Deleting prompt with ID \(id.uuidString).")
                saveContext()
            }
        } catch {
            logger.error("Failed to fetch prompt for deletion: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func saveContext() {
        guard let context = mainContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save SwiftData context: \(error.localizedDescription)")
        }
    }
}
