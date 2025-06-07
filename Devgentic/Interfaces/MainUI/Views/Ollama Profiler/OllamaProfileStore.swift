//
//  OllamaProfileStore.swift
//  Devgentic
//
//  Created by Raj Singh on 01/06/25.
//

import Foundation
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "OllamaProfileStore")

/// Manages the collection of Ollama profiles, including persistence and selection.
class OllamaProfileStore: ObservableObject {
    // Published properties
    @Published var profiles: [OllamaProfileModel] {
        didSet {
            // Save profiles whenever the array changes
            saveProfiles()
            // Ensure selectedProfileID is still valid
            if let selectedID = selectedProfileID, !profiles.contains(where: { $0.id == selectedID }) {
                selectedProfileID = profiles.first?.id // Select first if old selection is gone
            } else if selectedProfileID == nil && !profiles.isEmpty {
                selectedProfileID = profiles.first?.id // Select first if nothing is selected
            } else if profiles.isEmpty {
                selectedProfileID = nil // Clear selection if no profiles exist
            }
        }
    }

    @Published var selectedProfileID: UUID? {
        didSet {
            // Log selection changes for debugging
            logger.info("Selected profile ID changed to: \(self.selectedProfileID?.uuidString ?? "nil")")
        }
    }

    // Private properties
    private let storageFileName = "ollama_profiles.json"
    private var profilesDirectory: URL? // URL to the directory where profiles are stored
    

    init() {
        // Initialize stored properties *before* calling instance methods that rely on 'self'.
        self.profiles = [] // Initialize profiles as an empty array first
        self.selectedProfileID = nil // Initialize selectedProfileID to nil

        // Initialize profilesDirectory
        if let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let devgenticDir = appSupportDirectory.appendingPathComponent("Devgentic", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: devgenticDir, withIntermediateDirectories: true, attributes: nil)
                self.profilesDirectory = devgenticDir
                logger.debug("Ollama profiles directory created or exists at: \(self.profilesDirectory!.path)")
            } catch {
                logger.error("Failed to create Ollama profiles directory: \(error.localizedDescription)")
                self.profilesDirectory = nil // Invalidate if creation fails
            }
        } else {
            logger.error("Could not find Application Support directory.")
            self.profilesDirectory = nil // Ensure it's nil if directory not found
        }

        // Now that all stored properties are initialized, load profiles from disk.
        let loadedProfiles = loadProfilesFromDisk()
        if !loadedProfiles.isEmpty {
            self.profiles = loadedProfiles
        }

        // If no profiles exist after loading (or if loading failed and profiles is still empty), create a default one.
        if self.profiles.isEmpty {
            let defaultProfile = OllamaProfileModel.defaultProfile()
            self.profiles.append(defaultProfile) // This will trigger didSet for profiles
            self.selectedProfileID = defaultProfile.id // Set selectedProfileID after profiles is populated
            logger.info("No profiles found or loaded, created and selected a default profile.")
        } else if self.selectedProfileID == nil {
            // If profiles were loaded but none is selected (e.g., from a previous state where selectedProfileID was nil),
            // select the first one.
            self.selectedProfileID = self.profiles.first?.id
            logger.info("Profiles loaded, selected the first available profile.")
        }
        // If profiles were loaded and selectedProfileID was already valid (e.g. from a previous app session where it was saved),
        // it will be preserved by the didSet of 'profiles' or remain as initially set if it's still valid.
    }

    /// Returns the currently selected Ollama profile.
    var currentProfile: OllamaProfileModel? {
        guard let selectedID = selectedProfileID else { return nil }
        return profiles.first(where: { $0.id == selectedID })
    }

    /// Adds a new Ollama profile to the store.
    func addProfile(profile: OllamaProfileModel) {
        // Prevent adding duplicates by ID, though UUID should make this rare
        if !profiles.contains(where: { $0.id == profile.id }) {
            profiles.append(profile)
            logger.info("Added new Ollama profile: '\(profile.profileName)' (ID: \(profile.id.uuidString))")
        } else {
            logger.warning("Attempted to add duplicate Ollama profile: '\(profile.profileName)' (ID: \(profile.id.uuidString))")
        }
    }

    /// Updates an existing Ollama profile in the store.
    func updateProfile(profile: OllamaProfileModel) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            logger.info("Updated Ollama profile: '\(profile.profileName)' (ID: \(profile.id.uuidString))")
        } else {
            logger.warning("Attempted to update non-existent Ollama profile: '\(profile.profileName)' (ID: \(profile.id.uuidString))")
        }
    }

    /// Deletes an Ollama profile from the store by its ID.
    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        logger.info("Deleted Ollama profile with ID: \(id.uuidString)")
    }

    /// Loads Ollama profiles from a JSON file on disk.
    private func loadProfilesFromDisk() -> [OllamaProfileModel] {
        guard let directory = profilesDirectory else {
            logger.error("Profiles directory not available, cannot load profiles.")
            return []
        }
        let fileURL = directory.appendingPathComponent(storageFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.info("Ollama profiles file not found at: \(fileURL.path). Returning empty array.")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let loadedProfiles = try decoder.decode([OllamaProfileModel].self, from: data)
            logger.info("Successfully loaded \(loadedProfiles.count) Ollama profiles from disk.")
            return loadedProfiles
        } catch {
            logger.error("Failed to load Ollama profiles from disk: \(error.localizedDescription)")
            // Attempt to delete corrupted file to prevent repeated load failures
            do {
                try FileManager.default.removeItem(at: fileURL)
                logger.warning("Corrupted profiles file deleted at: \(fileURL.path)")
            } catch let removalError {
                logger.error("Failed to delete corrupted profiles file: \(removalError.localizedDescription)")
            }
            return []
        }
    }

    /// Saves the current Ollama profiles to a JSON file on disk.
    private func saveProfiles() {
        // Ensure profilesDirectory is available
        guard let directory = profilesDirectory else {
            logger.error("Profiles directory not available, cannot save profiles.")
            return
        }
        let fileURL = directory.appendingPathComponent(storageFileName)

        // Do not save if profiles is empty unless it's an intentional clear.
        // However, the current logic adds a default profile if empty, so this check might be redundant
        // depending on desired behavior for an "empty" state before default creation.
        // For now, always attempt to save as `profiles` property's didSet triggers this.

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // For human-readable JSON
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: [.atomicWrite])
            logger.info("Successfully saved \(self.profiles.count) Ollama profiles to disk at: \(fileURL.path)")
        } catch {
            logger.error("Failed to save Ollama profiles to disk: \(error.localizedDescription)")
        }
    }
}
