//
//  PromptLibraryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import Combine
import os

@MainActor
class PromptLibraryViewModel: ObservableObject {
    // MARK: - Dependencies
    private let promptStore = PromptStore.shared
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "PromptLibraryViewModel")
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published State Properties for UI
    @Published var searchText: String = ""
    @Published var filteredPrompts: [Prompt] = []
    @Published var selectedPrompt: Prompt? = nil
    @Published var showingCreateOrEditPromptSheet: Bool = false
    
    // Properties for the create/edit sheet
    @Published var promptToEdit: Prompt? // If this is non-nil, we are editing
    @Published var editablePromptTitle: String = ""
    @Published var editablePromptText: String = ""
    @Published var editablePromptCategory: String = "General" // Default category
    @Published var editablePromptTagsString: String = "" // Comma-separated tags

    // MARK: - Initialization
    init() {
        logger.info("PromptLibraryViewModel initialized.")
        
        // Subscribe to changes in searchText
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main) // Add a small delay to avoid filtering on every keystroke
            .sink { [weak self] _ in
                self?.filterPrompts()
            }
            .store(in: &cancellables)

        // Subscribe to changes in prompts from the store
        promptStore.$prompts
            .sink { [weak self] _ in
                self?.filterPrompts() // Re-filter when the underlying store changes
            }
            .store(in: &cancellables)
        
        // Initial load/filter
        filterPrompts()
    }

    // MARK: - Filtering Logic
    private func filterPrompts() {
        let allPrompts = promptStore.getAllPrompts()
        
        if searchText.isEmpty {
            filteredPrompts = allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() } // Default sort by title
        } else {
            let lowercasedSearchText = searchText.lowercased()
            filteredPrompts = allPrompts.filter { prompt in
                prompt.title.lowercased().contains(lowercasedSearchText) ||
                prompt.text.lowercased().contains(lowercasedSearchText) ||
                prompt.category.lowercased().contains(lowercasedSearchText) ||
                (prompt.tags?.contains(where: { $0.lowercased().contains(lowercasedSearchText) }) ?? false)
            }.sorted { $0.title.lowercased() < $1.title.lowercased() }
        }
        logger.debug("Filtered prompts. Count: \(self.filteredPrompts.count) for search term: '\(self.searchText)'")
    }

    // MARK: - Prompt Selection
    func selectPrompt(_ prompt: Prompt?) {
        selectedPrompt = prompt
        if let prompt {
            logger.debug("Selected prompt: '\(prompt.title)'")
        } else {
            logger.debug("Cleared prompt selection.")
        }
    }

    // MARK: - CRUD Operations & Sheet Management

    /// Prepares the ViewModel for creating a new prompt and shows the sheet.
    func prepareForCreateNewPrompt() {
        promptToEdit = nil // Ensure we are in "create" mode
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General" // Reset to default
        editablePromptTagsString = ""
        showingCreateOrEditPromptSheet = true
        logger.info("Preparing to create a new prompt.")
    }

    /// Prepares the ViewModel for editing an existing prompt and shows the sheet.
    func prepareToEditPrompt(_ prompt: Prompt) {
        promptToEdit = prompt
        editablePromptTitle = prompt.title
        editablePromptText = prompt.text
        editablePromptCategory = prompt.category
        editablePromptTagsString = prompt.tags?.joined(separator: ", ") ?? ""
        showingCreateOrEditPromptSheet = true
        logger.info("Preparing to edit prompt: '\(prompt.title)'")
    }

    /// Saves the prompt being created or edited.
    func savePromptFromSheet() {
        let tagsArray = editablePromptTagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if var editingPrompt = promptToEdit { // Editing existing prompt
            editingPrompt.title = editablePromptTitle
            editingPrompt.text = editablePromptText
            editingPrompt.category = editablePromptCategory
            editingPrompt.tags = tagsArray.isEmpty ? nil : tagsArray
            
            promptStore.updatePrompt(editingPrompt)
            logger.info("Updated prompt: '\(editingPrompt.title)'")
            if selectedPrompt?.id == editingPrompt.id { // Reselect if it was the selected one
                selectPrompt(editingPrompt)
            }
        } else { // Creating new prompt
            let newPrompt = Prompt(
                title: editablePromptTitle,
                text: editablePromptText,
                category: editablePromptCategory,
                isUserDefined: true, // All prompts created via UI are user-defined
                tags: tagsArray.isEmpty ? nil : tagsArray
            )
            promptStore.addPrompt(newPrompt)
            logger.info("Created new prompt: '\(newPrompt.title)'")
        }
        showingCreateOrEditPromptSheet = false
        // Reset fields after saving
        promptToEdit = nil
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General"
        editablePromptTagsString = ""
    }
    
    /// Deletes the currently selected prompt.
    func deleteSelectedPrompt() {
        guard let promptToDelete = selectedPrompt else {
            logger.warning("Delete requested but no prompt is selected.")
            return
        }
        logger.info("Attempting to delete selected prompt: '\(promptToDelete.title)'")
        promptStore.deletePrompt(withId: promptToDelete.id)
        selectedPrompt = nil // Clear selection after deletion
    }
    
    /// Deletes a specific prompt.
    func deletePrompt(_ prompt: Prompt) {
        logger.info("Attempting to delete prompt: '\(prompt.title)' by direct call.")
        promptStore.deletePrompt(withId: prompt.id)
        if selectedPrompt?.id == prompt.id {
            selectedPrompt = nil
        }
    }

    // MARK: - Prompt Usage
    
    /// Updates the last used timestamp for a given prompt.
    /// This is important for the future "#" quick access feature.
    func updatePromptUsage(prompt: Prompt) {
        var mutablePrompt = prompt
        mutablePrompt.lastUsedAt = Date()
        promptStore.updatePrompt(mutablePrompt)
        logger.info("Updated last used time for prompt: '\(prompt.title)'")
    }
}
