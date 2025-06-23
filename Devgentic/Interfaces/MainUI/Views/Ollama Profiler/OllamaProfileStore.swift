//
//  OllamaProfileStore.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import Foundation
import Combine
import CoreData // Import Core Data
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaProfileStore")

/// Manages the collection of Ollama profiles, including persistence and selection, using Core Data.
class OllamaProfileStore: ObservableObject {
    // Published properties
    @Published var profiles: [OllamaProfileModel] = []
    @Published var selectedProfileID: UUID? {
        didSet {
            // Persist the last selected profile ID to UserDefaults for session continuity
            UserDefaults.standard.set(selectedProfileID?.uuidString, forKey: "selectedProfileID")
            logger.info("Selected profile ID changed to: \(self.selectedProfileID?.uuidString ?? "nil")")
        }
    }

    // Private properties
    private let persistenceService: CoreDataServiceProtocol
    private let viewContext: NSManagedObjectContext

    // Use a specific queue for profile updates to avoid race conditions.
    private let updateQueue = DispatchQueue(label: "com.devgentic.ollamaProfileStore.updateQueue")

    init(persistenceService: CoreDataServiceProtocol = CoreDataPersistenceService.shared) {
        self.persistenceService = persistenceService
        self.viewContext = (persistenceService as! CoreDataPersistenceService).viewContext
        
        // Load profiles from Core Data on initialization
        loadProfiles()
        
        // Restore the last selected profile ID from UserDefaults
        if let savedIDString = UserDefaults.standard.string(forKey: "selectedProfileID"),
           let savedID = UUID(uuidString: savedIDString),
           profiles.contains(where: { $0.id == savedID }) {
            self.selectedProfileID = savedID
        } else {
            // If the saved ID is invalid or not found, select the first available profile or none
            self.selectedProfileID = profiles.first?.id
        }
    }

    /// Returns the currently selected Ollama profile.
    var currentProfile: OllamaProfileModel? {
        guard let selectedID = selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == selectedID })
    }

    /// Fetches all profiles from Core Data and updates the published `profiles` array.
    private func loadProfiles() {
        let request: NSFetchRequest<OllamaProfileEntity> = OllamaProfileEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \OllamaProfileEntity.profileName, ascending: true)]
        
        do {
            let results = try viewContext.fetch(request)
            // Map entities to models on the main thread
            DispatchQueue.main.async {
                self.profiles = results.map { $0.toOllamaProfileModel() }
                logger.info("Successfully loaded \(self.profiles.count) Ollama profiles from Core Data.")
            }
        } catch {
            logger.error("Failed to fetch Ollama profiles from Core Data: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.profiles = []
            }
        }
    }

    /// Adds a new Ollama profile to Core Data and updates the local store.
    func addProfile(profile: OllamaProfileModel) {
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Perform Core Data operation
            self.persistenceService.addOllamaProfile(from: profile)
            
            // Reload profiles on the main thread to reflect the change
            self.loadProfiles()
        }
    }

    /// Updates an existing Ollama profile in Core Data and the local store.
    func updateProfile(profile: OllamaProfileModel) {
        updateQueue.async { [weak self] in
            guard let self = self else { return }

            // Fetch the specific entity to update
            if let entity = self.persistenceService.getOllamaProfile(withId: profile.id) {
                // Perform Core Data update
                self.persistenceService.updateOllamaProfile(entity: entity, with: profile)
                
                // Reload profiles on the main thread
                self.loadProfiles()
            } else {
                logger.warning("Attempted to update non-existent Ollama profile: '\(profile.profileName)' (ID: \(profile.id.uuidString))")
            }
        }
    }

    /// Deletes an Ollama profile from Core Data and updates the local store.
    func deleteProfile(id: UUID) {
        updateQueue.async { [weak self] in
            guard let self = self else { return }

            // Perform Core Data deletion
            self.persistenceService.deleteOllamaProfile(with: id)

            DispatchQueue.main.async {
                // Remove from the local array
                self.profiles.removeAll { $0.id == id }

                // If the deleted profile was the selected one, clear the selection.
                // The UI layer will be responsible for selecting a new one if needed.
                if self.selectedProfileID == id {
                    self.selectedProfileID = self.profiles.first?.id
                }
                
                logger.info("Deleted Ollama profile with ID: \(id.uuidString)")
            }
        }
    }
}
