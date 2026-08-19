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
    ///
    /// - Returns: the ADVISORY findings for the saved profile. ⚠️ Register A34: these were computed
    ///   on every save and then dropped on the floor — the only trace was a log line, so an advisory
    ///   rule could never reach the user without someone hand-building a bespoke view for it.
    ///   Returning them gives the severity a product surface by virtue of being an advisory.
    ///   `@discardableResult` because most callers legitimately do not care.
    @discardableResult
    func saveProfile(_ snapshot: BackendProfileSnapshot, callerFile: String, callerFunction: String, callerLine: Int) throws -> [ProfileValidationError]

    /// Deletes a profile with the specified ID.
    func deleteProfile(withId id: UUID) throws
}

extension BackendProfileStoreProtocol {
    /// Call this — the four-argument requirement exists only so the compiler can fill in the
    /// caller. Defaults live here rather than on the requirement because a Swift protocol cannot
    /// carry default parameter values, and every call site spelling out `#fileID` would defeat
    /// the point.
    @discardableResult
    func saveProfile(_ snapshot: BackendProfileSnapshot,
                     file: String = #fileID,
                     function: String = #function,
                     line: Int = #line) throws -> [ProfileValidationError] {
        try saveProfile(snapshot, callerFile: file, callerFunction: function, callerLine: line)
    }
}

// MARK: - SwiftData Backend Profile Store

/// The persistence layer for backend profiles, backed by SwiftData.
///
/// ⚠️ API keys are NOT in the blob. They live in the Keychain via `ProviderKeyStore`, keyed on
/// profile id; `BackendProfileSD` strips them on write and re-injects on read. This comment
/// previously stated the opposite and was accurate at the time — the blob held every cloud key in
/// cleartext, recoverable with `strings` from an unsandboxed Application Support directory.
@MainActor
final class BackendProfileStore: BackendProfileStoreProtocol {

    // MARK: - Singleton Instance
    static let shared = BackendProfileStore()

    // MARK: - SwiftData Container

    private(set) var modelContainer: ModelContainer?

    func configureContainer(_ container: ModelContainer) {
        self.modelContainer = container
        logger.info("BackendProfileStore configured with SwiftData ModelContainer.")
        migrateAPIKeysToKeychain()
        // register A53 — the blob sweep above only reaches credentials stored in SwiftData.
        // `GeminiService` also wrote raw keys into UserDefaults; those need their own removal.
        ProviderKeyStore.purgeLegacyPlaintextKeys()
    }

