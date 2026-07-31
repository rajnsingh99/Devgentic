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
    func saveProfile(_ snapshot: BackendProfileSnapshot, callerFile: String, callerFunction: String, callerLine: Int) throws

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) throws
}

extension BackendProfileStoreProtocol {
    /// Call this — the four-argument requirement exists only so the compiler can fill in the
    /// caller. Defaults live here rather than on the requirement because a Swift protocol cannot
    /// carry default parameter values, and every call site spelling out `#fileID` would defeat
    /// the point.
    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     file: String = #fileID,
                     function: String = #function,
                     line: Int = #line) throws {
        try saveProfile(snapshot, callerFile: file, callerFunction: function, callerLine: line)
    }
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
    func saveProfile(
        _ snapshot: BackendProfileSnapshot,
        callerFile: String,
        callerFunction: String,
        callerLine: Int
    ) throws {
        // Compiler-supplied caller attribution. Every save previously logged an identical line
        // whoever called it, so a burst of them named neither the trigger nor the reason — the
        // one thing needed to tell "the user saved" from "a binding is firing in a loop".
        let caller = "\(callerFile):\(callerLine) \(callerFunction)"

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
                // Is anything actually different? `lastSelected` is deliberately excluded — it is
                // bumped on EVERY call, so it can never be equal and would mask a no-op.
                //
                // ⚠️ A no-op save is not free. Assigning to a SwiftData model dirties it whether
                // or not the value changed, so a redundant call still costs a write, a
                // `lastSelected` bump that reorders "recently used", and a WAL entry. An
                // on-device run on 2026-07-31 emitted this line ~18× per profile back-to-back
                // with no indication of caller or cause; the caller attribution below exists to
                // make that answerable from a log instead of by reading every call site.
                let unchanged = existing.displayName == snapshot.displayName
                    && existing.details == snapshot.details
                    && existing.fileContextStrategy == snapshot.fileContextStrategy

                existing.displayName = snapshot.displayName
                existing.lastSelected = now
                existing.details = snapshot.details
                existing.fileContextStrategy = snapshot.fileContextStrategy

                if unchanged {
                    logger.notice("""
                        [PROFILE_SAVE] ⚠️ REDUNDANT — '\(snapshot.displayName)' (\(snapshot.id.uuidString)) \
                        saved with NO field changed. Still costs a write and bumps lastSelected \
                        (which reorders "recently used"). Called from \(caller)
                        """)
                } else {
                    logger.info("[PROFILE_SAVE] Updated '\(snapshot.displayName)' (\(snapshot.id.uuidString)) from \(caller)")
                }
            } else {
                let newModel = BackendProfile(
                    id: snapshot.id,
                    displayName: snapshot.displayName,
                    lastSelected: now,
                    details: snapshot.details,
                    fileContextStrategy: snapshot.fileContextStrategy
                )
                context.insert(newModel)
                logger.info("[PROFILE_SAVE] Inserted '\(snapshot.displayName)' (\(snapshot.id.uuidString)) from \(caller)")
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
