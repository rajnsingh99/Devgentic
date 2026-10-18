// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackendProfileSD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "BackendProfileSD")

/// Why a profile's stored configuration could not be read.
/// `.undecodable` means damaged bytes (reconfigure); `.writtenByNewerBuild` means intact bytes this build cannot read.
/// The two need opposite responses, so the UI must tell them apart.
enum ConfigurationUnreadableReason: Equatable, Sendable {
    /// The bytes did not decode. Damaged, truncated, or a shape no version understands.
    case undecodable
    /// Stamped with a blob version above what this build knows.
    case writtenByNewerBuild(storedVersion: Int)
}

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

    /// Non-nil when this row is a workflow node's private configuration rather than a shared profile.
    /// `ownerWorkflowID` keys the save-time reconcile and the workflow-delete cascade; `ownerNodeID` is the ownership marker.
    /// Owned rows are excluded from shared-profile surfaces; filter through `BackendProfileService.sharedProfiles`.
    var ownerWorkflowID: UUID?
    var ownerNodeID: UUID?

    /// JSON-encoded `ProfileDetails` blob. This is the single source of truth for
    /// the type-specific configuration (Bot, Agent, Workflow, ImageGen).
    var configData: Data

    // MARK: - Transient Cache

    /// In-memory cache so we don't re-decode on every property access.
    @Transient
    private var _cachedDetails: ProfileDetails?

    /// True when `configData` could not be decoded and `_cachedDetails` is a placeholder, not the user's configuration.
    /// Stops a read failure from becoming a write failure. Transient; not part of the schema.
    @Transient
    private var _detailsUnreadableReason: ConfigurationUnreadableReason?

    /// Unchanged meaning, now derived — every existing guard reads this and keeps working.
    private var _detailsDecodeFailed: Bool { _detailsUnreadableReason != nil }

    /// Whether the last Keychain read for this profile failed, as opposed to finding nothing.
    /// While true, `details` carries no API key and the setter must not delete the stored credential.
    @Transient
    private var _providerKeyUnreadable: Bool = false

    /// Whether any Keychain read for this instance has failed this session.
    /// Sticky, unlike `_providerKeyUnreadable`: a stale draft saved after recovery must not read as a cleared key.
    @Transient
    private var _providerKeyClearSuppressed: Bool = false

    /// When the Keychain was last asked for this profile's key; throttles re-reads, since a locked item can raise a prompt.
    @Transient
    private var _providerKeyLastReadAttempt: Date?

    /// Minimum spacing between automatic re-reads of an unreadable key.
    static let providerKeyRetryInterval: TimeInterval = 60

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

    /// True when `configData` could not be decoded, so `details` is a placeholder and the stored bytes are preserved.
    /// Surface this in the UI instead of presenting the placeholder as the user's configuration.
    var hasUnreadableConfiguration: Bool {
        primeDecodeState()
        return _detailsDecodeFailed
    }

    /// Why the configuration could not be read, or nil when it is readable.
    var configurationUnreadableReason: ConfigurationUnreadableReason? {
        primeDecodeState()
        return _detailsUnreadableReason
    }

    // Why: the flag is transient and defaults to false on a fresh instance, so reading it raw can bypass the refusal.
    /// Brings `_cachedDetails` / `_detailsDecodeFailed` into agreement with the current stored bytes. Idempotent.
    /// Every accessor that consults `_detailsDecodeFailed`, the setter included, must call this first.
    private func primeDecodeState() {
        guard _cachedDetails == nil else {
            // Retries the Keychain read when an earlier read failed, rather than caching the failure for the instance's lifetime.
            if _providerKeyUnreadable { rereadProviderKey(force: false) }
            return
        }
        let outcome = Self.decodeDetails(from: configData)
        // Skips profiles with no per-profile Keychain item: shared-key providers get their key from `GlobalProviderKeys`,
        // and workflows and keyless providers (Ollama, MLX) have none.
        guard outcome.details.keyProvider != nil,
              outcome.details.sharedKeyAccount == nil,
              !outcome.details.isKeylessProvider else {
            _cachedDetails = outcome.details
            _detailsUnreadableReason = outcome.reason
            return
        }
        // Injects the API key from the Keychain here, so it is read once per decode and cached.
        // Uses `read`, not `load` (nil for both "no key" and "read failed"); the write path deletes the item on a nil key.
        let keyOutcome = ProviderKeyStore.read(for: id)
        _providerKeyLastReadAttempt = Date()
        _providerKeyUnreadable = { if case .failed = keyOutcome { return true } else { return false } }()
        if _providerKeyUnreadable { _providerKeyClearSuppressed = true }

        let keychainKey: String? = { if case .found(let k) = keyOutcome { return k } else { return nil } }()

        // The `??` covers a failed Keychain write: the setter left the key inline rather than destroy it.
        // The Keychain value wins when both exist.
        _cachedDetails = outcome.details.settingProviderAPIKey(
            keychainKey ?? outcome.details.providerAPIKey
        )
        _detailsUnreadableReason = outcome.reason
    }

    /// Drops the decode cache so the next `details` read re-primes from `configData`.
    /// Test seam: lets a test that writes `configData` directly make the getter observe those bytes.
    func resetDecodeCacheForTesting() {
        _cachedDetails = nil
        _detailsUnreadableReason = nil
        _providerKeyUnreadable = false
        _providerKeyClearSuppressed = false
        _providerKeyLastReadAttempt = nil
    }

    /// Whether this profile's API key is stored but cannot be read from the Keychain right now
    /// (locked, or an access prompt denied or pending). Distinguishes it from a profile never given a key.
    var hasUnreadableProviderKey: Bool {
        primeDecodeState()
        if let account = _cachedDetails?.sharedKeyAccount {
            if case .failed = GlobalProviderKeys.read(account: account) { return true }
            return false
        }
        return _providerKeyUnreadable
    }

    /// Asks the Keychain for the key again now, ignoring the throttle — the user pressed Try Again.
    /// - Returns: whether the key is readable afterwards (found, or definitively absent).
    @discardableResult
    func retryProviderKeyRead() -> Bool {
        primeDecodeState()
        if let account = _cachedDetails?.sharedKeyAccount {
            if case .failed = GlobalProviderKeys.retry(account: account) { return false }
            return true
        }
        guard _providerKeyUnreadable else { return true }
        rereadProviderKey(force: true)
        return !_providerKeyUnreadable
    }

    /// Re-reads only the key; the cached blob decode is unaffected by Keychain state.
    /// Found replaces the cached key; not found clears the flag and keeps any inline key; failed only updates the throttle.
    /// `_providerKeyClearSuppressed` is never cleared here.
    private func rereadProviderKey(force: Bool) {
        if !force, let last = _providerKeyLastReadAttempt,
           Date().timeIntervalSince(last) < Self.providerKeyRetryInterval {
            return
        }
        _providerKeyLastReadAttempt = Date()
        switch ProviderKeyStore.read(for: id, bypassingFailedRead: true) {
        case .found(let key):
            _providerKeyUnreadable = false
            _cachedDetails = _cachedDetails?.settingProviderAPIKey(key)
            logger.notice("[SECRETS] The Keychain API key for profile '\(displayName)' (id \(id)) is readable again; the profile is configured once more.")
        case .notFound:
            _providerKeyUnreadable = false
        case .failed:
            break
        }
    }

    /// Test seam: makes the next `details` read eligible to re-read the key without waiting out `providerKeyRetryInterval`.
    func expireProviderKeyRetryThrottleForTesting() {
        _providerKeyLastReadAttempt = nil
    }

    /// Explicitly discards an unreadable configuration and replaces it; logged as a deliberate act.
    /// The sanctioned way past the refusal to overwrite, mirroring `WorkflowLayoutSD.replaceUnreadableLayout`.
    func discardUnreadableConfiguration(replacingWith newValue: ProfileDetails, reason: String) {
        logger.warning(
            "[PERSISTENCE] Discarding unreadable profile blob — '\(displayName)' (id \(id)), reason: "
            + "\(reason). It was stored as \(profileTypeRaw)/\(providerRaw)/\(modelNameRaw) "
            + "(\(configData.count) bytes). CONSEQUENCE: the original undecodable bytes are overwritten "
            + "and are no longer recoverable by any future build."
        )
        _detailsUnreadableReason = nil
        details = newValue
    }

    var details: ProfileDetails {
        get {
            primeDecodeState()
            return Self.injectingSharedKey(into: _cachedDetails ?? Self.decodeDetails(from: configData).details)
        }
        set {
            // Load-bearing: see `primeDecodeState()`.
            primeDecodeState()
            // Refuses to overwrite bytes that could not be read: a placeholder coming back is an opportunistic save,
            // while a genuine edit differs. Compared against what the getter handed out, since it injects the shared key.
            if _detailsDecodeFailed, newValue == _cachedDetails.map(Self.injectingSharedKey(into:)) {
                logger.error(
                    "[PERSISTENCE] Refusing to overwrite unreadable profile blob — profile '\(displayName)' "
                    + "(id \(id)): the incoming value is the placeholder issued after the failed decode, so "
                    + "this is an opportunistic save rather than a user edit. CONSEQUENCE: configData is left "
                    + "byte-intact and the original configuration remains recoverable; this profile will keep "
                    + "presenting as a blank bot until it is explicitly re-saved with real values."
                )
                return
            }
            if _detailsDecodeFailed {
                logger.warning(
                    "[PERSISTENCE] Replacing unreadable profile blob — profile '\(displayName)' (id \(id)) is "
                    + "being written with a value that differs from the placeholder, so it is treated as a "
                    + "deliberate user edit. CONSEQUENCE: the original undecodable bytes are overwritten and "
                    + "are no longer recoverable."
                )
                _detailsUnreadableReason = nil
            }

            let detailsToEncode: ProfileDetails
            let detailsToCache: ProfileDetails
            if let account = newValue.sharedKeyAccount {
                // One key per provider: the shared key is not this profile's to write or delete, so a save strips it
                // and never touches the Keychain.
                Self.noteDiscardedSharedKey(carriedBy: newValue, account: account,
                                            profileName: displayName, profileID: id)
                detailsToEncode = newValue.settingProviderAPIKey(nil)
                // The getter injects the shared key, so the cache holds the stripped value.
                detailsToCache = detailsToEncode
            } else if newValue.isKeylessProvider, !Self.keepsOwnKey(_cachedDetails) {
                // A keyless provider (Ollama, MLX) has nothing to store, so a save never touches the Keychain; carried keys drop.
                // Gated on the previous value too, so switching from a keyed provider takes the branch below and clears the old item.
                detailsToEncode = newValue.settingProviderAPIKey(nil)
                detailsToCache = detailsToEncode
            } else {
                // Moves the key to the Keychain before encoding and strips it from the blob only after that write succeeds.
                // A keyless provider reaches here only when leaving a keyed one; nil clears the old item.
                let keyForKeychain = newValue.isKeylessProvider ? nil : newValue.providerAPIKey

                // Suppresses clearing the Keychain item while reads are failing: a nil key is user intent only when readable.
                // Uses the sticky flag, not `_providerKeyUnreadable`; otherwise an unrelated save deletes an intact credential.
                let suppressKeychainClear = (keyForKeychain == nil && _providerKeyClearSuppressed)
                if suppressKeychainClear {
                    logger.error(
                        "[SECRETS] NOT clearing the Keychain API key for profile '\(displayName)' "
                        + "(id \(id)): a Keychain read FAILED earlier in this session, so a missing key "
                        + "cannot be trusted as the user clearing it — it may come from a form filled "
                        + "while the key was hidden. CONSEQUENCE: the stored credential is preserved and "
                        + "the rest of this save proceeds normally. If the user DID mean to remove the "
                        + "key, that removal is not applied this session: relaunch and clear it again."
                    )
                }

                // `true` in the suppressed case means the blob may be written without the key; the key is safe in the Keychain.
                let storedSecurely = suppressKeychainClear
                    ? true
                    : ProviderKeyStore.save(keyForKeychain, for: id)
                detailsToEncode = storedSecurely ? newValue.settingProviderAPIKey(nil) : newValue
                // A key just written is known, so the display flag clears; the sticky flag stays.
                if keyForKeychain != nil && storedSecurely && !suppressKeychainClear {
                    _providerKeyUnreadable = false
                }
                // `_cachedDetails` keeps the key (the in-memory view); only `configData` is stripped.
                // In the suppressed case memory keeps the existing key so requests stay authenticated; nil if still unreadable.
                detailsToCache = suppressKeychainClear
                    ? newValue.settingProviderAPIKey(_cachedDetails?.providerAPIKey)
                    : newValue
            }

            guard let encoded = Self.encodeDetails(detailsToEncode) else {
                // Leaves `_cachedDetails` and every denormalized column untouched too, so the row never describes one profile
                // and contains another.
                logger.error(
                    "[PERSISTENCE] Refusing to write profile '\(displayName)' (id \(id)): the new "
                    + "configuration could not be encoded. CONSEQUENCE: this edit is DISCARDED and the "
                    + "profile keeps its previously-saved configuration; the UI may show the attempted "
                    + "value until the next fetch."
                )
                return
            }
            _cachedDetails = detailsToCache
            configData = encoded
            // Keep denormalized columns in sync
            switch newValue {
            case .bot:       profileTypeRaw = ProfileType.bot.rawValue
            case .agent:     profileTypeRaw = ProfileType.agent.rawValue
            case .workflow:  profileTypeRaw = ProfileType.workflow.rawValue
            case .imageGen:  profileTypeRaw = ProfileType.imageGen.rawValue
            case .code:      profileTypeRaw = ProfileType.code.rawValue
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
        fileContextStrategy: FileContextStrategy? = nil,
        ownerWorkflowID: UUID? = nil,
        ownerNodeID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.fileContextStrategyRaw = fileContextStrategy?.rawValue
        self.ownerWorkflowID = ownerWorkflowID
        self.ownerNodeID = ownerNodeID

        // Derive discriminator from the details case
        switch details {
        case .bot:       self.profileTypeRaw = ProfileType.bot.rawValue
        case .agent:     self.profileTypeRaw = ProfileType.agent.rawValue
        case .workflow:  self.profileTypeRaw = ProfileType.workflow.rawValue
        case .imageGen:  self.profileTypeRaw = ProfileType.imageGen.rawValue
        case .code:      self.profileTypeRaw = ProfileType.code.rawValue
        }

        let (provider, model) = Self.extractProviderAndModel(from: details)
        self.providerRaw = provider
        self.modelNameRaw = model

        // Same strip-on-write as the `details` setter; `_cachedDetails` keeps the key except on a shared-key provider.
        let detailsToEncode: ProfileDetails
        let detailsToCache: ProfileDetails
        if let account = details.sharedKeyAccount {
            Self.noteDiscardedSharedKey(carriedBy: details, account: account,
                                        profileName: displayName, profileID: id)
            detailsToEncode = details.settingProviderAPIKey(nil)
            detailsToCache = detailsToEncode
        } else if details.isKeylessProvider {
            // Nothing to store for a keyless provider, and a fresh row has no old item to clear.
            detailsToEncode = details.settingProviderAPIKey(nil)
            detailsToCache = detailsToEncode
        } else {
            let storedSecurely = ProviderKeyStore.save(details.providerAPIKey, for: id)
            detailsToEncode = storedSecurely ? details.settingProviderAPIKey(nil) : details
            detailsToCache = details
        }

        if let encoded = Self.encodeDetails(detailsToEncode) {
            self.configData = encoded
            self._cachedDetails = detailsToCache
        } else {
            // A fresh row has no prior bytes to protect, so it stores bytes that cannot decode as anything.
            // `{}` would be mistakable for a valid empty config; the read path flags these bytes instead of trusting them.
            self.configData = Data("PROFILE_ENCODE_FAILED".utf8)
            self._detailsUnreadableReason = .undecodable
            logger.fault(
                "[PERSISTENCE] Profile '\(displayName)' (id \(id)) was created but its configuration "
                + "could not be encoded. CONSEQUENCE: the row is stored UNREADABLE on purpose rather "
                + "than as a plausible-looking blank, so it presents as needing reconfiguration "
                + "instead of silently losing settings the user believes they saved."
            )
        }
    }

    // MARK: - Shared Provider Keys

    /// Whether `details` belongs to a provider whose key lives in a PER-PROFILE Keychain item
    /// (today: OpenAI-compatible) — the one case where leaving it must clear that item.
    static func keepsOwnKey(_ details: ProfileDetails?) -> Bool {
        guard let details, let provider = details.keyProvider else { return false }
        return provider.usesAPIKey && details.sharedKeyAccount == nil
    }

    /// `details` with the shared provider key injected, when its provider has one. Not found or
    /// unreadable → `details` as stored, which carries no key.
    static func injectingSharedKey(into details: ProfileDetails) -> ProfileDetails {
        guard let account = details.sharedKeyAccount,
              case .found(let key) = GlobalProviderKeys.read(account: account) else { return details }
        return details.settingProviderAPIKey(key)
    }

    /// Logs a key that a shared-provider profile was saved carrying and that is not the shared key; it is discarded.
    /// Never writes. Silent otherwise, including when the carried key is the injected shared key.
    static func noteDiscardedSharedKey(carriedBy details: ProfileDetails, account: String,
                                       profileName: String, profileID: UUID) {
        guard let carried = details.providerAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !carried.isEmpty else { return }
        if case .found(let shared) = GlobalProviderKeys.read(account: account), shared == carried { return }
        logger.notice(
            "[GLOBAL_KEYS] Profile '\(profileName)' (id \(profileID)) was saved carrying a '\(account)' key "
            + "that is not the shared one. CONSEQUENCE: it is discarded — profiles never store their own "
            + "key on this provider — and the profile uses the shared key, or none until one is entered "
            + "in the model catalog."
        )
    }

    // MARK: - Denormalization Helpers

    /// Extracts provider and model name from ProfileDetails for denormalized columns.
    private static func extractProviderAndModel(from details: ProfileDetails) -> (provider: String, model: String) {
        switch details {
        case .bot(let config):      return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .agent(let config):    return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .imageGen(let config): return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .code(let config):     return (config.llmConfig.apiProvider.rawValue, config.llmConfig.modelName)
        case .workflow:             return ("", "")
        }
    }

    // MARK: - Encode / Decode Helpers

    // Why: never return a sentinel blob: the setter assigns the result straight into `configData`.
    /// Encodes ProfileDetails to JSON data, or nil when it cannot be encoded; nil means "keep what is on disk".
    /// A failure is logged at `.fault` alongside `assertionFailure`, which is compiled out in release.
    private static func encodeDetails(_ details: ProfileDetails) -> Data? {
        do {
            return try JSONEncoder().encode(details)
        } catch {
            logger.fault(
                "[PERSISTENCE] Failed to ENCODE ProfileDetails: \(error). CONSEQUENCE: the write is "
                + "refused and the previously-stored configuration is left byte-intact — the profile "
                + "keeps working with its saved settings, and this edit is discarded rather than "
                + "destroying them. Non-conforming floats (infinity/NaN) in a numeric setting are the "
                + "likely cause."
            )
            assertionFailure("ProfileDetails encoding should never fail for a valid in-memory value.")
            return nil
        }
    }

    // Why: the blob is opaque to SwiftData, so shape changes surface here at read time; this path must be non-destructive.
    /// Decodes ProfileDetails from JSON data, running schema migrations first.
    /// Returns the value plus the failure reason, if any; callers must propagate it so the placeholder is never written back.
    private static func decodeDetails(from data: Data) -> (details: ProfileDetails, reason: ConfigurationUnreadableReason?) {
        let placeholder = ProfileDetails.bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: ""))
        )

        switch ProfileBlobGate.check(data) {
        case .tooNew(let storedVersion):
            // Data written by a newer build is intact but unreadable here, so the row is refused rather than decoded.
            // Distinct from corruption: reconfiguring would destroy recoverable data, so the only correct action is no change.
            logger.error(
                "[PERSISTENCE] ProfileDetails blob is schemaVersion \(storedVersion) but this build "
                + "understands at most \(ProfileBlobGate.currentVersion) (\(data.count) bytes) — it was "
                + "written by a NEWER version of Devgentic. CONSEQUENCE: not decoded and NOT "
                + "overwritten; a placeholder is shown and the profile is marked unreadable. The data "
                + "is intact — update Devgentic to read it. ⚠️ Reconfiguring this profile on THIS "
                + "build would replace the newer configuration permanently."
            )
            return (placeholder, .writtenByNewerBuild(storedVersion: storedVersion))

        case .unsupported(let storedVersion):
            logger.error(
                "[PERSISTENCE] ProfileDetails blob is schemaVersion \(storedVersion), older than this build's "
                + "\(ProfileBlobGate.currentVersion) (\(data.count) bytes) — it predates the 2026-10-03 format "
                + "reset, and older formats are no longer upgraded. CONSEQUENCE: not decoded and NOT "
                + "overwritten; a placeholder is shown and the profile is marked unreadable. Delete and "
                + "recreate the profile."
            )
            return (placeholder, .undecodable)

        case .decodable:
            do {
                return (try JSONDecoder().decode(ProfileDetails.self, from: data), nil)
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to decode ProfileDetails (\(data.count) bytes): "
                    + "\(error). CONSEQUENCE: a placeholder bot config is returned for display, the stored "
                    + "bytes are NOT overwritten, and this profile is marked unreadable."
                )
                return (placeholder, .undecodable)
            }
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
            fileContextStrategy: fileContextStrategy,
            ownerWorkflowID: ownerWorkflowID,
            ownerNodeID: ownerNodeID
        )
    }
}

