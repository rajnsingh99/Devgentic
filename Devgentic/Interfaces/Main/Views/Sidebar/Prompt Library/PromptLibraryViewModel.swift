//
//  PromptLibraryViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 10/05/25.
//

import SwiftUI
import os

@Observable @MainActor
class PromptLibraryViewModel {
    // MARK: - Dependencies
    private let promptService = PromptService.shared
    @ObservationIgnored private let logger = DGLogger(category: "PromptLibraryViewModel")

    // MARK: - State Properties for UI
    var searchText: String = "" {
        didSet { filterPrompts(searchText: searchText, category: selectedCategory) }
    }
    var filteredPrompts: [DevPrompt] = []
    var selectedPrompt: DevPrompt? = nil
    var showingCreateOrEditPromptSheet: Bool = false

    var selectedCategory: String = "All" {
        didSet { filterPrompts(searchText: searchText, category: selectedCategory) }
    }

    // Properties for the create/edit sheet
    var promptToEdit: DevPrompt?
    var editablePromptTitle: String = ""
    var editablePromptText: String = ""
    var editablePromptCategory: String = "General"
    var editablePromptTagsString: String = ""

    // MARK: - Initialization
    init() {
        logger.info("PromptLibraryViewModel initialized.")

        // Initial filter
        filterPrompts(searchText: searchText, category: selectedCategory)
    }

    // MARK: - Filtering Logic
    // FIX: The function now accepts parameters to avoid state synchronization issues.
    private func filterPrompts(searchText: String, category: String) {
        logger.trace("--- Starting filterPrompts ---")
        // Get the full, unfiltered list from the store.
        let allPrompts = promptService.getAllPrompts()
        logger.trace("Fetched \(allPrompts.count) total prompts from store.")

        // 1. Apply the category filter using the 'category' parameter.
        let categoryFiltered: [DevPrompt]
        if category == "All" {
            categoryFiltered = allPrompts
            logger.trace("Category is 'All', skipping category filter.")
        } else {
            // Filter based on the selected category, ignoring case for robustness.
            categoryFiltered = allPrompts.filter { $0.category.caseInsensitiveCompare(category) == .orderedSame }
            logger.trace("Filtered by category '\(category)'. Result count: \(categoryFiltered.count)")
        }

        // 2. Then, apply the search text filter on the result of the category filter.
        let searchFiltered: [DevPrompt]
        if searchText.isEmpty {
            searchFiltered = categoryFiltered
            logger.trace("Search text is empty, skipping search filter.")
        } else {
            let lowercasedSearchText = searchText.lowercased()
            searchFiltered = categoryFiltered.filter { prompt in
                prompt.title.lowercased().contains(lowercasedSearchText) ||
                prompt.text.lowercased().contains(lowercasedSearchText) ||
                (prompt.tags?.contains(where: { $0.lowercased().contains(lowercasedSearchText) }) ?? false)
            }
            logger.trace("Filtered by search text '\(searchText)'. Result count: \(searchFiltered.count)")
        }

        // 3. Finally, sort the result and assign it to the @Published property.
        self.filteredPrompts = searchFiltered.sorted { $0.title.lowercased() < $1.title.lowercased() }
        
        logger.debug("Filter process complete. Final filtered count: \(self.filteredPrompts.count)")
        logger.trace("--- Finished filterPrompts ---")
    }


    // MARK: - Prompt Selection
    func selectPrompt(_ prompt: DevPrompt?) {
        selectedPrompt = prompt
        if let prompt {
            logger.debug("Selected prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
        } else {
            logger.debug("Cleared prompt selection.")
        }
    }

    // MARK: - CRUD Operations & Sheet Management

    func prepareForCreateNewPrompt() {
        promptToEdit = nil
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General"
        editablePromptTagsString = ""
        showingCreateOrEditPromptSheet = true
        logger.info("Preparing to create a new prompt.")
    }

    func prepareToEditPrompt(_ prompt: DevPrompt) {
        promptToEdit = prompt
        editablePromptTitle = prompt.title
        editablePromptText = prompt.text
        editablePromptCategory = prompt.category
        editablePromptTagsString = prompt.tags?.joined(separator: ", ") ?? ""
        showingCreateOrEditPromptSheet = true
        logger.info("Preparing to edit prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
    }

    func savePromptFromSheet() {
        let tagsArray = editablePromptTagsString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if var editingPrompt = promptToEdit {
            // Log details before updating
            logger.info("Saving changes to existing prompt. ID: \(editingPrompt.id.uuidString)")
            editingPrompt.title = editablePromptTitle
            editingPrompt.text = editablePromptText
            editingPrompt.category = editablePromptCategory
            editingPrompt.tags = tagsArray.isEmpty ? nil : tagsArray
            
            promptService.updatePrompt(editingPrompt)
            logger.info("Successfully updated prompt: '\(editingPrompt.title)'")
            if selectedPrompt?.id == editingPrompt.id {
                selectPrompt(editingPrompt)
            }
        } else {
            // Log details before creating
            logger.info("Creating a new prompt with title: '\(self.editablePromptTitle)'")
            let newPrompt = DevPrompt(
                title: editablePromptTitle,
                text: editablePromptText,
                category: editablePromptCategory,
                isUserDefined: true,
                tags: tagsArray.isEmpty ? nil : tagsArray
            )
            promptService.addPrompt(newPrompt)
            logger.info("Successfully created new prompt. ID: \(newPrompt.id.uuidString)")
        }
        showingCreateOrEditPromptSheet = false
        // Reset fields after saving
        promptToEdit = nil
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General"
        editablePromptTagsString = ""
    }
    
    func deletePrompt(_ prompt: DevPrompt) {
        logger.info("Attempting to delete prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
        promptService.deletePrompt(withId: prompt.id)
        
        filterPrompts(searchText: self.searchText, category: self.selectedCategory)
        
        if selectedPrompt?.id == prompt.id {
            logger.debug("Deselecting deleted prompt.")
            selectedPrompt = nil
        }
    }

    // MARK: - Prompt Usage
    
    func updatePromptUsage(prompt: DevPrompt) {
        var mutablePrompt = prompt
        mutablePrompt.lastUsedAt = Date()
        promptService.updatePrompt(mutablePrompt)
        logger.info("Updated last used time for prompt: '\(prompt.title)' (ID: \(prompt.id.uuidString))")
    }
}
