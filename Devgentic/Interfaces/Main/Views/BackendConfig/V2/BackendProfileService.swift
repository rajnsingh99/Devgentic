//
//  BackendProfileService.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//

import Foundation
import Combine

/// An ObservableObject that acts as the central service for the Backend Profile UI.
/// It manages the state of profiles, handles persistence, and provides logic for advanced configurations.
final class BackendProfileService: ObservableObject {
    
    /// The published array of profiles that the UI will observe for changes.
    /// This now uses the concrete `BackendProfileModel` directly.
    @Published var profiles: [BackendProfileModel] = []
    
    private let profileStore: BackendProfileStoreProtocol
    
    /// Initializes the service, optionally with a specific store for testing.
    /// On initialization, it immediately loads the profiles from persistence.
    init(store: BackendProfileStoreProtocol = BackendProfileStore.shared) {
        self.profileStore = store
        loadProfiles()
    }
    
    // MARK: - Persistence Methods
    
    /// Fetches all profiles from the persistence layer and updates the published `profiles` array.
    func loadProfiles() {
        // The store now returns the correct model type, so no mapping is needed.
        self.profiles = profileStore.fetchProfiles()
    }
    
    /// Saves a given profile to the persistence layer and reloads the local array.
    func saveProfile(_ profile: BackendProfileModel) {
        profileStore.saveProfile(profile)
        loadProfiles()
    }
    
    /// Deletes a profile using its ID from the persistence layer and reloads the local array.
    func deleteProfile(withId id: UUID) {
        profileStore.deleteProfile(withId: id)
        loadProfiles()
    }
    
    // MARK: - Advanced Configuration Logic
    
    /// The main public method to get a strongly-typed advanced configuration model for a profile.
    /// It decodes the stored dictionary or returns a default configuration if none exists.
    func getAdvancedConfig(for profile: BackendProfileModel) -> any Codable {
        // 1. Extract the ProviderConfig based on the profile's details.
        let providerConfig: ProviderConfig?
        switch profile.details {
        case .bot(let llmConfig):
            providerConfig = llmConfig
        case .agent(let llmConfig, _):
            providerConfig = llmConfig
        case .workflow:
            // Workflows do not have a single provider config.
            providerConfig = nil
        }
        
        // 2. If no config exists (e.g., for a workflow), return a default.
        guard let config = providerConfig else {
            return OllamaAdvancedConfig.default()
        }
        
        // 3. Determine the provider and decode the specific advanced model.
        switch config.apiProvider {
        case .google:
            return decodeConfig(from: config.advancedConfiguration, as: GeminiAdvancedConfig.self)
                ?? GeminiAdvancedConfig.default()
        
        case .ollama:
            return decodeConfig(from: config.advancedConfiguration, as: OllamaAdvancedConfig.self)
                ?? OllamaAdvancedConfig.default()
            
        default:
            // For providers without a defined advanced config model yet, return a default.
            return OllamaAdvancedConfig.default()
        }
    }
    
    /// Encodes a `Codable` configuration model into the `[String: AnyCodable]` dictionary format.
    /// - Returns: The encoded dictionary, or `nil` if encoding fails.
    func encodeConfig(from config: any Codable) -> [String: AnyCodable]? {
        do {
            let data = try JSONEncoder().encode(AnyCodable(config))
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                return nil
            }
            return dictionary.mapValues { AnyCodable($0) }
        } catch {
            print("Failed to encode advanced configuration: \(error)")
            return nil
        }
    }
    
    /// Decodes a `[String: AnyCodable]` dictionary back into a specific `Codable` model type.
    /// - Returns: The decoded model, or `nil` if the dictionary is missing or decoding fails.
    private func decodeConfig<T: Codable>(from dictionary: [String: AnyCodable]?, as type: T.Type) -> T? {
        guard let dictionary = dictionary else { return nil }
        
        let unwrappedDict = dictionary.mapValues { $0.value }
        
        do {
            let data = try JSONSerialization.data(withJSONObject: unwrappedDict)
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            return decodedObject
        } catch {
            print("Failed to decode advanced configuration: \(error)")
            return nil
        }
    }
}
