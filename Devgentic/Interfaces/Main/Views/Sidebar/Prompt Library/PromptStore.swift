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

    // Use the Core Data service as the primary persistence layer.
    private let persistenceService: CoreDataServiceProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptStore")

    /// The collection of all prompts, published for UI updates.
    @Published var prompts: [Prompt] = []

    private init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        
        // Load all prompts from the Core Data store.
        loadPrompts()
        
        // If the library is still empty after loading (e.g., first launch), add default prompts.
        if prompts.isEmpty {
            logger.info("Prompt library is empty. Adding default example prompts to Core Data.")
            addDefaultPrompts()
        }
        
        logger.info("PromptStore initialized. Loaded \(self.prompts.count) prompts from Core Data.")
    }

    /// Loads prompts from the Core Data persistence service.
    private func loadPrompts() {
        self.prompts = persistenceService.fetchPrompts().sorted(by: { $0.createdAt > $1.createdAt })
    }
    
    /// Adds the default set of prompts to the store.
    private func addDefaultPrompts() {
        for prompt in Prompt.examplePrompts {
            persistenceService.addPrompt(from: prompt)
        }
        // Reload from persistence to ensure the UI has the latest data.
        loadPrompts()
    }

    // MARK: - CRUD Operations (Now interacting with Core Data)

    /// Adds a new prompt to the store and saves changes via the persistence service.
    /// - Parameter prompt: The `Prompt` to add.
    func addPrompt(_ prompt: Prompt) {
        persistenceService.addPrompt(from: prompt)
        loadPrompts() // Reload to update the @Published array
        logger.info("Added new prompt via Core Data: '\(prompt.title)'")
    }

    /// Updates an existing prompt in the store and saves changes via the persistence service.
    /// - Parameter prompt: The `Prompt` to update.
    func updatePrompt(_ prompt: Prompt) {
        persistenceService.updatePrompt(from: prompt)
        loadPrompts() // Reload to update the @Published array
        logger.info("Updated prompt via Core Data: '\(prompt.title)'")
    }

    /// Deletes a prompt from the store by its ID and saves changes via the persistence service.
    /// - Parameter id: The `UUID` of the prompt to delete.
    func deletePrompt(withId id: UUID) {
        persistenceService.deletePrompt(withId: id)
        loadPrompts() // Reload to update the @Published array
        logger.info("Deleted prompt via Core Data with ID: \(id.uuidString)")
    }

    /// Deletes multiple prompts from the store by their IDs.
    /// - Parameter ids: A `Set` of `UUID`s of the prompts to delete.
    func deletePrompts(withIds ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            persistenceService.deletePrompt(withId: id)
        }
        loadPrompts() // Reload to update the @Published array
        logger.info("Deleted \(ids.count) prompts via Core Data.")
    }

    /// Retrieves a prompt by its ID from the local array.
    /// - Parameter id: The `UUID` of the prompt to retrieve.
    /// - Returns: An optional `Prompt` if found, otherwise `nil`.
    func getPrompt(withId id: UUID) -> Prompt? {
        return prompts.first { $0.id == id }
    }
    
    func getAllPrompts() -> [Prompt] {
        return prompts
    }
}
