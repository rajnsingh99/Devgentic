//
//  PromptStore.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

// Stores/PromptStore.swift
import Foundation
import Combine
import os

/// Manages the collection of prompts, handling persistence and providing access.
@MainActor // Ensures changes to @Published properties are on the main thread
class PromptStore: ObservableObject {
    static let shared = PromptStore()

    private let persistenceService = PromptPersistenceService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptStore")

    /// The collection of all prompts, published for UI updates.
    @Published var prompts: [Prompt] = []

    private init() {
        loadPrompts()
        if prompts.isEmpty {
            logger.info("Prompt library is empty. Adding default example prompts.")
            prompts.append(contentsOf: Prompt.examplePrompts)
            saveChanges() // Save the default prompts
        }
        logger.info("PromptStore initialized. Loaded \(self.prompts.count) prompts.")
    }

    /// Loads prompts from the persistence service.
    private func loadPrompts() {
        self.prompts = persistenceService.loadPrompts().sorted(by: { $0.createdAt > $1.createdAt })
    }

    /// Saves all current prompts to the persistence service.
    private func saveChanges() {
        persistenceService.savePrompts(self.prompts)
        logger.debug("Changes saved to persistence by PromptStore.")
    }

    // MARK: - CRUD Operations

    /// Adds a new prompt to the store and saves changes.
    /// - Parameter prompt: The `Prompt` to add.
    func addPrompt(_ prompt: Prompt) {
        if prompts.contains(where: { $0.id == prompt.id }) {
            logger.warning("Attempted to add a prompt with an existing ID: \(prompt.id.uuidString). Updating instead.")
            updatePrompt(prompt)
        } else {
            prompts.append(prompt)
            prompts.sort(by: { $0.createdAt > $1.createdAt }) // Maintain sort order
            saveChanges()
            logger.info("Added new prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
        }
    }

    /// Updates an existing prompt in the store and saves changes.
    /// - Parameter prompt: The `Prompt` to update.
    func updatePrompt(_ prompt: Prompt) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }) else {
            logger.warning("Attempted to update a non-existent prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString)). Adding it instead.")
            addPrompt(prompt) // Or handle as an error
            return
        }
        prompts[index] = prompt
        // No need to re-sort if only content changes, but if title/category for sorting changes, consider it.
        // For simplicity, we can re-sort if needed, or assume `createdAt` doesn't change often on update.
        saveChanges()
        logger.info("Updated prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
    }

    /// Deletes a prompt from the store by its ID and saves changes.
    /// - Parameter id: The `UUID` of the prompt to delete.
    func deletePrompt(withId id: UUID) {
        if let index = prompts.firstIndex(where: { $0.id == id }) {
            let removedPromptTitle = prompts[index].title
            prompts.remove(at: index)
            saveChanges()
            logger.info("Deleted prompt: '\(removedPromptTitle)' (ID: \(id.uuidString))")
        } else {
            logger.warning("Attempted to delete a non-existent prompt with ID: \(id.uuidString)")
        }
    }

    /// Deletes multiple prompts from the store by their IDs and saves changes.
    /// - Parameter ids: A `Set` of `UUID`s of the prompts to delete.
    func deletePrompts(withIds ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let initialCount = prompts.count
        prompts.removeAll { ids.contains($0.id) }
        if prompts.count < initialCount {
            saveChanges()
            logger.info("Deleted \(initialCount - self.prompts.count) prompts.")
        } else {
            logger.info("No prompts found matching IDs for deletion: \(ids.map { $0.uuidString }.joined(separator: ", "))")
        }
    }

    /// Retrieves a prompt by its ID.
    /// - Parameter id: The `UUID` of the prompt to retrieve.
    /// - Returns: An optional `Prompt` if found, otherwise `nil`.
    func getPrompt(withId id: UUID) -> Prompt? {
        return prompts.first { $0.id == id }
    }
    
    /// Retrieves all prompts, optionally sorted.
    /// Consider adding sorting parameters if needed directly here,
    /// or let the ViewModel handle sorting of the published `prompts` array.
    func getAllPrompts() -> [Prompt] {
        return prompts // Already sorted by createdAt descending in current implementation
    }
}
