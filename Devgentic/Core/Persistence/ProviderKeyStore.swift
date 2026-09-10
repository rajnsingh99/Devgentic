// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProviderKeyStore.swift
//  Devgentic
//
//  Created on 07/08/26.
//
//  Keychain home for cloud-provider API keys, keyed on profile ID.
//
//  ⚠️ WHY THIS EXISTS. Every cloud key used to be persisted VERBATIM inside the SwiftData
//  `configData` blob — `ProviderConfig.encode(to:)` wrote `apiKey` like any other field, so
//  `strings ~/Library/Application\ Support/DevgenticSD.store | grep sk-ant` returned the live key.
//  The app is not sandboxed, so that file (plus its `-wal`/`-shm` siblings) is readable by any
//  process running as the user, and it is swept up by Time Machine, iCloud Drive, Dropbox and any
//  log-collection or crash-reporting tool that grabs Application Support.
//
//  ⚠️ THE KEY IS STRIPPED AT THE PERSISTENCE SEAM, NOT IN `ProviderConfig.encode(to:)`. That was
//  deliberate: `ProviderConfig` is a value type with no idea which profile owns it, so a Keychain
//  round-trip inside its `Codable` conformance has nothing to key on. `BackendProfileSD` does know
//  the profile id, so the strip-on-write / inject-on-read pair lives there and `ProviderConfig`
//  stays an honest, fully round-trippable value — which matters because it is also encoded into
//  in-memory snapshots that legitimately carry the key.
//
//  Mirrors `MCPSecretStore`'s shape. Keys are scoped per profile, so two profiles on the same
//  provider can hold different credentials — which the old provider-scoped guesses could not.
//

import Foundation

enum ProviderKeyStore {

    private static let logger = DGLogger(category: "ProviderKeyStore")

    /// Keychain service identifier. ⚠️ Changing this orphans every stored key — existing items are
    /// looked up by (service, account) and nothing migrates them.
    static let service = "com.devgentic.provider"

    /// ⚠️ TEST SEAM (registers B2 / UNTESTED-12). This was `private static let SecureKeyStorage()`,
    /// which meant the failure branches — a Keychain write that fails, and a READ that fails —
    /// could not be exercised at all, so the load-bearing "strip only if the write succeeded" and
    /// "never delete on a failed read" rules were asserted by comment alone. Mutated only by
    /// `setStorageForTesting`; production never reassigns it.
    nonisolated(unsafe) private static var storage: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setStorageForTesting(_ replacement: KeychainAccessing?) {
        storage = replacement ?? SecureKeyStorage()
    }

    // MARK: - API

