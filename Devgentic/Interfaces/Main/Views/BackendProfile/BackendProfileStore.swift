// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendProfileStore.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: declared as a protocol requirement, not just an extension method: extension methods dispatch statically, so the
    // store's query-level override would be bypassed.
    /// The shared library: every profile a picker may offer. See the extension default's doc.
    func fetchSharedProfiles() throws -> [BackendProfileSnapshot]

    /// One workflow's node-owned rows. Same requirement rationale as `fetchSharedProfiles`.
    func fetchOwnedProfiles(forWorkflow workflowID: UUID) throws -> [BackendProfileSnapshot]

    /// Exactly the rows named by `ids`. Same requirement rationale as `fetchSharedProfiles`.
    func fetchProfiles(ids: Set<UUID>) throws -> [BackendProfileSnapshot]

    /// Fetches a single profile by ID, or nil if not found.
    func fetchProfile(byId id: UUID) throws -> BackendProfileSnapshot?

    /// Saves or updates a profile from a snapshot, running `ProfileValidator` first (throws
    /// `ProfileStoreError.validationFailed` on failure). - Returns: the advisory findings for the saved profile, so
    /// callers can surface them; `@discardableResult` because most callers ignore them.
    @discardableResult
    func saveProfile(_ snapshot: BackendProfileSnapshot, callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError]

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) throws
}

extension BackendProfileStoreProtocol {

    // Why: the defaults filter `fetchProfiles()`, which the production store caps at 500 rows, so owned rows and shared
    // profiles would compete for the same window.
    /// The profiles a user may choose: everything except workflow-node-owned rows. The store-level twin of
    /// `BackendProfileService.sharedProfiles`, for pickers that call `fetchProfiles()` directly. These defaults are for
    /// test doubles only; `BackendProfileStore` overrides them with query-level predicates.
    func fetchSharedProfiles() throws -> [BackendProfileSnapshot] {
        try fetchProfiles().filter { !$0.isNodeOwned }
    }

    func fetchProfiles(ids: Set<UUID>) throws -> [BackendProfileSnapshot] {
        try fetchProfiles().filter { ids.contains($0.id) }
    }

    /// The private profile rows belonging to one workflow's nodes. Keyed on `ownerWorkflowID` so it never decodes a
    /// layout blob; the delete cascade and the save-time reconcile both rely on that.
    func fetchOwnedProfiles(forWorkflow workflowID: UUID) throws -> [BackendProfileSnapshot] {
        try fetchProfiles().filter { $0.ownerWorkflowID == workflowID && $0.isNodeOwned }
    }

    /// Call this variant; the four-argument requirement exists only so the compiler fills in the caller. Defaults live
    /// here because a Swift protocol cannot carry default parameter values.
    @discardableResult
    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     file: String = #fileID,
                     function: String = #function,
                     line: Int = #line) throws -> [ProfileValidationError] {
        try saveProfile(snapshot, callerFile: file, callerFunction: function, callerLine: line)
    }
}

// MARK: - SwiftData Backend Profile Store

