// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

private let logger = DGLogger(category: "BackendProfileSD")

/// Why a profile's stored configuration could not be read.
///
/// ⚠️ These demand OPPOSITE responses from the user, which is why the distinction has to survive all
/// the way to the UI rather than dying in a log line (register G18). `.undecodable` means the bytes
/// are damaged — reconfiguring is the only way forward. `.writtenByNewerBuild` means the bytes are
/// perfectly intact and merely unreadable by THIS build — reconfiguring is the one action that
/// destroys them. Presenting both with the same "Discard and Reconfigure" affordance invites the user
/// to delete recoverable data.
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

    /// Non-nil when this row is a workflow NODE's private configuration rather than a shared profile.
    ///
    /// ⚠️ These two fields are what make a workflow node's settings workflow-scoped. A node still
    /// references a profile by UUID exactly as before; what changed is that the row it points at can
    /// be owned by that node — created fresh or duplicated on import — instead of being a profile the
    /// user also runs in chat. Editing such a row affects nothing outside its workflow.
    ///
    /// ⚠️ THE TWO IDS DO DIFFERENT JOBS, and neither is "scoping the reconcile" — an earlier
    /// version of this comment said `ownerNodeID` did that, which is the exact rule
    /// `BackendProfileService.reconcileOwnedProfiles` documents as a LEAK and refuses to use.
    ///
    /// `ownerWorkflowID` is what both the save-time reconcile and the workflow-delete cascade key
    /// on, via `BackendProfileStore.fetchOwnedProfiles(forWorkflow:)` — which is why it exists:
    /// finding a workflow's private rows without loading and decoding every layout blob.
    ///
    /// `ownerNodeID` is the ownership MARKER (`isNodeOwned` is a nil-check on it) and the key for
    /// the one-node-per-row aliasing tripwire in `WorkflowCanvasState.addNode`. Survival is decided
    /// by whether a node REFERENCES the row, never by whether this id names a live node.
    ///
    /// ⚠️ An owned row must never appear anywhere a shared profile is offered — sidebar, composer
    /// picker, QuickAccess, scheduler, ChatOps routing. Filter through
    /// `BackendProfileService.sharedProfiles`, never by re-deriving the test at each call site.
    /// `profiles` itself stays unfiltered: the executor and the node inspector resolve owned rows
    /// by id and must keep finding them.
    var ownerWorkflowID: UUID?
    var ownerNodeID: UUID?

    /// JSON-encoded `ProfileDetails` blob. This is the single source of truth for
    /// the type-specific configuration (Bot, Agent, Workflow, ImageGen).
    var configData: Data

    // MARK: - Transient Cache

    /// In-memory cache so we don't re-decode on every property access.
    @Transient
    private var _cachedDetails: ProfileDetails?

    /// True when `configData` could not be decoded and `_cachedDetails` is therefore a
    /// PLACEHOLDER rather than the user's real configuration.
    ///
    /// ⚠️ This flag is what stops a read failure from becoming a write failure. Without it, an
    /// undecodable blob decoded to a blank bot, the blank bot was cached, and the next
    /// `saveProfile` — including the opportunistic ones that fire without any user edit — encoded
    /// that blank bot straight back over the user's model choice, API key, instructions and
    /// enabled-tool list. Transient, so it never participates in the schema.
    @Transient
    private var _detailsUnreadableReason: ConfigurationUnreadableReason?

    /// Unchanged meaning, now derived — every existing guard reads this and keeps working.
    private var _detailsDecodeFailed: Bool { _detailsUnreadableReason != nil }

    /// Whether the last Keychain read for this profile FAILED, as opposed to finding nothing.
    /// Register B2.
    ///
    /// ⚠️ This exists solely to stop a read failure being mistaken for user intent. When it is
    /// true, `details` carries no API key — but that absence is OUR failure, not the user's
    /// choice, so the setter must not act on it by deleting the stored credential.
    @Transient
    private var _providerKeyUnreadable: Bool = false

    /// Whether ANY Keychain read for this instance has failed this session. Register KC-20.
    ///
    /// ⚠️ STICKY, and deliberately separate from `_providerKeyUnreadable`, which a later successful
    /// read clears. The setter's clear-suppression must NOT follow that recovery: the profile
    /// editor holds a draft snapshotted while the key was unreadable (so its key is nil), and
    /// saving that stale draft after a recovery — a rename, a capability toggle — would read as
    /// "the user cleared the key" and delete a credential that was fine all along. The cost is the
    /// narrow case of a user genuinely clearing a key after a recovered failure in the same
    /// session: the clear is logged as not taken and applies after relaunch.
    @Transient
    private var _providerKeyClearSuppressed: Bool = false

    /// When the Keychain was last asked for this profile's key. Throttles the KC-20 re-read —
    /// `details` is read on nearly every render, and each read of a locked or ACL-pending item can
    /// raise a system prompt, so an unthrottled retry would re-prompt continuously.
    @Transient
    private var _providerKeyLastReadAttempt: Date?

    /// Minimum spacing between automatic re-reads of an unreadable key. Register KC-20.
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

    /// The rich, type-safe configuration envelope.
    /// Reading decodes from `configData` (with caching); writing re-encodes.
    /// True when `configData` could not be decoded, so `details` is a placeholder and the stored
    /// bytes are being preserved rather than overwritten. Surface this in the UI instead of
    /// presenting the placeholder as if it were the user's configuration.
    var hasUnreadableConfiguration: Bool {
        primeDecodeState()
        return _detailsDecodeFailed
    }

    /// WHY the configuration could not be read — the two cases need opposite responses from the user,
    /// so collapsing them to a bool was the reason G18's refusal could not reach the UI.
    var configurationUnreadableReason: ConfigurationUnreadableReason? {
        primeDecodeState()
        return _detailsUnreadableReason
    }

    /// Brings `_cachedDetails` / `_detailsDecodeFailed` into agreement with the CURRENT stored bytes.
    ///
    /// ⚠️ Every accessor that consults `_detailsDecodeFailed` must call this first, the setter
    /// included. The flag is `@Transient` and so defaults to `false` on every freshly materialized
    /// instance; a guard reading it raw is correct only when something already ran the getter on that
    /// same instance. Today the opportunistic savers do read `details` before writing it, so the
    /// refusal happens to work — but it works BY ACCIDENT of access order, and the sibling
    /// `WorkflowLayoutSD` guard was genuinely bypassed for exactly this reason
    /// (`WorkflowLayoutStore.save` assigns without reading). Priming makes the refusal a function of
    /// what is on disk instead.
    ///
    /// Idempotent: `_cachedDetails` is non-nil after the first call, after `init`, and after any set.
    private func primeDecodeState() {
        guard _cachedDetails == nil else {
            // ⚠️ Register KC-20. Before this, a failed first read was cached for the instance's
            // whole lifetime — the "until the Keychain is readable again" promise in the setter's
            // log had no code behind it, because nothing ever looked again.
            if _providerKeyUnreadable { rereadProviderKey(force: false) }
            return
        }
        let outcome = Self.decodeDetails(from: configData)
        // ⚠️ A shared-key provider has no per-profile item to read: its key is injected by the
        // `details` getter from `GlobalProviderKeys`, which caches it for the process. Reading here
        // as well is what made every fetch decrypt every profile's key again. A workflow has no key,
        // and a keyless provider (Ollama, MLX) never sends one — reading for it was a lookup on
        // every fetch and render that could only ever answer "not found".
        guard outcome.details.keyProvider != nil,
              outcome.details.sharedKeyAccount == nil,
              !outcome.details.isKeylessProvider else {
            _cachedDetails = outcome.details
            _detailsUnreadableReason = outcome.reason
            return
        }
        // ⚠️ Inject the API key from the Keychain, where it now lives instead of in the blob.
        // Done HERE rather than in the getter so the Keychain is touched once per decode and the
        // result is cached — `details` is read on nearly every render.
        //
        // ⚠️ register B2 — `read`, not `load`. `load` answers nil for BOTH "no key stored" and
        // "the Keychain read failed", and this row's write path treats a nil key as "the user
        // cleared it" and DELETES the item. One locked Keychain therefore turned into permanent
        // credential destruction on the next opportunistic save. The flag below is what stops that.
        let keyOutcome = ProviderKeyStore.read(for: id)
        _providerKeyLastReadAttempt = Date()
        _providerKeyUnreadable = { if case .failed = keyOutcome { return true } else { return false } }()
        if _providerKeyUnreadable { _providerKeyClearSuppressed = true }

        let keychainKey: String? = { if case .found(let k) = keyOutcome { return k } else { return nil } }()

        // The `??` is the write-failure path: when the Keychain write failed, the setter left the key
        // inline rather than destroy it, and it must keep working until a later save moves it.
        // Keychain wins when both exist — it is the newer of the two by construction.
        _cachedDetails = outcome.details.settingProviderAPIKey(
            keychainKey ?? outcome.details.providerAPIKey
        )
        _detailsUnreadableReason = outcome.reason
    }

    /// Drops the decode cache so the next `details` read re-primes from `configData`.
    ///
    /// ⚠️ TEST SEAM. Production code never needs it — the cache is populated on init and on every
    /// set — but a test that writes `configData` directly (to reproduce a legacy blob) has no
    /// other way to make the getter observe those bytes.
    func resetDecodeCacheForTesting() {
        _cachedDetails = nil
        _detailsUnreadableReason = nil
        _providerKeyUnreadable = false
        _providerKeyClearSuppressed = false
        _providerKeyLastReadAttempt = nil
    }

    /// Whether this profile's API key is stored but could not be read from the Keychain right now
    /// — locked, or an access prompt denied or still pending (typically right after an update
    /// re-signs the app). Register KC-22: without this, that state rendered exactly like a profile
    /// that was never given a key, and the user's natural fix was to paste the key again.
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

    /// Re-reads ONLY the key — the blob decode is unaffected by Keychain state and stays cached.
    /// Register KC-20.
    ///
    /// ⚠️ Found → the Keychain value replaces the cached key (Keychain wins, as in the first prime).
    /// Not found → the flag clears and the cached key is left alone: an inline legacy key, if any,
    /// is still the right fallback. Failed → nothing changes except the throttle timestamp.
    /// `_providerKeyClearSuppressed` is NEVER cleared here — see its declaration.
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

    /// ⚠️ TEST SEAM for the KC-20 throttle: makes the next `details` read eligible to re-read the
    /// key without waiting out `providerKeyRetryInterval`.
    func expireProviderKeyRetryThrottleForTesting() {
        _providerKeyLastReadAttempt = nil
    }

    /// Explicitly discards an unreadable configuration and replaces it.
    ///
    /// The sanctioned way past the refusal, mirroring `WorkflowLayoutSD.replaceUnreadableLayout`.
    /// Separate and awkwardly named on purpose: today the ONLY way to clear the flag is to assign a
    /// value that differs from the placeholder — which is exactly what a user idly editing a
    /// blank-looking profile does, so destruction is currently reachable by accident. This makes it a
    /// named, logged, deliberate act instead.
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
            // ⚠️ Load-bearing, not defensive — see `primeDecodeState()`.
            primeDecodeState()
            // ⚠️ REFUSE to overwrite bytes we could not read.
            //
            // When the decode failed we handed the caller a placeholder. If that same placeholder
            // comes back, this is an opportunistic save (ToolLibraryContainerView,
            // CodeSessionManager, MLXContextWindowHealer all call saveProfile without the user
            // editing anything) and writing it would destroy the original configuration
            // permanently. A genuine user edit produces a DIFFERENT value and is allowed through.
            // Compared against what the GETTER handed out — it injects the shared key, so the raw
            // cache would never equal a placeholder coming back and the refusal would not fire.
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
                // ⚠️ ONE KEY PER PROVIDER. The key is not this profile's to write or delete — every
                // profile on the provider shares it, and it is set only in the model catalog or the
                // Code model picker — so a save just strips it and never touches the Keychain. The
                // B2 / KC-20 guards below therefore have nothing to protect on this path: no save,
                // opportunistic or stale, can destroy or replace the shared key from here.
                Self.noteDiscardedSharedKey(carriedBy: newValue, account: account,
                                            profileName: displayName, profileID: id)
                detailsToEncode = newValue.settingProviderAPIKey(nil)
                // The getter injects the shared key, so the cache holds the stripped value.
                detailsToCache = detailsToEncode
            } else if newValue.isKeylessProvider, !Self.keepsOwnKey(_cachedDetails) {
                // A keyless provider (Ollama, MLX) has nothing to store, so a save never touches the
                // Keychain — it used to DELETE a per-profile item on every save that could never
                // exist. Any key the value carries (a provider switch left it behind) is dropped.
                // ⚠️ Gated on the PREVIOUS value too: a profile switching here FROM a provider that
                // keeps its own key takes the branch below instead, which clears that old item under
                // the B2 / KC-20 guards rather than orphaning it.
                detailsToEncode = newValue.settingProviderAPIKey(nil)
                detailsToCache = detailsToEncode
            } else {
                // ⚠️ Move the key to the Keychain BEFORE encoding, and only strip it from the blob
                // once that write succeeded. Stripping first and failing second would destroy the
                // user's credential; this way the worst case is the pre-existing behaviour (key stays
                // in the blob) rather than a key that exists nowhere.
                // A keyless provider reaches here only when LEAVING a provider that kept its own
                // key — nil clears that old item.
                let keyForKeychain = newValue.isKeylessProvider ? nil : newValue.providerAPIKey

                // ⚠️ register B2 — THE GUARD THAT STOPS A READ FAILURE BECOMING A DELETE. When the
                // Keychain could not be read, `details` came back with no key, so an unrelated save
                // (a rename, a capability chip, the thinking auto-heal, the MLX context healer) called
                // `save(nil)` → `delete` and destroyed a credential that was perfectly intact. A nil
                // key is only user intent when we could actually SEE that there was nothing there.
                //
                // Deliberately asymmetric: a nil key with an unreadable Keychain leaves the item
                // alone, while a nil key with a readable one still clears it. Refusing to clear in
                // both cases would break the user's ability to remove a key at all.
                // ⚠️ The STICKY flag, not `_providerKeyUnreadable` — a recovery since the failure does
                // not make a draft snapshotted during it trustworthy (register KC-20).
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

                // `true` in the suppressed case is correct rather than a fudge: it means "the blob may
                // be written without the key", which is exactly right — the key is not in the blob, it
                // is safe in the Keychain and we are deliberately not touching it.
                let storedSecurely = suppressKeychainClear
                    ? true
                    : ProviderKeyStore.save(keyForKeychain, for: id)
                detailsToEncode = storedSecurely ? newValue.settingProviderAPIKey(nil) : newValue
                // A key just WRITTEN is a key we know — the banner must not keep saying "unreadable"
                // until the next throttled re-read. Display flag only; the sticky one stays (KC-20).
                if keyForKeychain != nil && storedSecurely && !suppressKeychainClear {
                    _providerKeyUnreadable = false
                }
                // `_cachedDetails` keeps the key — it is the in-memory view, and every reader
                // expects `details.llmConfig.apiKey` to be usable. Only `configData` is stripped.
                // ⚠️ In the suppressed case the Keychain still holds the key, so memory must too —
                // caching the key-less value would send every later request unauthenticated while the
                // credential sat intact and readable (register KC-20). Nil if it is still unreadable.
                detailsToCache = suppressKeychainClear
                    ? newValue.settingProviderAPIKey(_cachedDetails?.providerAPIKey)
                    : newValue
            }

            guard let encoded = Self.encodeDetails(detailsToEncode) else {
                // ⚠️ Deliberately leaves `_cachedDetails` and every denormalized column untouched
                // too. A half-applied write — new provider/model columns beside the OLD blob — would
                // be worse than no write: the row would describe one profile and contain another,
                // and nothing downstream could tell.
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

        // ⚠️ Same strip-on-write as the `details` setter — a freshly created profile must not
        // put its key in the blob either. `_cachedDetails` keeps the key for in-memory readers,
        // except on a shared-key provider, where the getter injects it.
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
            // A fresh row has no prior bytes to protect, so refusal is not an option here — but the
            // stored value must never be mistakable for a valid empty config. `{}` would be: it is
            // well-formed JSON, and a future `ProfileDetails` with all-optional fields could decode
            // it cleanly into a blank profile (exactly the shape that made G22 undetectable). These
            // bytes cannot decode as anything, so the read path flags the row instead of trusting it.
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

    /// Logs a key a shared-provider profile was saved carrying that is not the shared key — it is
    /// about to be discarded. Never writes: shared keys are set only in the model catalog and the
    /// Code model picker. Silent otherwise, including for the common case of carrying the shared
    /// key itself (the getter injected it).
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

    /// Encodes ProfileDetails to JSON data, or `nil` when it cannot be encoded.
    ///
    /// ⚠️ This returned `Data("{}".utf8)` on failure, while its own doc comment warned that such a
    /// fallback "would silently destroy the user's profile data on the next read" and its log line
    /// claimed it was "refusing to write corrupt data". It was doing neither: the setter assigns the
    /// return value straight into `configData`, so an encode failure REPLACED a working profile —
    /// model, provider, instructions, enabled tools, capabilities — with two bytes. The comment
    /// described the hazard, the log denied it, and the code performed it.
    ///
    /// Now the refusal is real: `nil` means "keep what is on disk". Optional rather than a sentinel
    /// blob because a sentinel is just another value the caller can write, and this whole class of
    /// bug comes from a caller writing something it should not have.
    ///
    /// ⚠️ `assertionFailure` alone was not a safety net — it is compiled out in release, so the very
    /// build where this matters got the silent destruction. Paired with a `.fault` log, per the
    /// project rule that a stripped assert must never be the only record of an invariant.
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

    /// Decodes ProfileDetails from JSON data, running schema migrations first.
    ///
    /// Returns the decoded value plus whether the decode FAILED. The caller must propagate
    /// `didFail`: the placeholder returned on failure is safe to display but must never be
    /// written back over `configData` (see the `details` setter).
    ///
    /// ⚠️ The blob is opaque to SwiftData, so a shape change inside `ProfileDetails` — adding a
    /// non-optional field to `Tool`, say — is invisible to schema migration and lands here at
    /// READ time, on a store that opened perfectly. That is why this path has to be
    /// non-destructive rather than merely non-crashing.
    private static func decodeDetails(from data: Data) -> (details: ProfileDetails, reason: ConfigurationUnreadableReason?) {
        let placeholder = ProfileDetails.bot(
            BotConfig(llmConfig: ProviderConfig(apiProvider: .ollama, modelName: ""))
        )

        switch ProfileBlobGate.check(data) {
        case .tooNew(let storedVersion):
            // ⚠️ Written by a NEWER build (register G18). Distinguished from corruption ON PURPOSE:
            // the remedies are opposite. Corrupt data invites the user to reconfigure the profile,
            // which overwrites the blob and makes the loss permanent. This data is INTACT — it just
            // needs a build that understands it — so the only correct action is to change nothing.
            //
            // Refusing here rather than attempting the decode also keeps the reason in the log. The
            // old code fell through to a generic decode failure, which reported "corrupt" for a file
            // that was perfectly well-formed.
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
/// (e.g., passing to `AgentConnect`, `BackendOrchestrationService`, ChatOps bridges).
///
/// ⚠️ **Deliberately NOT `Codable` any more** (removed 2026-08-06 with the profile import/export
/// feature, register G93/G97). It was `Codable` for exactly one reason — it WAS the on-disk export
/// format that `ProfileExporter` wrote to the user's JSON — and that feature is gone. Both the app
/// and test targets compile without the conformance, which is how the claim was checked rather than
/// assumed.
///
/// Do not re-add it casually. A `Codable` conformance on a type that reaches disk is a promise about
/// field names and shapes, and this type is edited freely — it gains and loses properties as the UI
/// does. Nothing persists a snapshot today: the store writes `ProfileDetails` into
/// `BackendProfileSD.configData`, a different type with its own versioned codec. `Hashable` DOES
/// stay load-bearing — `ProfileEditBuffer.isDirty` is `draft != original`.
struct BackendProfileSnapshot: Identifiable, Hashable, Sendable {
    /// ⚠️ `var` rather than `let` for exactly ONE reason: `duplicated(as:)` needs to re-stamp
    /// identity on a whole-value copy, which is what makes duplication carry future properties for
    /// free (register A31). Treat it as immutable everywhere else — this is the key the store saves
    /// and deletes by, and reassigning it on a live snapshot retargets that write at another row.
    var id: UUID
    var displayName: String
    var lastSelected: Date?
    var details: ProfileDetails

    /// User-selected file context strategy. When nil, resolves to the smart default for the profile type.
    var fileContextStrategy: FileContextStrategy?

    /// Non-nil when this profile is a workflow node's private configuration — see the same-named
    /// properties on `BackendProfile` for the full contract.
    ///
    /// ⚠️ Carried by `duplicated(as:)` for free, like every other property. An import must therefore
    /// RE-STAMP them for the new owner (or clear them, for a copy that is becoming a shared profile).
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

    /// A copy of this profile under a new identity — everything is carried across except the
    /// three things that are *about* this particular row: its id, its name, and when it was last
    /// selected (a copy has never been used).
    ///
    /// ⚠️ Exists so duplication is **copy-by-default** rather than list-the-fields (register A31).
    /// `DuplicateProfileSheet` built its copy by calling the memberwise init with four arguments,
    /// and every parameter here has a default — so `fileContextStrategy` was quietly omitted and
    /// the copy came out `nil`. That is not a cosmetic loss: `resolve(nil, for: .agent)` returns
    /// `.stateless`, so duplicating an agent explicitly set to `.directInjection` produced a copy
    /// that hands the model file PATHS where the original handed it file CONTENT — the same
    /// prompt, a different answer, with nothing on screen to explain it.
    ///
    /// ⚠️ Any property added to this struct is carried by this method for free. Do not "fix" it
    /// back into an explicit field list: the next property added would be dropped exactly the same
    /// way, and it would be just as silent.
    func duplicated(as newName: String) -> BackendProfileSnapshot {
        var copy = self
        copy.id = UUID()
        copy.displayName = newName
        copy.lastSelected = nil
        return copy
    }
}
