//
//  PromptService.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

// Stores/PromptService.swift
import Foundation
import Combine
import os

/// Manages the collection of prompts, handling persistence and providing access.
@MainActor // Ensures changes to @Published properties are on the main thread
class PromptService: ObservableObject {
    static let shared = PromptService()

    // Use the new PromptStoreProtocol
    private let promptStore: PromptStoreProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptService")

    /// The collection of all prompts, published for UI updates.
    @Published var prompts: [DevPrompt] = []

    // Update the initializer to accept a PromptStoreProtocol
    private init(promptStore: PromptStoreProtocol = PromptStore.shared) {
        self.promptStore = promptStore
        
        // Load all prompts from the new prompt store.
        loadPrompts()
        
        // If the library is still empty after loading (e.g., first launch), add default prompts.
        if prompts.isEmpty {
            logger.info("Prompt library is empty. Adding default example prompts.")
            addDefaultPrompts()
        }
        
        logger.info("PromptService initialized. Loaded \(self.prompts.count) prompts.")
    }

    /// Loads prompts from the prompt store.
    private func loadPrompts() {
        self.prompts = promptStore.fetchPrompts().sorted(by: { $0.createdAt > $1.createdAt })
    }
    
    /// Adds the default set of prompts to the store.
    private func addDefaultPrompts() {
        for prompt in DevPrompt.examplePrompts {
            promptStore.addPrompt(from: prompt)
        }
        // Reload from persistence to ensure the UI has the latest data.
        loadPrompts()
    }

    // MARK: - CRUD Operations (Now interacting with PromptStore)

    /// Adds a new prompt to the store and saves changes via the prompt store.
    /// - Parameter prompt: The `Prompt` to add.
    func addPrompt(_ prompt: DevPrompt) {
        promptStore.addPrompt(from: prompt)
        loadPrompts() // Reload to update the @Published array
        logger.info("Added new prompt: '\(prompt.title)'")
    }

    /// Updates an existing prompt in the store and saves changes via the prompt store.
    /// - Parameter prompt: The `Prompt` to update.
    func updatePrompt(_ prompt: DevPrompt) {
        promptStore.updatePrompt(from: prompt)
        loadPrompts() // Reload to update the @Published array
        logger.info("Updated prompt: '\(prompt.title)'")
    }

    /// Deletes a prompt from the store by its ID and saves changes via the prompt store.
    /// - Parameter id: The `UUID` of the prompt to delete.
    func deletePrompt(withId id: UUID) {
        promptStore.deletePrompt(withId: id)
        loadPrompts() // Reload to update the @Published array
        logger.info("Deleted prompt with ID: \(id.uuidString)")
    }

    /// Deletes multiple prompts from the store by their IDs.
    /// - Parameter ids: A `Set` of `UUID`s of the prompts to delete.
    func deletePrompts(withIds ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            promptStore.deletePrompt(withId: id)
        }
        loadPrompts() // Reload to update the @Published array
        logger.info("Deleted \(ids.count) prompts.")
    }

    /// Retrieves a prompt by its ID from the local array.
    /// - Parameter id: The `UUID` of the prompt to retrieve.
    /// - Returns: An optional `Prompt` if found, otherwise `nil`.
    func getPrompt(withId id: UUID) -> DevPrompt? {
        return prompts.first { $0.id == id }
    }
    
    func getAllPrompts() -> [DevPrompt] {
        return prompts
    }
}
