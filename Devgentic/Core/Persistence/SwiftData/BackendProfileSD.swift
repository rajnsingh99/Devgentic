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
        guard _cachedDetails == nil else { return }
        let outcome = Self.decodeDetails(from: configData)
        // ⚠️ Inject the API key from the Keychain, where it now lives instead of in the blob.
        // Done HERE rather than in the getter so the Keychain is touched once per decode and the
        // result is cached — `details` is read on nearly every render.
        //
        // ⚠️ register B2 — `read`, not `load`. `load` answers nil for BOTH "no key stored" and
        // "the Keychain read failed", and this row's write path treats a nil key as "the user
        // cleared it" and DELETES the item. One locked Keychain therefore turned into permanent
        // credential destruction on the next opportunistic save. The flag below is what stops that.
        let keyOutcome = ProviderKeyStore.read(for: id)
        _providerKeyUnreadable = { if case .failed = keyOutcome { return true } else { return false } }()

        let keychainKey: String? = { if case .found(let k) = keyOutcome { return k } else { return nil } }()

        // The `??` is the migration path: a blob written before the Keychain move still carries its
        // key inline and must keep working until the launch sweep rewrites it. Keychain wins when
        // both exist — it is the newer of the two by construction.
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
    }

    /// Whether the STORED BYTES still carry an inline API key — i.e. this row predates the move to
    /// the Keychain.
    ///
    /// ⚠️ Decodes `configData` directly rather than reading `details`, because `details` injects
    /// the Keychain value and would report `true` for an already-migrated row. This is the only
    /// thing that distinguishes the two, so the migration sweep keys off it.
    var hasInlineAPIKeyInStoredBlob: Bool {
        let decoded = Self.decodeDetails(from: configData).details
        guard let key = decoded.providerAPIKey else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            return _cachedDetails ?? Self.decodeDetails(from: configData).details
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
            if _detailsDecodeFailed, newValue == _cachedDetails {
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

            // ⚠️ Move the key to the Keychain BEFORE encoding, and only strip it from the blob
            // once that write succeeded. Stripping first and failing second would destroy the
            // user's credential; this way the worst case is the pre-existing behaviour (key stays
            // in the blob) rather than a key that exists nowhere.
            let keyForKeychain = newValue.providerAPIKey

            // ⚠️ register B2 — THE GUARD THAT STOPS A READ FAILURE BECOMING A DELETE. When the
            // Keychain could not be read, `details` came back with no key, so an unrelated save
            // (a rename, a capability chip, the thinking auto-heal, the MLX context healer) called
            // `save(nil)` → `delete` and destroyed a credential that was perfectly intact. A nil
            // key is only user intent when we could actually SEE that there was nothing there.
            //
            // Deliberately asymmetric: a nil key with an unreadable Keychain leaves the item
            // alone, while a nil key with a readable one still clears it. Refusing to clear in
            // both cases would break the user's ability to remove a key at all.
            let suppressKeychainClear = (keyForKeychain == nil && _providerKeyUnreadable)
            if suppressKeychainClear {
                logger.error(
                    "[SECRETS] NOT clearing the Keychain API key for profile '\(displayName)' "
                    + "(id \(id)): the key is absent from this write only because the Keychain read "
                    + "FAILED earlier in this session, not because the user cleared it. "
                    + "CONSEQUENCE: the stored credential is preserved and the rest of this save "
                    + "proceeds normally; the profile will keep behaving as unconfigured until the "
                    + "Keychain is readable again."
                )
            }

            // `true` in the suppressed case is correct rather than a fudge: it means "the blob may
            // be written without the key", which is exactly right — the key is not in the blob, it
            // is safe in the Keychain and we are deliberately not touching it.
            let storedSecurely = suppressKeychainClear
                ? true
                : ProviderKeyStore.save(keyForKeychain, for: id)
            let detailsToEncode = storedSecurely ? newValue.settingProviderAPIKey(nil) : newValue

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
            // `_cachedDetails` keeps the key — it is the in-memory view, and every reader
            // expects `details.llmConfig.apiKey` to be usable. Only `configData` is stripped.
            _cachedDetails = newValue
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
        case .code:      self.profileTypeRaw = ProfileType.code.rawValue
        }

        let (provider, model) = Self.extractProviderAndModel(from: details)
        self.providerRaw = provider
        self.modelNameRaw = model

        // ⚠️ Same strip-on-write as the `details` setter — a freshly created profile must not
        // put its key in the blob either. `_cachedDetails` keeps the key for in-memory readers.
        let storedSecurely = ProviderKeyStore.save(details.providerAPIKey, for: id)
        let detailsToEncode = storedSecurely ? details.settingProviderAPIKey(nil) : details

        if let encoded = Self.encodeDetails(detailsToEncode) {
            self.configData = encoded
            self._cachedDetails = details
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

        // Run migration pipeline before decoding.
        switch ProfileMigrator.migrateIfNeeded(data) {
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
                + "understands at most \(ProfileMigrator.currentVersion) (\(data.count) bytes) — it was "
                + "written by a NEWER version of Devgentic. CONSEQUENCE: not decoded and NOT "
                + "overwritten; a placeholder is shown and the profile is marked unreadable. The data "
                + "is intact — update Devgentic to read it. ⚠️ Reconfiguring this profile on THIS "
                + "build would replace the newer configuration permanently."
            )
            return (placeholder, .writtenByNewerBuild(storedVersion: storedVersion))

        case .migrated(let migrated):
            do {
                return (try JSONDecoder().decode(ProfileDetails.self, from: migrated), nil)
            } catch {
                logger.error(
                    "[PERSISTENCE] Failed to decode ProfileDetails after migration (\(data.count) bytes): "
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
            fileContextStrategy: fileContextStrategy
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
        fileContextStrategy: FileContextStrategy? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.lastSelected = lastSelected
        self.details = details
        self.fileContextStrategy = fileContextStrategy
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