    /// One-time sweep moving API keys out of the stored blobs and into the Keychain.
    ///
    /// ⚠️ Fixing the write path only protects FUTURE saves — every profile written before it keeps
    /// its key in `configData` until something rewrites that row, which for a profile the user
    /// never edits again is never. For a credential-at-rest fix that is not good enough, so this
    /// actively rewrites them at launch. Same launch-hook shape as
    /// `DownloadHistoryStore.reconcileOrphans`.
    ///
    /// ⚠️ Deliberately does NOT go through `saveProfile`: that stamps `lastSelected`, which would
    /// reorder the user's entire "recently used" sidebar on one launch as a side effect of a
    /// security fix. Assigning `details` is enough — the setter strips the key and re-encodes.
    private func migrateAPIKeysToKeychain() {
        guard let context = mainContext else { return }

        var descriptor = FetchDescriptor<BackendProfile>()
        descriptor.fetchLimit = 500
        guard let models = try? context.fetch(descriptor) else {
            logger.error(
                "[SECRETS] Could not fetch profiles for the API-key migration. CONSEQUENCE: any "
                + "keys still stored inline remain in the profile blob until the next launch."
            )
            return
        }

        var attempted = 0
        var migrated = 0
        var stillInline = 0
        for model in models {
            guard model.hasInlineAPIKeyInStoredBlob else { continue }
            attempted += 1
            // Assigning through the setter performs the strip-and-store: it writes the key to the
            // Keychain and re-encodes `configData` without it.
            model.details = model.details

            // ⚠️ register B25 — count what actually HAPPENED, not what was tried. This used to be
            // an unconditional `migrated += 1` right after the assignment, and the assignment
            // succeeds even when the Keychain write inside it failed: the setter deliberately
            // keeps the key inline in that case rather than destroying it. So on a launch where
            // the Keychain was unavailable — a login-item start before unlock is the ordinary
            // case — every row kept its inline key and the log still announced that N keys were
            // "no longer readable from DevgenticSD.store". A security claim stated as achieved
            // when it was not is worse than no log line at all.
            if model.hasInlineAPIKeyInStoredBlob {
                stillInline += 1
            } else {
                migrated += 1
            }
        }

        if stillInline > 0 {
            logger.error(
                "[SECRETS] \(stillInline) of \(attempted) profile(s) still hold their API key "
                + "INLINE after the migration pass — the Keychain write failed for them, so the "
                + "key was deliberately left in the blob rather than destroyed. CONSEQUENCE: those "
                + "credentials remain readable from DevgenticSD.store and from any backup of "
                + "Application Support; the sweep retries on the next launch."
            )
        }

        guard attempted > 0 else { return }
        do {
            try context.save()
            if migrated > 0 {
                logger.notice(
                    "[SECRETS] Migrated \(migrated) provider API key(s) out of the profile blobs and "
                    + "into the Keychain. CONSEQUENCE: those keys are no longer readable from "
                    + "DevgenticSD.store or from any backup of Application Support."
                )
            }
        } catch {
            logger.error(
                "[SECRETS] The API-key migration could not be saved: \(error.localizedDescription). "
                + "CONSEQUENCE: \(migrated) key(s) are now in the Keychain but ALSO still in the "
                + "profile blobs; the sweep retries on the next launch."
            )
        }
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

    /// What a profile row still knows about itself when its `configData` blob cannot be decoded.
    ///
    /// These come from real, denormalized COLUMNS — untouched by a failed decode, because only the
    /// `details` setter writes them. So the app can tell the user exactly what they had
    /// ("Agent · anthropic · claude-sonnet-4") with no new persistence and no guessing.
    struct UnreadableProfileInfo: Equatable, Identifiable {
        let id: UUID
        let displayName: String
        /// From `profileTypeRaw`, NOT from `details`. ⚠️ This is the whole point: the placeholder
        /// issued after a failed decode is a `.bot`, so `BackendProfileSnapshot.profileType` — which
        /// derives from `details` — reports a corrupted Agent as a Bot everywhere in the UI.
        let storedType: ProfileType?
        let storedProvider: String
        let storedModel: String

        /// ⚠️ Load-bearing for what the UI is allowed to offer. `.writtenByNewerBuild` means the bytes
        /// are INTACT — the only correct action is to change nothing and update the app — so the
        /// destructive "Discard and Reconfigure" path must not lead there (register G18).
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

    /// Profiles whose stored configuration could not be decoded on this launch.
    ///
    /// ⚠️ A store-level QUERY, deliberately — not a field on `BackendProfileSnapshot`. The snapshot is
    /// `Hashable` and drives `ProfileEditBuffer.isDirty` (`draft != original`), so a stored property
    /// carrying a transient, this-launch decode flag could pin a corrupted profile permanently dirty
    /// or permanently clean. Same reasoning that produced `WorkflowLayoutStore.isLayoutUnreadable(for:)`.
    ///
    /// (This argument used to have a second leg — the snapshot was also the profile EXPORT format, so
    /// the flag would have leaked into every exported file. Profile import/export was removed on
    /// 2026-08-06 as an unwanted feature, register G93/G97; the `Hashable`/`isDirty` leg stands on its
    /// own and is why this is still a query.)
    ///
    /// ⚠️ Call this from a load/refresh point, never from a SwiftUI `body`: it primes a JSON decode
    /// per profile.
    func unreadableProfiles() -> [UnreadableProfileInfo] {
        // ⚠️ Both early returns below FAIL OPEN — they answer "no profile is unreadable", which is
        // indistinguishable from a healthy store. That is the wrong direction for a corruption
        // warning: `BackendProfileDetailView` drives the entire "your configuration could not be
        // read" banner off this result, so a failure here silently RETIRES the warning and the
        // user is invited to keep editing a profile whose blob is not being read.
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
        // ⚠️ Fails open the same way, and on the SEND path as well as the editor — answering
        // "this profile is fine" is what lets a request go out built from a placeholder config.
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

    /// Deliberately discards a profile's unreadable configuration, replacing it with a fresh one of
    /// the type the row still claims to be.
    ///
    /// ⚠️ DESTRUCTIVE and irreversible. Callers must confirm with the user first, quoting
    /// `UnreadableProfileInfo.wasSummary` so they know what they are giving up.
    @discardableResult
    func discardUnreadableConfiguration(for id: UUID, reason: String) -> Bool {
        // ⚠️ Both early returns below used to be bare `return false` with NO log, while the caller
        // (`BackendProfileDetailView.discardUnreadableConfiguration`) does
        // `guard didDiscard else { return }  // store logged it` — a comment that was factually
        // wrong for exactly these paths. The user accepted a destructive confirmation, the banner
        // stayed up, no toast appeared, and nothing anywhere recorded that the click did nothing.
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

        // Rebuild as the type the ROW says it was, not the `.bot` placeholder the failed decode
        // produced — otherwise "reconfigure" silently demotes the user's Agent to a Bot, which is the
        // very mislabelling this whole change exists to stop.
        let provider = ApiProvider(rawValue: model.providerRaw) ?? .ollama
        let llm = ProviderConfig(apiProvider: provider, modelName: model.modelNameRaw)
        let replacement: ProfileDetails
        switch ProfileType(rawValue: model.profileTypeRaw) {
        case .agent:    replacement = .agent(AgentConfig(llmConfig: llm))
        case .workflow: replacement = .workflow(WorkflowConfig(agentProfileIDs: []))
        case .imageGen: replacement = .imageGen(ImageGenConfig(llmConfig: llm))
        case .code:     replacement = .code(AgentConfig(llmConfig: llm))
        case .bot, nil: replacement = .bot(BotConfig(llmConfig: llm))
        }

        model.discardUnreadableConfiguration(replacingWith: replacement, reason: reason)
        do {
            try context.save()
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

            // ⚠️ Gate on `.blocking` ONLY — never on `isEmpty` (G92). This used to refuse the save
            // whenever ANY finding came back, which handed an explicitly advisory sentence the
            // force of a hard error and made a local agent profile creatable but not editable.
            // A new advisory rule must never silently become a gate by being added to this array.
            let blockers = validationErrors.blocking
            let advisories = validationErrors.advisories
            if !advisories.isEmpty {
                logger.notice(
                    "[PROFILE] '\(snapshot.displayName)' saved with \(advisories.count) advisory "
                    + "finding(s): \(advisories.map { "\($0.field): \($0.message)" }.joined(separator: " | ")). "
                    + "CONSEQUENCE: none for the save — these describe likely-degraded behaviour and "
                    + "are surfaced by the model pickers, not by refusing the write."
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
            // ⚠️ Register A34. Returned, not just logged. An advisory that only reaches the log can
            // never reach the person who can act on it, and the two rules that exist today both had
            // to hand-build their own bespoke UI to be seen at all. Handing them back means the next
            // advisory rule is visible by virtue of being an advisory.
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
                try context.save()
                // ⚠️ After the row is gone, not before: a failed save would otherwise leave a
                // profile whose credential had already been destroyed. A key must never outlive
                // the profile that owned it — that was one of the two distinct harms in the
                // UserDefaults side-effect finding too.
                ProviderKeyStore.delete(for: id)
                logger.info("Deleted profile with ID \(id.uuidString) and its stored API key.")
            }
        } catch {
            logger.error("Failed to delete profile with ID \(id.uuidString): \(error.localizedDescription)")
            throw ProfileStoreError.deleteFailed(underlying: error)
        }
    }
}
