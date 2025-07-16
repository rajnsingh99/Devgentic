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
            UserDefaults.standard.set(selectedIntegrationID?.uuidString, forKey: "selectedLLMIntegrationID")
            logger.info("Selected LLM Integration ID changed to: \(self.selectedIntegrationID?.uuidString ?? "nil")")
            
            if let id = selectedIntegrationID, let index = integrations.firstIndex(where: { $0.id == id }) {
                integrations[index].lastSelected = Date()
                if let entity = persistenceService.getLLMIntegration(withId: id) {
                    // The underlying service now handles the complex update logic
                    persistenceService.updateLLMIntegration(entity: entity, with: integrations[index])
                }
            }
        }
    }

    private let persistenceService: CoreDataServiceProtocol

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        loadIntegrations()
        
        if let savedIDString = UserDefaults.standard.string(forKey: "selectedLLMIntegrationID"),
           let savedID = UUID(uuidString: savedIDString),
           integrations.contains(where: { $0.id == savedID }) {
            self.selectedIntegrationID = savedID
        } else {
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
            // The toLLMIntegrationModel() method on the entity now handles the nested structure
            self.integrations = entities.map { $0.toLLMIntegrationModel() }
            logger.info("Successfully loaded \(self.integrations.count) LLM integrations from Core Data.")
            
            if self.integrations.isEmpty {
                logger.info("No LLM integrations found. Creating a default Ollama profile.")
                self.addIntegration(model: .defaultOllama())
            }
        }
    }

    /// Adds a new LLM integration to Core Data and updates the local store.
    func addIntegration(model: LLMIntegrationModel) {
        persistenceService.addLLMIntegration(from: model)
        loadIntegrations() // Reload to get the new object from the source of truth
    }

    /// Updates an existing LLM integration in Core Data and the local store.
    func updateIntegration(model: LLMIntegrationModel) {
        if let entity = persistenceService.getLLMIntegration(withId: model.id) {
            persistenceService.updateLLMIntegration(entity: entity, with: model)
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

            if self.selectedIntegrationID == id {
                self.selectedIntegrationID = self.integrations.sorted(by: { $0.lastSelected ?? .distantPast > $1.lastSelected ?? .distantPast }).first?.id
            }
            
            logger.info("Deleted LLM integration with ID: \(id.uuidString)")
        }
    }
}