// MARK: - BackendProfileSnapshot (Value-type mirror for cross-boundary use)

/// A `Sendable` value-type copy of a `BackendProfile` for use outside SwiftData contexts
/// (for example `AgentConnect`, `BackendOrchestrationService`, ChatOps bridges).
/// Not `Codable`: nothing persists a snapshot; the store writes `ProfileDetails` into `configData`.
struct BackendProfileSnapshot: Identifiable, Hashable, Sendable {
    /// `var` only so `duplicated(as:)` can re-stamp identity on a whole-value copy. Treat as immutable elsewhere:
    /// the store saves and deletes by this key, so reassigning it retargets the write at another row.
    var id: UUID
    var displayName: String
    var lastSelected: Date?
    var details: ProfileDetails

    /// User-selected file context strategy. When nil, resolves to the smart default for the profile type.
    var fileContextStrategy: FileContextStrategy?

    /// Non-nil when this profile is a workflow node's private configuration; see the same-named `BackendProfile` properties.
    /// Carried by `duplicated(as:)`, so an import must re-stamp or clear them.
    var ownerWorkflowID: UUID?
    var ownerNodeID: UUID?

    /// Whether this row belongs to a workflow node rather than the shared profile library.
    var isNodeOwned: Bool { ownerNodeID != nil }

