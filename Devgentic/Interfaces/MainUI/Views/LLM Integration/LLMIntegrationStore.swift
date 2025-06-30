//
//  LLMIntegrationStore.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import Foundation
import Combine
import CoreData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMIntegrationStore")

/// Manages the collection of all LLM provider integrations, handling persistence and selection.
class LLMIntegrationStore: ObservableObject {
    
    @Published var integrations: [LLMIntegrationModel] = []
    @Published var selectedIntegrationID: UUID? {
        didSet {
            // Persist the last selected ID to UserDefaults for session continuity
            UserDefaults.standard.set(selectedIntegrationID?.uuidString, forKey: "selectedLLMIntegrationID")
            logger.info("Selected LLM Integration ID changed to: \(self.selectedIntegrationID?.uuidString ?? "nil")")
            
            // Update the lastSelected date for the newly selected integration
            if let id = selectedIntegrationID, let index = integrations.firstIndex(where: { $0.id == id }) {
                integrations[index].lastSelected = Date()
                if let entity = persistenceService.getLLMIntegration(withId: id) {
                    persistenceService.updateLLMIntegration(entity: entity, with: integrations[index])
                }
            }
        }
    }

    private let persistenceService: CoreDataServiceProtocol
    private let viewContext: NSManagedObjectContext

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        self.viewContext = (persistenceService as! CoreDataPersistenceService).viewContext
        
        loadIntegrations()
        
        // Restore the last selected integration ID
        if let savedIDString = UserDefaults.standard.string(forKey: "selectedLLMIntegrationID"),
           let savedID = UUID(uuidString: savedIDString),
           integrations.contains(where: { $0.id == savedID }) {
            self.selectedIntegrationID = savedID
        } else {
            // If no ID is saved or valid, select the most recently used one, or the first.
            self.selectedIntegrationID = integrations.sorted(by: { $0.lastSelected ?? .distantPast > $1.lastSelected ?? .distantPast }).first?.id
        }
    }

    /// Returns the currently selected LLM Integration.
    var currentIntegration: LLMIntegrationModel? {
        guard let selectedID = selectedIntegrationID else { return nil }
        return integrations.first { $0.id == selectedID }
    }

    /// Fetches all integrations from Core Data and updates the published `integrations` array.
    func loadIntegrations() {
        let entities = persistenceService.fetchLLMIntegrations()
        DispatchQueue.main.async {
            self.integrations = entities.map { $0.toLLMIntegrationModel() }
            logger.info("Successfully loaded \(self.integrations.count) LLM integrations from Core Data.")
            
            // If no integrations exist, create a default one.
            if self.integrations.isEmpty {
                logger.info("No LLM integrations found. Creating a default Ollama profile.")
                self.addIntegration(model: .defaultOllama())
            }
        }
    }

    /// Adds a new LLM integration to Core Data and updates the local store.
    func addIntegration(model: LLMIntegrationModel) {
        persistenceService.addLLMIntegration(from: model)
        // Reload all to ensure the new item is included and sorted.
        loadIntegrations()
    }

    /// Updates an existing LLM integration in Core Data and the local store.
    func updateIntegration(model: LLMIntegrationModel) {
        if let entity = persistenceService.getLLMIntegration(withId: model.id) {
            persistenceService.updateLLMIntegration(entity: entity, with: model)
            // Find and update the model in the local array to reflect changes instantly.
            if let index = integrations.firstIndex(where: { $0.id == model.id }) {
                DispatchQueue.main.async {
                    self.integrations[index] = model
                }
            }
        } else {
            logger.warning("Attempted to update non-existent LLM integration: '\(model.displayName)' (ID: \(model.id.uuidString))")
        }
    }

    /// Deletes an LLM integration from Core Data and updates the local store.
    func deleteIntegration(id: UUID) {
        persistenceService.deleteLLMIntegration(with: id)

        DispatchQueue.main.async {
            self.integrations.removeAll { $0.id == id }

            // If the deleted integration was the selected one, select a new one.
            if self.selectedIntegrationID == id {
                self.selectedIntegrationID = self.integrations.sorted(by: { $0.lastSelected ?? .distantPast > $1.lastSelected ?? .distantPast }).first?.id
            }
            
            logger.info("Deleted LLM integration with ID: \(id.uuidString)")
        }
    }
}
