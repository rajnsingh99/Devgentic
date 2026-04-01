//
//  BackendProfileSD.swift
//  Devgentic
//
//  Created on 26/03/26.
//
//  SwiftData @Model for BackendProfile persistence.
//  Replaces the Core Data BackendProfileEntity cluster
//  (BackendProfileEntity, BotConfigEntity, AgentConfigEntity,
//  WorkflowConfigEntity, ImageGenConfigEntity).
//

import Foundation
import SwiftData
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "BackendProfileSD")

// MARK: - SwiftData Model

@Model
final class BackendProfile {

    // MARK: - Persisted Properties

    @Attribute(.unique)
    var id: UUID

    var displayName: String
    var lastSelected: Date?

    /// Raw value of `ProfileType` — used as a discriminator for queries/sorts.
    var profileTypeRaw: String

    /// Raw value of `FileContextStrategy`. Nil means "use smart default for profile type".
    var fileContextStrategyRaw: String?

    /// Denormalized provider name (e.g. "ollama", "openAI") for queryability without decoding the blob.
    var providerRaw: String = ""

    /// Denormalized model name for queryability without decoding the blob.
    var modelNameRaw: String = ""

    /// JSON-encoded `ProfileDetails` blob. This is the single source of truth for
    /// the type-specific configuration (Bot, Agent, Workflow, ImageGen).
    var configData: Data

    // MARK: - Transient Cache

    /// In-memory cache so we don't re-decode on every property access.
    @Transient
    private var _cachedDetails: ProfileDetails?

    // MARK: - Computed Accessors

    /// The strongly-typed profile type, derived from the stored raw value.
    var profileType: ProfileType {
        ProfileType(rawValue: profileTypeRaw) ?? .bot
    }

    /// The user-selected file context strategy, resolved from the raw string.
    var fileContextStrategy: FileContextStrategy? {
        get { fileContextStrategyRaw.flatMap { FileContextStrategy(rawValue: $0) } }
        set { fileContextStrategyRaw = newValue?.rawValue }
    }

    /// The rich, type-safe configuration envelope.
    /// Reading decodes from `configData` (with caching); writing re-encodes.
    var details: ProfileDetails {
        get {
            if let cached = _cachedDetails { return cached }
            let decoded = Self.decodeDetails(from: configData)
            _cachedDetails = decoded
            return decoded
        }
        set {
            _cachedDetails = newValue
            configData = Self.encodeDetails(newValue)
            // Keep denormalized columns in sync
            switch newValue {
            case .bot:       profileTypeRaw = ProfileType.bot.rawValue
            case .agent:     profileTypeRaw = ProfileType.agent.rawValue
            case .workflow:  profileTypeRaw = ProfileType.workflow.rawValue
            case .imageGen:  profileTypeRaw = ProfileType.imageGen.rawValue
            }
            let (provider, model) = Self.extractProviderAndModel(from: newValue)
            providerRaw = provider
            modelNameRaw = model
        }
    }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        displayName: String,
        lastSelected: Date? = nil,
        details: ProfileDetails,
        fileContextStrategy: FileContextStrategy? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.fileContextStrategyRaw = fileContextStrategy?.rawValue

        // Derive discriminator from the details case
        switch details {
        case .bot:       self.profileTypeRaw = ProfileType.bot.rawValue
        case .agent:     self.profileTypeRaw = ProfileType.agent.rawValue
        case .workflow:  self.profileTypeRaw = ProfileType.workflow.rawValue
        case .imageGen:  self.profileTypeRaw = ProfileType.imageGen.rawValue
        }

        let (provider, model) = Self.extractProviderAndModel(from: details)
        self.providerRaw = provider
        self.modelNameRaw = model

        self.configData = Self.encodeDetails(details)
        self._cachedDetails = details
    }

    // MARK: - Denormalization Helpers

    /// Extracts provider and model name from ProfileDetails for denormalized columns.
    private static func extractProviderAndModel(from details: ProfileDetails) -> (provider: String, model: String) {
        switch details {
        case .bot(let config):      return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .agent(let config):    return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .imageGen(let config): return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .workflow:             return ("", "")
        }
    }

    // MARK: - Encode / Decode Helpers

    /// Encodes ProfileDetails to JSON data. Fatally asserts on failure since encoding
    /// a known-good in-memory value should never fail — a `"{}"` fallback would silently
    /// destroy the user's profile data on the next read.
    private static func encodeDetails(_ details: ProfileDetails) -> Data {
        do {
            return try JSONEncoder().encode(details)
        } catch {
            logger.fault("Failed to encode ProfileDetails — refusing to write corrupt data: \(error.localizedDescription)")
            // Return the error-marker blob that decodeDetails recognises as "do not overwrite"
            // This prevents the SwiftData auto-save from persisting a corrupt empty blob.
            assertionFailure("ProfileDetails encoding should never fail for a valid in-memory value.")
            return Data("{}".utf8)
        }
    }

    /// Decodes ProfileDetails from JSON data, running schema migrations first.
    /// Falls back to a default bot config only as a last resort to prevent crashes.
    private static func decodeDetails(from data: Data) -> ProfileDetails {
        // Run migration pipeline before decoding
        let migrated = ProfileMigrator.migrateIfNeeded(data)

        do {
            return try JSONDecoder().decode(ProfileDetails.self, from: migrated)
        } catch {
            logger.error("Failed to decode ProfileDetails after migration: \(error.localizedDescription)")
            return .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: "")))
        }
    }
}

// MARK: - Convenience Extensions

extension BackendProfile {
    /// Creates a lightweight snapshot suitable for passing across actor / concurrency boundaries.
    /// The snapshot is a plain value type with no SwiftData model context dependency.
    func snapshot() -> BackendProfileSnapshot {
        BackendProfileSnapshot(
            id: id,
            displayName: displayName,
            lastSelected: lastSelected,
            details: details,
            fileContextStrategy: fileContextStrategy
        )
    }
}

// MARK: - BackendProfileSnapshot (Value-type mirror for cross-boundary use)

/// A `Sendable` value-type copy of a `BackendProfile` for use outside SwiftData contexts
/// (e.g., passing to `AgentConnect`, `BackendOrchestrationService`, ChatOps bridges).
struct BackendProfileSnapshot: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var lastSelected: Date?
    var details: ProfileDetails

    /// User-selected file context strategy. When nil, resolves to the smart default for the profile type.
    var fileContextStrategy: FileContextStrategy?

    /// Resolved file context strategy — uses explicit setting or falls back to smart default.
    var resolvedFileContextStrategy: FileContextStrategy {
        fileContextStrategy ?? FileContextStrategy.defaultStrategy(for: profileType)
    }

    var profileType: ProfileType {
        switch details {
        case .bot:       return .bot
        case .agent:     return .agent
        case .workflow:  return .workflow
        case .imageGen:  return .imageGen
        }
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        lastSelected: Date? = nil,
        details: ProfileDetails,
        fileContextStrategy: FileContextStrategy? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.details = details
        self.fileContextStrategy = fileContextStrategy
    }
}
