//
//  BackendProfileService.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Refactored on 26/08/25 to support unified BackendProfileModel.
//  Updated on 27/08/25 to fix advanced configuration encoding.
//

import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendProfileService")

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
        case .bot(let llmConfig, _):
            providerConfig = llmConfig
        case .agent(let llmConfig, _, _, _, _, _):
            providerConfig = llmConfig
        case .workflow:
            // Workflows do not have a single provider config.
            providerConfig = nil
        }
        
        // 2. If no config exists (e.g., for a workflow), return a default.
        guard let config = providerConfig else {
            // Return a sensible default if there's no provider config.
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
    
    /// **FIXED**: Encodes a specific `Codable` model into the `[String: AnyCodable]` dictionary format.
    /// This version uses a generic constraint to correctly handle any Codable struct.
    /// - Returns: The encoded dictionary, or `nil` if encoding fails.
    func encodeConfig<T: Codable>(from config: T) -> [String: AnyCodable]? {
        do {
            // 1. Encode the concrete struct (e.g., OllamaAdvancedConfig) to Data.
            let data = try JSONEncoder().encode(config)
            // 2. Deserialize that Data into a standard [String: Any] dictionary.
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                print("Failed to cast JSON object to [String: Any]")
                return nil
            }
            // 3. Wrap each value in the dictionary with AnyCodable for storage.
            return dictionary.mapValues { AnyCodable($0) }
        } catch {
            print("Failed to encode advanced configuration: \(error)")
            return nil
        }
    }
    
    /// Decodes a `[String: AnyCodable]` dictionary back into a specific `Codable` model type.
    /// - Returns: The decoded model, or `nil` if the dictionary is missing or decoding fails.
    func decodeConfig<T: Codable>(from dictionary: [String: AnyCodable]?, as type: T.Type) -> T? {
        guard let dictionary = dictionary else { return nil }
        
        // 1. Unwrap the `AnyCodable` values to get a standard [String: Any] dictionary.
        let unwrappedDict = dictionary.mapValues { $0.value }
        
        do {
            // 2. Serialize the standard dictionary to JSON Data.
            let data = try JSONSerialization.data(withJSONObject: unwrappedDict)
            // 3. Decode the Data into the target struct type (e.g., OllamaAdvancedConfig).
            let decodedObject = try JSONDecoder().decode(T.self, from: data)
            return decodedObject
        } catch {
            print("Failed to decode advanced configuration: \(error)")
            return nil
        }
    }
    
    // MARK: - Diagnostics / Logging
    
    /// Logs the full, detailed configuration of the selected profile to the console.
    func logProfileSelection(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        
        var logOutput = "\n\n==================================================\n"
        logOutput += "🔍 PROFILE SELECTED: \(profile.displayName)\n"
        logOutput += "==================================================\n"
        logOutput += "ID: \(profile.id)\n"
        logOutput += "Type: \(profile.profileType.rawValue)\n"
        logOutput += "Last Selected: \(profile.lastSelected?.description ?? "Never")\n\n"
        
        switch profile.details {
        case .bot(let llmConfig, let instructions):
            logOutput += "🤖 [BOT CONFIGURATION]\n"
            logOutput += formatLLMConfig(llmConfig)
            logOutput += "Instructions (Length): \(instructions?.count ?? 0) characters\n"
            
        case .agent(let llmConfig, let architecture, let tools, let description, let instructions, let knowledgeSources):
            logOutput += "🕵️ [AGENT CONFIGURATION]\n"
            logOutput += "Architecture: \(architecture.rawValue)\n"
            logOutput += "Description: \(description ?? "None")\n"
            logOutput += "Instructions (Length): \(instructions?.count ?? 0) characters\n\n"
            
            logOutput += "🛠 [TOOLS (\(tools.filter({ $0.isEnabled }).count) Active)]\n"
            if tools.isEmpty {
                logOutput += "  - No tools configured.\n"
            } else {
                for tool in tools {
                    let status = tool.isEnabled ? "✅" : "❌"
                    logOutput += "  \(status) \(tool.name) (Requires Confirmation: \(tool.requiresConfirmation))\n"
                }
            }
            logOutput += "\n"
            
            logOutput += "📚 [KNOWLEDGE SOURCES (\(knowledgeSources?.count ?? 0) Active)]\n"
            if let sources = knowledgeSources, !sources.isEmpty {
                for source in sources {
                    logOutput += "  - [\(source.type.rawValue)] \(source.location)\n"
                }
            } else {
                logOutput += "  - No knowledge sources.\n"
            }
            logOutput += "\n"
            
            logOutput += "🧠 [LLM / PROVIDER CONFIGURATION]\n"
            logOutput += formatLLMConfig(llmConfig)
            
        case .workflow(let agents):
            logOutput += "🔄 [WORKFLOW CONFIGURATION]\n"
            logOutput += "Agents Included: \(agents.count)\n"
            for (index, agent) in agents.enumerated() {
                logOutput += "  \(index + 1). \(agent.displayName) (\(agent.id))\n"
            }
        }
        
        logOutput += "==================================================\n\n"
        
        logger.info("\(logOutput)")
    }
    
    private func formatLLMConfig(_ config: ProviderConfig) -> String {
        var str = "Provider: \(config.apiProvider.rawValue)\n"
        str += "Model Name: \(config.modelName)\n"
        str += "Base URL: \(config.baseURL ?? "Default (Not set)")\n"
        
        // Dynamic Strategy Flag Logging
        let flagIndicator = config.supportsNativeTools ? "✅ YES -> Routes to NativeStructuredGenerator()" : "❌ NO -> Routes to PromptedJsonModeStrategy()"
        str += "Supports Native Tools: \(flagIndicator)\n"
        
        if let key = config.apiKey, !key.isEmpty {
            let masked = key.count > 8 ? "\(key.prefix(4))...\(key.suffix(4))" : "****"
            str += "API Key: \(masked) (Masked for Security)\n"
        } else {
            str += "API Key: None\n"
        }
        
        if let adv = config.advancedConfiguration, !adv.isEmpty {
            str += "Advanced Config Keys: \(adv.keys.joined(separator: ", "))\n"
        } else {
            str += "Advanced Config: Default / None\n"
        }
        
        return str
    }
}