/// The persistence layer for backend profiles, backed by SwiftData. API keys are not in the blob: they live in the
/// Keychain via `ProviderKeyStore`, keyed on profile id; `BackendProfileSD` strips them on write and re-injects on
/// read.
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

    // Why: filtering after the fetch would let owned rows push real library profiles out of the window.
    /// Query-level shared-library fetch: the predicate excludes node-owned rows before the 500-row window is applied. The
    /// cap stays as a picker bound but counts only shared profiles.
    func fetchSharedProfiles() throws -> [BackendProfileSnapshot] {
        guard let context = mainContext else { throw ProfileStoreError.containerNotConfigured }
        do {
            var descriptor = FetchDescriptor<BackendProfile>(
                predicate: #Predicate { $0.ownerNodeID == nil },
                sortBy: [SortDescriptor(\.lastSelected, order: .reverse)]
            )
            descriptor.fetchLimit = 500
            return try context.fetch(descriptor).map { $0.snapshot() }
        } catch {
            logger.error("Failed to fetch shared Backend Profiles: \(error.localizedDescription)")
            throw ProfileStoreError.fetchFailed(underlying: error)
        }
    }

    // Why: a cap would hide older owned rows from the save-time reconcile and the workflow-delete cascade, orphaning the row
    // and its Keychain credential.
    /// Query-level owned-row fetch, deliberately uncapped: the result is bounded by one workflow's node count.
    func fetchOwnedProfiles(forWorkflow workflowID: UUID) throws -> [BackendProfileSnapshot] {
        guard let context = mainContext else { throw ProfileStoreError.containerNotConfigured }
        do {
            let descriptor = FetchDescriptor<BackendProfile>(
                predicate: #Predicate { $0.ownerWorkflowID == workflowID }
            )
            return try context.fetch(descriptor).map { $0.snapshot() }
        } catch {
            logger.error("Failed to fetch owned profiles for workflow \(workflowID): \(error.localizedDescription)")
            throw ProfileStoreError.fetchFailed(underlying: error)
        }
    }

    /// Query-level by-ids fetch, uncapped and bounded by the caller's id set. `WorkflowExecutor` resolves a run's profile
    /// map through it, so profiles older than the 500-row window are still found.
    func fetchProfiles(ids: Set<UUID>) throws -> [BackendProfileSnapshot] {
        guard let context = mainContext else { throw ProfileStoreError.containerNotConfigured }
        do {
            // #Predicate cannot capture a Set — materialize to Array for `contains`.
            let idList = Array(ids)
            let descriptor = FetchDescriptor<BackendProfile>(
                predicate: #Predicate { idList.contains($0.id) }
            )
            return try context.fetch(descriptor).map { $0.snapshot() }
        } catch {
            logger.error("Failed to fetch \(ids.count) profile(s) by id: \(error.localizedDescription)")
            throw ProfileStoreError.fetchFailed(underlying: error)
        }
    }

    /// What a profile row still knows about itself when its `configData` blob cannot be decoded. The values come from
    /// denormalized columns that a failed decode leaves untouched, so the app can tell the user what they had ("Agent ·
    /// anthropic · claude-sonnet-4").
    struct UnreadableProfileInfo: Equatable, Identifiable {
        let id: UUID
        let displayName: String
        /// Taken from `profileTypeRaw`, not `details`: the placeholder after a failed decode is a `.bot`, so
        /// `BackendProfileSnapshot.profileType` would report a corrupted Agent as a Bot.
        let storedType: ProfileType?
        let storedProvider: String
        let storedModel: String

        /// Decides what the UI may offer: `.writtenByNewerBuild` means the bytes are intact, so the destructive "Discard and
        /// Reconfigure" path must not lead there.
        let reason: ConfigurationUnreadableReason

        /// "Agent · anthropic · claude-sonnet-4", omitting whatever is blank.
        var wasSummary: String {
            var parts: [String] = []
            // rawValue, not localizedTitle: that returns a LocalizedStringKey and these raw values ARE
            // the display names ("Agent", "Image Generator").
            if let storedType { parts.append(storedType.rawValue) }
            if !storedProvider.isEmpty { parts.append(storedProvider) }
            if !storedModel.isEmpty { parts.append(storedModel) }
            return parts.joined(separator: " · ")
        }
    }

    // Why: call it from a load/refresh point, never a SwiftUI `body`; it primes a JSON decode per profile.
    /// Profiles whose stored configuration could not be decoded on this launch. A store-level query rather than a
    /// snapshot field: the snapshot is `Hashable` and drives `ProfileEditBuffer.isDirty`, so a transient decode flag
    /// could pin a profile dirty or clean.
    func unreadableProfiles() -> [UnreadableProfileInfo] {
        // Both early returns fail open, answering "no profile is unreadable"; `BackendProfileDetailView` drives its
        // corruption banner from this, so a failure here silently retires the warning.
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] unreadableProfiles() could not run: the SwiftData container is not "
                + "configured. CONSEQUENCE: reported as 'no profiles are unreadable', so the "
                + "corruption banner will not appear even if a blob is genuinely undecodable."
            )
            return []
        }
        var descriptor = FetchDescriptor<BackendProfile>()
        descriptor.fetchLimit = 500

        let models: [BackendProfile]
        do {
            models = try context.fetch(descriptor)
        } catch {
            logger.error(
                "[PERSISTENCE] unreadableProfiles() fetch failed: \(error.localizedDescription). "
                + "CONSEQUENCE: reported as 'no profiles are unreadable' — the corruption banner is "
                + "suppressed for this launch and any genuinely undecodable profile presents as a "
                + "blank bot instead."
            )
            return []
        }

        return models.compactMap { model in
            guard model.hasUnreadableConfiguration else { return nil }
            return UnreadableProfileInfo(
                id: model.id,
                displayName: model.displayName,
                storedType: ProfileType(rawValue: model.profileTypeRaw),
                storedProvider: model.providerRaw,
                storedModel: model.modelNameRaw,
                reason: model.configurationUnreadableReason ?? .undecodable
            )
        }
    }

    /// Whether this specific profile's configuration is unreadable — the single-row form, for the
    /// editor and the send path where fetching all 500 would be wasteful.
    func isConfigurationUnreadable(for id: UUID) -> Bool {
        // Fails open the same way, on the send path as well as the editor: answering "this profile is fine" lets a request
        // go out built from a placeholder config.
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] isConfigurationUnreadable(\(id)) could not run: the SwiftData "
                + "container is not configured. CONSEQUENCE: reported as readable, so the caller "
                + "proceeds as though the profile's configuration were intact."
            )
            return false
        }
        let predicate = #Predicate<BackendProfile> { $0.id == id }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1

        do {
            guard let model = try context.fetch(descriptor).first else {
                logger.notice(
                    "[PERSISTENCE] isConfigurationUnreadable(\(id)): no such row. CONSEQUENCE: "
                    + "reported as readable; the profile was most likely deleted in another surface."
                )
                return false
            }
            return model.hasUnreadableConfiguration
        } catch {
            logger.error(
                "[PERSISTENCE] isConfigurationUnreadable(\(id)) fetch failed: "
                + "\(error.localizedDescription). CONSEQUENCE: reported as readable, so the caller "
                + "proceeds as though the profile's configuration were intact."
            )
            return false
        }
    }

    /// Discards a profile's unreadable configuration, replacing it with a fresh one of the type the row still claims to
    /// be. Destructive and irreversible: callers must confirm first, quoting `UnreadableProfileInfo.wasSummary`.
    @discardableResult
    func discardUnreadableConfiguration(for id: UUID, reason: String) -> Bool {
        // Both early returns log, since the caller returns silently on `false` and a destructive confirmation that did
        // nothing would otherwise leave no trace.
        guard let context = mainContext else {
            logger.error(
                "[PERSISTENCE] Discard REFUSED for profile \(id): the SwiftData container is not "
                + "configured. CONSEQUENCE: the unreadable-configuration banner stays up and the "
                + "user's confirmed action had no effect."
            )
            return false
        }
        let predicate = #Predicate<BackendProfile> { $0.id == id }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1

        let fetched: BackendProfile?
        do {
            fetched = try context.fetch(descriptor).first
        } catch {
            logger.error(
                "[PERSISTENCE] Discard REFUSED for profile \(id): the row could not be fetched "
                + "(\(error.localizedDescription)). CONSEQUENCE: the unreadable-configuration "
                + "banner stays up and the user's confirmed action had no effect."
            )
            return false
        }

        guard let model = fetched else {
            logger.error(
                "[PERSISTENCE] Discard REFUSED for profile \(id): no such row. CONSEQUENCE: the "
                + "banner stays up; the profile was most likely deleted in another surface while "
                + "this editor was open."
            )
            return false
        }

        guard model.hasUnreadableConfiguration else {
            logger.notice(
                "[PERSISTENCE] Discard SKIPPED for profile \(id): the row is no longer flagged "
                + "unreadable, so there is nothing to replace. CONSEQUENCE: no write is made and "
                + "the banner is dismissed on the next refresh — this is the benign case where the "
                + "blob became readable (e.g. after an app update) between the alert and the tap."
            )
            return false
        }

        // Rebuilds as the type the row says it was, not the `.bot` placeholder, so reconfiguring does not demote an Agent to
        // a Bot.
        let provider = ApiProvider(rawValue: model.providerRaw) ?? .ollama
        let llm = ProviderConfig(apiProvider: provider, modelName: model.modelNameRaw)
        let replacement: ProfileDetails
        switch ProfileType(rawValue: model.profileTypeRaw) {
        case .agent:    replacement = .agent(AgentConfig(llmConfig: llm))
        case .workflow: replacement = .workflow(WorkflowConfig())
        case .imageGen: replacement = .imageGen(ImageGenConfig(llmConfig: llm))
        case .code:     replacement = .code(AgentConfig(llmConfig: llm))
        case .bot, nil: replacement = .bot(BotConfig(llmConfig: llm))
        }

        model.discardUnreadableConfiguration(replacingWith: replacement, reason: reason)
        do {
            try SharedContextSave.save(context, "profiles: discard unreadable \(id)")
            return true
        } catch {
            logger.error(
                "[PERSISTENCE] Failed to persist the discard of profile \(id): "
                + "\(error.localizedDescription). CONSEQUENCE: the profile remains unreadable and the "
                + "warning stays up rather than falsely reporting success."
            )
            return false
        }
    }

    /// Whether this profile's API key is stored but unreadable right now. Returns `false` (no banner) when the row cannot
    /// be fetched, since a false "unreadable" would send the user to Keychain Access for nothing.
    func isProviderKeyUnreadable(for id: UUID) -> Bool {
        providerKeyModel(for: id)?.hasUnreadableProviderKey ?? false
    }

    /// Re-reads this profile's API key from the Keychain now, bypassing the automatic re-read throttle. - Returns:
    /// whether the key is readable afterwards.
    func retryProviderKeyRead(for id: UUID) -> Bool {
        guard let model = providerKeyModel(for: id) else { return false }
        return model.retryProviderKeyRead()
    }

    private func providerKeyModel(for id: UUID) -> BackendProfile? {
        guard let context = mainContext else { return nil }
        let predicate = #Predicate<BackendProfile> { $0.id == id }
        var descriptor = FetchDescriptor<BackendProfile>(predicate: predicate)
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            logger.error("[SECRETS] Could not fetch profile \(id) to check its Keychain key: \(error.localizedDescription). CONSEQUENCE: the unreadable-key banner is not shown for it.")
            return nil
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
    @discardableResult
    func saveProfile(
        _ snapshot: BackendProfileSnapshot,
        callerFile: String,
        callerFunction: String,
        callerLine: Int
    ) throws -> [ProfileValidationError] {
        // Compiler-supplied caller attribution, so a burst of saves identifies the trigger.
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

            // Gates on `.blocking` only, never on `isEmpty`: an advisory finding must not gain the force of a hard error.
            let blockers = validationErrors.blocking
            let advisories = validationErrors.advisories
            if !advisories.isEmpty {
                logger.notice(
                    "[PROFILE] '\(snapshot.displayName)' (\(snapshot.id.uuidString.prefix(8))) saved with \(advisories.count) advisory "
                    + "finding(s): \(advisories.map { "\($0.field): \($0.message)" }.joined(separator: " | ")). "
                    + "CONSEQUENCE: none for the save — these describe likely-degraded behaviour and "
                    + "are surfaced by the model catalog's badges, not by refusing the write. Called from \(caller)"
                )
            }
            if !blockers.isEmpty {
                logger.error(
                    "[PROFILE] Save REFUSED for '\(snapshot.displayName)': "
                    + "\(blockers.map { "\($0.field): \($0.message)" }.joined(separator: " | ")). "
                    + "CONSEQUENCE: the user's edit was discarded and the profile on disk is unchanged."
                )
                throw ProfileStoreError.validationFailed(blockers)
            }

            if let existing = existing {
                // Whether anything actually differs; `lastSelected` is excluded because it changes on every call. A no-op save still
                // costs a write, a `lastSelected` bump and a WAL entry, since assigning dirties the model.
                let unchanged = existing.displayName == snapshot.displayName
                    && existing.details == snapshot.details
                    && existing.fileContextStrategy == snapshot.fileContextStrategy
                    && existing.ownerWorkflowID == snapshot.ownerWorkflowID
                    && existing.ownerNodeID == snapshot.ownerNodeID

                // The no-op is not skipped here: assigning `details` runs a setter that moves the API key to the Keychain, guards
                // undecodable blobs and rewrites denormalized columns. Redundant saves are fixed at the caller.
                existing.displayName = snapshot.displayName
                existing.lastSelected = now
                existing.details = snapshot.details
                existing.fileContextStrategy = snapshot.fileContextStrategy
                // Carried on update as well as insert, so the node inspector's save does not orphan an owned row (reconcile, cascade
                // delete, shared picker).
                existing.ownerWorkflowID = snapshot.ownerWorkflowID
                existing.ownerNodeID = snapshot.ownerNodeID

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
                    fileContextStrategy: snapshot.fileContextStrategy,
                    ownerWorkflowID: snapshot.ownerWorkflowID,
                    ownerNodeID: snapshot.ownerNodeID
                )
                context.insert(newModel)
                logger.info("[PROFILE_SAVE] Inserted '\(snapshot.displayName)' (\(snapshot.id.uuidString)) from \(caller)")
            }

            try SharedContextSave.save(context, "profiles: save '\(snapshot.displayName)'")
            // Returned, not just logged: an advisory that only reaches the log cannot reach the person who can act on it.
            return advisories
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
                try SharedContextSave.save(context, "profiles: delete \(id)")
                // Deleted after the row is gone, so a failed save never leaves a profile whose credential was already destroyed. The
                // result is checked so the log never records a surviving credential as deleted.
                if ProviderKeyStore.delete(for: id) {
                    logger.info("Deleted profile with ID \(id.uuidString) and its stored API key.")
                } else {
                    logger.error("[SECRETS] Deleted profile with ID \(id.uuidString), but its API key is STILL in the Keychain (see the preceding [SECRETS] line). Search Keychain Access for \"\(id.uuidString)\" to remove it.")
                }
            }
        } catch {
            logger.error("Failed to delete profile with ID \(id.uuidString): \(error.localizedDescription)")
            throw ProfileStoreError.deleteFailed(underlying: error)
        }
    }
}
