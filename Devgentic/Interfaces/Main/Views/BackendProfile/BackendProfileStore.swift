//
//  BackendProfileStore.swift
//  Devgentic
//
//  Created by Raj Singh on 22/08/25.
//
//  Migrated to SwiftData on 26/03/26.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "BackendProfileStore")

// MARK: - Store Errors

/// Errors surfaced by `BackendProfileStore` so callers can display meaningful feedback.
enum ProfileStoreError: LocalizedError {
    case containerNotConfigured
    case fetchFailed(underlying: Error)
    case saveFailed(underlying: Error)
    case deleteFailed(underlying: Error)
    case validationFailed([ProfileValidationError])

    var errorDescription: String? {
        switch self {
        case .containerNotConfigured:
            return "Profile storage is not configured. Please restart the application."
        case .fetchFailed(let error):
            return "Failed to load profiles: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save profile: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete profile: \(error.localizedDescription)"
        case .validationFailed(let errors):
            return errors.first?.message ?? "Validation failed."
        }
    }
}

// MARK: - Backend Profile Store Protocol

@MainActor
protocol BackendProfileStoreProtocol {
    /// Fetches all stored backend profiles as snapshot value types.
    func fetchProfiles() throws -> [BackendProfileSnapshot]

    /// Fetches a single profile by ID, or nil if not found.
    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot?

    /// Saves or updates a profile from a snapshot.
    /// Runs `ProfileValidator` before persisting — throws `ProfileStoreError.validationFailed` on failure.
    func saveProfile(_ snapshot: BackendProfileSnapshot) throws

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) throws
}

// MARK: - SwiftData Backend Profile Store

/// The persistence layer for backend profiles, backed by SwiftData.
/// API keys are stored directly in the SwiftData blob alongside other profile configuration.
@MainActor
final class BackendProfileStore: BackendProfileStoreProtocol {

    // MARK: - Singleton Instance
    static let shared = BackendProfileStore()

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("BackendProfileStore configured with SwiftData ModelContainer.")
    }

    private var mainContext: ModelContext? {
        modelContainer?.mainContext
    }

    // MARK: - Initialization
    private init() {}

    // MARK: - Public API

    /// Fetches all stored backend profiles, sorted by last selected (most recent first).
    func fetchProfiles() throws -> [BackendProfileSnapshot] {
        guard let context = mainContext else {
            throw ProfileStoreError.containerNotConfigured
        }

        do {
            var descriptor = FetchDescriptor<BackendProfile>(
                sortBy: [SortDescriptor(\.lastSelected, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            let models = try context.fetch(descriptor)
            return models.map { $0.snapshot() }
        } catch {
            logger.error("Failed to fetch Backend Profiles: \(error.localizedDescription)")
            throw ProfileStoreError.fetchFailed(underlying: error)
        }
    }

    /// Fetches a single profile by its UUID.
    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot? {
        guard let context = mainContext else {
            throw ProfileStoreError.containerNotConfigured
        }

        let predicate = #Predicate<BackendProfile> { $0.id == id }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            return try context.fetch(descriptor).first?.snapshot()
        } catch {
            logger.error("Failed to fetch profile \(id): \(error.localizedDescription)")
            throw ProfileStoreError.fetchFailed(underlying: error)
        }
    }

    /// Saves or updates a profile from a snapshot.
    /// Enforces validation at the store level — any caller (UI, import, ChatOps) gets the same checks.
    func saveProfile(_ snapshot: BackendProfileSnapshot) throws {
        guard let context = mainContext else {
            throw ProfileStoreError.containerNotConfigured
        }

        let targetID = snapshot.id
        let predicate = #Predicate<BackendProfile> { $0.id == targetID }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            let now = Date()
            let existing = try context.fetch(descriptor).first

            // Pre-save validation: strict for updates (profile already exists),
            // lenient for inserts (initial creation — user configures provider details after).
            let isUpdate = existing != nil
            let validationErrors = ProfileValidator.validate(snapshot, strict: isUpdate)
            if !validationErrors.isEmpty {
                throw ProfileStoreError.validationFailed(validationErrors)
            }

            if let existing = existing {
                existing.displayName = snapshot.displayName
                existing.lastSelected = now
                existing.details = snapshot.details
                existing.fileContextStrategy = snapshot.fileContextStrategy
                logger.info("Updated profile '\(snapshot.displayName)' (ID: \(snapshot.id.uuidString))")
            } else {
                let newModel = BackendProfile(
                    id: snapshot.id,
                    displayName: snapshot.displayName,
                    lastSelected: now,
                    details: snapshot.details,
                    fileContextStrategy: snapshot.fileContextStrategy
                )
                context.insert(newModel)
                logger.info("Inserted new profile '\(snapshot.displayName)' (ID: \(snapshot.id.uuidString))")
            }

            try context.save()
        } catch let storeError as ProfileStoreError {
            throw storeError  // Re-throw validation errors as-is
        } catch {
            logger.error("Failed to save profile '\(snapshot.displayName)': \(error.localizedDescription)")
            throw ProfileStoreError.saveFailed(underlying: error)
        }
    }

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) throws {
        guard let context = mainContext else {
            throw ProfileStoreError.containerNotConfigured
        }

        let predicate = #Predicate<BackendProfile> { $0.id == id }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            if let toDelete = try context.fetch(descriptor).first {
                context.delete(toDelete)
                try context.save()
                logger.info("Deleted profile with ID \(id.uuidString).")
            }
        } catch {
            logger.error("Failed to delete profile with ID \(id.uuidString): \(error.localizedDescription)")
            throw ProfileStoreError.deleteFailed(underlying: error)
        }
    }
}