    /// Stores (or clears, when `key` is nil/blank) the API key for a profile.
    /// - Returns: whether the Keychain write succeeded. Callers must not strip the key from the
    ///   blob when this returns `false` — see `BackendProfileSD.details`.
    @discardableResult
    static func save(_ key: String?, for profileID: UUID) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            // ⚠️ register B19 — this used to `delete(for:)` and hardcode `return true`, because
            // `delete` was `Void` and swallowed its own `OSStatus`. So a FAILED delete was
            // reported to the caller as a successful clear: the blob was written with no key, the
            // Keychain item survived, and `primeDecodeState` re-injected the supposedly-removed
            // credential on the very next read. A user who cleared a revoked key watched it come
            // back and get sent on every request.
            return delete(for: profileID, reason: .keyCleared)
        }

        let status = storage.save(value: trimmed, service: service, account: profileID.uuidString)
        guard status == errSecSuccess else {
            logger.error(
                "[SECRETS] Failed to write the API key for profile \(profileID) to the Keychain "
                + "(OSStatus \(status)). CONSEQUENCE: the key is NOT stripped from the profile blob "
                + "for this save — it stays where it already was rather than being lost."
            )
            return false
        }
        return true
    }

    /// Reads the API key for a profile, or nil when none is stored **or the read failed**.
    ///
    /// ⚠️ Only for callers that merely need a value to send. Anything that WRITES based on the
    /// answer must use `read(for:)` — see register B2.
    static func load(for profileID: UUID) -> String? {
        guard case .found(let key) = storage.read(service: service, account: profileID.uuidString) else {
            return nil
        }
        return key
    }

    /// Reads the API key, distinguishing "none stored" from "the read failed".
    static func read(for profileID: UUID) -> KeychainReadOutcome {
        let outcome = storage.read(service: service, account: profileID.uuidString)
        if case .failed(let status) = outcome {
            logger.error(
                "[SECRETS] Could not read the Keychain API key for profile \(profileID) "
                + "(OSStatus \(status)) — this is NOT the same as the profile having no key. "
                + "CONSEQUENCE: the credential is left untouched and will not be stripped or "
                + "deleted by this session's saves; the profile will behave as unconfigured until "
                + "the Keychain is readable again (typically: unlock it, or re-grant access after "
                + "an app update changed the code signature)."
            )
        }
        return outcome
    }

    /// Why a key is being removed. Drives the log line's CONSEQUENCE, which is genuinely different
    /// per caller — the same message served both and was wrong for one of them.
    enum DeletionReason {
        /// The owning profile is being deleted.
        case profileDeleted
        /// The user cleared the API key field on a profile that still exists.
        case keyCleared
    }

    /// Removes a profile's key. Called when the profile is deleted, so a key cannot outlive the
    /// thing that owned it — and when the user clears the field.
    ///
    /// - Returns: whether the Keychain no longer holds the item (`errSecItemNotFound` counts as
    ///   success — the desired end state is "gone", not "we did the deleting").
    @discardableResult
    static func delete(for profileID: UUID, reason: DeletionReason = .profileDeleted) -> Bool {
        let status = storage.delete(service: service, account: profileID.uuidString)
        guard status != errSecSuccess && status != errSecItemNotFound else { return true }

        switch reason {
        case .profileDeleted:
            logger.error(
                "[SECRETS] Failed to delete the Keychain API key for profile \(profileID) "
                + "(OSStatus \(status)). CONSEQUENCE: an orphaned credential remains in the "
                + "Keychain after the profile was removed."
            )
        case .keyCleared:
            logger.error(
                "[SECRETS] Failed to remove the Keychain API key for profile \(profileID) after "
                + "the user cleared it (OSStatus \(status)). CONSEQUENCE: the profile blob will be "
                + "written with no key but the OLD credential is still in the Keychain, so the "
                + "next read RE-INJECTS it and it keeps being sent — the clear did not take."
            )
        }
        return false
    }

    // MARK: - Legacy plaintext cleanup (register A53)

    /// `UserDefaults` keys that earlier builds wrote a raw provider credential into, and which
    /// nothing reads.
    ///
    /// ⚠️ **Membership here requires that the key has NO reader.** `gemini_api_key` qualifies:
    /// `GeminiService` wrote it on every successful model-list fetch and its `getApiKey` /
    /// `clearApiKey` accessors had zero callers repo-wide, so removing it cannot break anything.
    /// A key that is still read back must NOT be added — it needs migrating to the Keychain
    /// first, then purging. In particular `webSearchAPIKey` is a live setting with a real reader
    /// (`SettingsCoordinator`) and is deliberately absent: deleting it would disable web search.
    private static let legacyPlaintextDefaultsKeys = ["gemini_api_key"]

    /// Removes credentials earlier builds left in `~/Library/Preferences/`.
    ///
    /// ⚠️ Deleting the WRITE is not enough. A profile whose key was validated by any prior build
    /// already has the plaintext value on disk, where no UI can reach it — it survives deleting
    /// the profile, rotating the key, and every later launch. Same lesson as the v7 blob repair
    /// (registers A11/A12): a corrected write site does not fix data already written.
    ///
    /// Idempotent and self-limiting: it logs only when something was actually removed, so it is
    /// safe to run on every launch and needs no migration flag of its own.
    static func purgeLegacyPlaintextKeys(defaults: UserDefaults = .standard) {
        for key in legacyPlaintextDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            logger.notice(
                "[SECRETS] Removed a legacy plaintext credential from UserDefaults ('\(key)'). "
                + "CONSEQUENCE: the copy an earlier build left in ~/Library/Preferences/ is gone; "
                + "the live key is unaffected — it lives in the Keychain, keyed on profile id."
            )
        }
    }
}

// MARK: - ProfileDetails key access

extension ProfileDetails {

    /// Whether this profile type has a system-instructions field at all. Register B14.
    ///
    /// ⚠️ Distinct from "the field is empty", and the difference decides whether an advisory is
    /// truthful: `.imageGen` and `.workflow` have no instructions to be missing, so treating their
    /// `nil` as "no guidance configured" would banner on every image-generation send. Matches the
    /// two arms `ProfileValidator` actually enforces the rule on.
    var supportsSystemInstructions: Bool {
        switch self {
        case .bot, .agent:              return true
        case .code, .imageGen, .workflow: return false
        }
    }

    /// The configured system instructions, or nil when unset or unsupported.
    var systemInstructions: String? {
        switch self {
        case .bot(let c):   return c.instructions
        case .agent(let c): return c.instructions
        case .code(let c):  return c.instructions
        case .imageGen, .workflow: return nil
        }
    }

    /// The provider API key carried by this configuration, if the profile type has one.
    /// `.workflow` has no `llmConfig` — it composes other profiles, each with their own.
    var providerAPIKey: String? {
        switch self {
        case .bot(let c):      return c.llmConfig.apiKey
        case .agent(let c):    return c.llmConfig.apiKey
        case .code(let c):     return c.llmConfig.apiKey
        case .imageGen(let c): return c.llmConfig.apiKey
        case .workflow:        return nil
        }
    }

    /// Returns a copy with the provider API key replaced (or removed, when nil).
    ///
    /// ⚠️ Used in both directions: with `nil` to strip before encoding, and with the Keychain value
    /// to re-inject after decoding. Keeping it one function means the two halves cannot disagree
    /// about which field they operate on.
    func settingProviderAPIKey(_ key: String?) -> ProfileDetails {
        switch self {
        case .bot(var c):      c.llmConfig.apiKey = key; return .bot(c)
        case .agent(var c):    c.llmConfig.apiKey = key; return .agent(c)
        case .code(var c):     c.llmConfig.apiKey = key; return .code(c)
        case .imageGen(var c): c.llmConfig.apiKey = key; return .imageGen(c)
        case .workflow:        return self
        }
    }
}