    /// Resolved file context strategy — explicit setting when the profile type can
    /// honor it, otherwise the smart default. A persisted override the type can't
    /// honor (e.g. a legacy bot set to `.stateless`) heals to the default here.
    var resolvedFileContextStrategy: FileContextStrategy {
        FileContextStrategy.resolve(fileContextStrategy, for: profileType)
    }

    var profileType: ProfileType {
        switch details {
        case .bot:       return .bot
        case .agent:     return .agent
        case .workflow:  return .workflow
        case .imageGen:  return .imageGen
        case .code:      return .code
        }
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        lastSelected: Date? = nil,
        details: ProfileDetails,
        fileContextStrategy: FileContextStrategy? = nil,
        ownerWorkflowID: UUID? = nil,
        ownerNodeID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.details = details
        self.fileContextStrategy = fileContextStrategy
        self.ownerWorkflowID = ownerWorkflowID
        self.ownerNodeID = ownerNodeID
    }

    // Why: do not turn this into an explicit field list; a forgotten field silently changes the copy's behavior.
    /// A copy of this profile under a new identity: only the id, name and last-selected date are not carried across.
    /// Copy-by-default, so properties added later are carried automatically.
    func duplicated(as newName: String) -> BackendProfileSnapshot {
        var copy = self
        copy.id = UUID()
        copy.displayName = newName
        copy.lastSelected = nil
        return copy
    }
}
