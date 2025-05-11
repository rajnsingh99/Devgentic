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
    @Published var promptToEdit: Prompt?
    @Published var editablePromptTitle: String = ""
    @Published var editablePromptText: String = ""
    @Published var editablePromptCategory: String = "General"
    @Published var editablePromptTagsString: String = ""

    // MARK: - Initialization
    init() {
        logger.info("PromptLibraryViewModel initialized.")
        
        // Subscribe to changes in searchText
        $searchText
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.filterPrompts()
            }
            .store(in: &cancellables)

        // Subscribe to changes in prompts from the store
        promptStore.$prompts
            .sink { [weak self] _ in
                self?.filterPrompts()
            }
            .store(in: &cancellables)
        
        // Initial load/filter
        filterPrompts()

        // MARK: - Observe for external edit requests
        // Ensure this uses the AppNotifications struct
        logger.debug("Attempting to register observer for notification name: \(AppNotifications.editPromptRequestedFromBriefView.rawValue)")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExternalEditRequest(_:)),
            name: AppNotifications.editPromptRequestedFromBriefView, // Use the AppNotifications struct
            object: nil
        )
        logger.debug("Registered observer for editPromptRequestedFromBriefView notification.")
    }

    deinit {
        logger.info("PromptLibraryViewModel deinitialized.")
        // Ensure this uses the AppNotifications struct
        NotificationCenter.default.removeObserver(self, name: AppNotifications.editPromptRequestedFromBriefView, object: nil)
    }

    // MARK: - Notification Handler
    /// Handles requests to edit a prompt that originate from outside this view model (e.g., brief view popover).
    @objc private func handleExternalEditRequest(_ notification: Notification) {
        guard let promptToEditExternally = notification.object as? Prompt else {
            logger.warning("Received editPromptRequestedFromBriefView notification without a valid Prompt object.")
            return
        }
        
        logger.info("Handling external request to edit prompt: '\(promptToEditExternally.title)' (ID: \(promptToEditExternally.id.uuidString))")
        
        if let freshPromptFromStore = promptStore.getPrompt(withId: promptToEditExternally.id) {
            self.prepareToEditPrompt(freshPromptFromStore)
        } else {
            logger.warning("Prompt \(promptToEditExternally.id.uuidString) for external edit not found in store. Using the passed object directly.")
            self.prepareToEditPrompt(promptToEditExternally)
        }
    }

    // MARK: - Filtering Logic
    private func filterPrompts() {
        let allPrompts = promptStore.getAllPrompts()
        
        if searchText.isEmpty {
            filteredPrompts = allPrompts.sorted { $0.title.lowercased() < $1.title.lowercased() }
        } else {
            let lowercasedSearchText = searchText.lowercased()
            filteredPrompts = allPrompts.filter { prompt in
                prompt.title.lowercased().contains(lowercasedSearchText) ||
                prompt.text.lowercased().contains(lowercasedSearchText) ||
                prompt.category.lowercased().contains(lowercasedSearchText) ||
                (prompt.tags?.contains(where: { $0.lowercased().contains(lowercasedSearchText) }) ?? false)
            }.sorted { $0.title.lowercased() < $1.title.lowercased() }
        }
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

    func prepareForCreateNewPrompt() {
        promptToEdit = nil
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General"
        editablePromptTagsString = ""
        showingCreateOrEditPromptSheet = true
        logger.info("Preparing to create a new prompt.")
    }

    func prepareToEditPrompt(_ prompt: Prompt) {
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
            editingPrompt.title = editablePromptTitle
            editingPrompt.text = editablePromptText
            editingPrompt.category = editablePromptCategory
            editingPrompt.tags = tagsArray.isEmpty ? nil : tagsArray
            
            promptStore.updatePrompt(editingPrompt)
            logger.info("Updated prompt: '\(editingPrompt.title)'")
            if selectedPrompt?.id == editingPrompt.id {
                selectPrompt(editingPrompt)
            }
        } else {
            let newPrompt = Prompt(
                title: editablePromptTitle,
                text: editablePromptText,
                category: editablePromptCategory,
                isUserDefined: true,
                tags: tagsArray.isEmpty ? nil : tagsArray
            )
            promptStore.addPrompt(newPrompt)
            logger.info("Created new prompt: '\(newPrompt.title)'")
        }
        showingCreateOrEditPromptSheet = false
        promptToEdit = nil
        editablePromptTitle = ""
        editablePromptText = ""
        editablePromptCategory = "General"
        editablePromptTagsString = ""
    }
    
    func deleteSelectedPrompt() {
        guard let promptToDelete = selectedPrompt else {
            logger.warning("Delete requested but no prompt is selected.")
            return
        }
        logger.info("Attempting to delete selected prompt: '\(promptToDelete.title)'")
        promptStore.deletePrompt(withId: promptToDelete.id)
        selectedPrompt = nil
    }
    
    func deletePrompt(_ prompt: Prompt) {
        logger.info("Attempting to delete prompt: '\(prompt.title)' by direct call.")
        promptStore.deletePrompt(withId: prompt.id)
        if selectedPrompt?.id == prompt.id {
            selectedPrompt = nil
        }
    }

    // MARK: - Prompt Usage
    
    func updatePromptUsage(prompt: Prompt) {
        var mutablePrompt = prompt
        mutablePrompt.lastUsedAt = Date()
        promptStore.updatePrompt(mutablePrompt)
        logger.info("Updated last used time for prompt: '\(prompt.title)'")
    }
}
