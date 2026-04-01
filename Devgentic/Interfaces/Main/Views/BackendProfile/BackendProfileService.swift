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
import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendProfileService")

/// An ObservableObject that acts as the central service for the Backend Profile UI.
/// It manages the list of profiles, handles persistence, and provides logic for advanced configurations.
///
/// **Change tracking** is NOT handled here — it lives in `ProfileEditBuffer`.
/// The service is a thin persistence + list layer. Detail views own an edit buffer
/// and only call `saveProfile(_:)` when the user explicitly saves.
@MainActor
final class BackendProfileService: ObservableObject {

    /// The published array of profiles that the sidebar observes.
    /// This always reflects the **last-persisted** state.
    @Published var profiles: [BackendProfileModel] = []

    /// The active edit buffer for the currently selected profile.
    /// Owned by the service so the panel view's navigation guard can check `editBuffer?.isDirty`.
    @Published var editBuffer: ProfileEditBuffer?

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
        do {
            self.profiles = try profileStore.fetchProfiles()
        } catch {
            logger.error("loadProfiles failed: \(error.localizedDescription)")
            // Keep existing in-memory profiles rather than clearing on transient errors
        }
    }

    /// Saves a given profile to the persistence layer and updates the in-memory array in-place.
    /// Throws `ProfileStoreError` on validation or persistence failure so callers can show errors.
    func saveProfile(_ profile: BackendProfileModel) throws {
        // Capture old knowledge sources before save for change detection
        let oldSources: [KnowledgeSource]?
        if let existing = profiles.first(where: { $0.id == profile.id }) {
            oldSources = resolveKnowledgeSources(from: existing)
        } else {
            oldSources = nil
        }

        try profileStore.saveProfile(profile)

        // Update in-place to preserve sidebar ordering
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            // New profile — reload to get correct sort order
            loadProfiles()
        }

        // Detect knowledge source changes and notify KnowledgeSourceMonitor
        let newSources = resolveKnowledgeSources(from: profile)
        if let old = oldSources, let new = newSources, old != new {
            Task.detached(priority: .utility) {
                await KnowledgeSourceMonitor.shared.handleProfileSourcesChanged(
                    oldSources: old,
                    newSources: new,
                    conversationID: UUID() // Synthetic — sources apply across conversations
                )
            }
        }
    }

    /// Resolves knowledge sources from profile details.
    private func resolveKnowledgeSources(from profile: BackendProfileModel) -> [KnowledgeSource]? {
        switch profile.details {
        case .bot(let config):   return config.knowledgeSources
        case .agent(let config): return config.knowledgeSources
        default:                 return nil
        }
    }

    /// Deletes a profile using its ID from the persistence layer and reloads the local array.
    func deleteProfile(withId id: UUID) throws {
        try profileStore.deleteProfile(withId: id)
        if editBuffer?.draft.id == id {
            editBuffer = nil
        }
        loadProfiles()
    }

    // MARK: - Edit Buffer Management

    /// Creates (or replaces) the edit buffer for the given profile ID.
    /// Call when the user selects a profile in the sidebar.
    func activateEditBuffer(for id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        editBuffer = ProfileEditBuffer(profile: profile)
    }

    /// Discards the current edit buffer.
    func deactivateEditBuffer() {
        editBuffer = nil
    }

    // MARK: - Advanced Configuration Logic

    /// The main public method to get a strongly-typed advanced configuration model for a profile.
    /// It decodes the stored dictionary or returns a default configuration if none exists.
    func getAdvancedConfig(for profile: BackendProfileModel) -> any Codable {
        // 1. Extract the ProviderConfig based on the profile's details.
        let providerConfig: ProviderConfig?
        switch profile.details {
        case .bot(let config):
            providerConfig = config.llmConfig
        case .agent(let config):
            providerConfig = config.llmConfig
        case .imageGen(let config):
            providerConfig = config.llmConfig
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

        case .anthropic:
            return decodeConfig(from: config.advancedConfiguration, as: AnthropicAdvancedConfig.self)
                ?? AnthropicAdvancedConfig.default()

        case .openAI:
            return decodeConfig(from: config.advancedConfiguration, as: OpenAIAdvancedConfig.self)
                ?? OpenAIAdvancedConfig.default()

        default:
            return OllamaAdvancedConfig.default()
        }
    }

    /// Encodes a specific `Codable` model into the `[String: JSONValue]` dictionary format.
    /// - Returns: The encoded dictionary, or `nil` if encoding fails.
    func encodeConfig<T: Codable>(from config: T) -> [String: JSONValue]? {
        do {
            let data = try JSONEncoder().encode(config)
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any] else {
                logger.warning("Failed to cast JSON object to [String: Any] during advanced config encode.")
                return nil
            }
            return dictionary.mapValues { JSONValue($0) ?? .null }
        } catch {
            logger.error("Failed to encode advanced configuration: \(error.localizedDescription)")
            return nil
        }
    }

    /// Decodes a `[String: JSONValue]` dictionary back into a specific `Codable` model type.
    /// - Returns: The decoded model, or `nil` if the dictionary is missing or decoding fails.
    func decodeConfig<T: Codable>(from dictionary: [String: JSONValue]?, as type: T.Type) -> T? {
        guard let dictionary = dictionary else { return nil }

        let unwrappedDict = dictionary.mapValues { $0.rawValue }

        do {
            let data = try JSONSerialization.data(withJSONObject: unwrappedDict)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            logger.error("Failed to decode advanced configuration: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Diagnostics / Logging

    /// Logs the full, detailed configuration of the selected profile to the console.
    func logProfileSelection(profileID: UUID) {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }

        var logOutput = "\n\n==================================================\n"
        logOutput += "PROFILE SELECTED: \(profile.displayName)\n"
        logOutput += "==================================================\n"
        logOutput += "ID: \(profile.id)\n"
        logOutput += "Type: \(profile.profileType.rawValue)\n"
        logOutput += "Last Selected: \(profile.lastSelected?.description ?? "Never")\n\n"

        switch profile.details {
        case .bot(let config):
            logOutput += "[BOT CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n"

        case .agent(let config):
            logOutput += "[AGENT CONFIGURATION]\n"
            logOutput += "Architecture: \(config.architecture.rawValue)\n"
            logOutput += "Description: \(config.description ?? "None")\n"
            logOutput += "Instructions (Length): \(config.instructions?.count ?? 0) characters\n\n"

            logOutput += "[TOOLS (\(config.tools.filter({ $0.isEnabled }).count) Active)]\n"
            if config.tools.isEmpty {
                logOutput += "  - No tools configured.\n"
            } else {
                for tool in config.tools {
                    let status = tool.isEnabled ? "ON" : "OFF"
                    logOutput += "  [\(status)] \(tool.name) (Requires Confirmation: \(tool.requiresConfirmation))\n"
                }
            }
            logOutput += "\n"

            logOutput += "[KNOWLEDGE SOURCES (\(config.knowledgeSources?.count ?? 0) Active)]\n"
            if let sources = config.knowledgeSources, !sources.isEmpty {
                for source in sources {
                    logOutput += "  - [\(source.type.rawValue)] \(source.location)\n"
                }
            } else {
                logOutput += "  - No knowledge sources.\n"
            }
            logOutput += "\n"

            logOutput += "[LLM / PROVIDER CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)

        case .workflow(let config):
            logOutput += "[WORKFLOW CONFIGURATION]\n"
            logOutput += "Agent Profile IDs: \(config.agentProfileIDs.count)\n"
            for (index, id) in config.agentProfileIDs.enumerated() {
                logOutput += "  \(index + 1). \(id.uuidString)\n"
            }

        case .imageGen(let config):
            logOutput += "[IMAGE GENERATOR CONFIGURATION]\n"
            logOutput += formatLLMConfig(config.llmConfig)
            logOutput += "Negative Prompt: \(config.negativePrompt ?? "None")\n"
            logOutput += "Default Aspect Ratio: \(config.defaultAspectRatio?.rawValue ?? "Not set")\n"
        }

        logOutput += "==================================================\n\n"

        logger.info("\(logOutput)")
    }

    private func formatLLMConfig(_ config: ProviderConfig) -> String {
        var str = "Provider: \(config.apiProvider.rawValue)\n"
        str += "Model Name: \(config.modelName)\n"
        str += "Base URL: \(config.baseURL ?? "Default (Not set)")\n"

        let flagIndicator = "Capability: \(config.cognitiveCapability.rawValue)"
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
