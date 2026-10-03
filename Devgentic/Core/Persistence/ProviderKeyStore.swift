// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
import os

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

    /// How long a failed read is answered from the cache before a fresh fetch asks again.
    static let failedReadRetryInterval: TimeInterval = 60

    /// Process-wide answers, keyed by account (profile id). Same shape as `GlobalProviderKeys`.
    ///
    /// ⚠️ Why it exists: a `BackendProfile` instance caches its own decode, but SwiftData hands out
    /// a NEW instance on every fetch — and the profile list refetches on most changes — so each
    /// OpenAI-compatible profile was read from the Keychain again on every refetch. With the item
    /// unreadable under a changed signature, each of those was a fresh access prompt.
    private enum Entry {
        case found(String)
        case notFound
        case failed(OSStatus, at: Date)
    }
    private static let cache = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Swaps the Keychain backend and empties the cache. Test-only — pass nil to restore the real one.
    static func setStorageForTesting(_ replacement: KeychainAccessing?) {
        storage = replacement ?? SecureKeyStorage()
        discardCache()
    }

    /// Forgets every cached answer, so the next read of each profile asks the Keychain.
    static func discardCache() {
        cache.withLock { $0.removeAll() }
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
        // On failure the item's state is unknown — drop the entry so the next read asks the Keychain.
        cache.withLock { $0[profileID.uuidString] = status == errSecSuccess ? .found(trimmed) : nil }
        guard status == errSecSuccess else {
            // ⚠️ Registers KC-27 + KC-53. This log used to claim the key "stays where it already
            // was" — true only when the profile ALREADY had a key, and false (and understated)
            // on the fresh-profile path, where there is no previous value and the key is stored
            // NOWHERE. State both cases, and name the disclosure-class consequence of the first:
            // a live API key sitting in plaintext in the SwiftData blob is the exact threat model
            // this store exists to close.
            logger.error(
                "[SECRETS] Failed to write the API key for profile \(profileID) to the Keychain "
                + "(\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: the key was NOT stripped "
                + "from the profile blob for this save. Two cases follow: if this profile ALREADY had "
                + "a key, that previous value remains in the SwiftData store in PLAINTEXT — readable "
                + "by any process running as the user, swept into backups — and keeps working until "
                + "the Keychain is writable again; if this is a FIRST key for the profile, it is "
                + "stored NOWHERE and the profile will fail authentication. Either way: unlock the "
                + "Keychain (or re-grant access after an app update changed the code signature) and "
                + "re-save the profile."
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
        guard case .found(let key) = read(for: profileID) else { return nil }
        return key
    }

    /// Reads the API key, distinguishing "none stored" from "the read failed".
    ///
    /// - Parameter bypassingFailedRead: ask the Keychain even when a recent read failed. For
    ///   callers with their own retry policy — a profile's KC-20 re-read and Try Again — so the
    ///   cache never stretches how long a profile stays "unreadable". A found or not-found answer
    ///   is still served from the cache: it cannot have changed without passing through `save` or
    ///   `delete` here.
    static func read(for profileID: UUID, bypassingFailedRead: Bool = false) -> KeychainReadOutcome {
        let account = profileID.uuidString
        switch cache.withLock({ $0[account] }) {
        case .found(let key)?:
            return .found(key)
        case .notFound?:
            return .notFound
        case .failed(let status, let at)?
            where !bypassingFailedRead && Date().timeIntervalSince(at) < failedReadRetryInterval:
            return .failed(status)
        case .failed?, nil:
            break
        }
        // Outside the lock: a read can block for as long as an access prompt stays on screen.
        let outcome = storage.read(service: service, account: account)
        cache.withLock { cache in
            switch outcome {
            case .found(let key):       cache[account] = .found(key)
            case .notFound:             cache[account] = .notFound
            case .failed(let status):   cache[account] = .failed(status, at: Date())
            }
        }
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
        let gone = status == errSecSuccess || status == errSecItemNotFound
        cache.withLock { $0[profileID.uuidString] = gone ? .notFound : nil }
        guard !gone else { return true }

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

    /// The provider whose API key this configuration uses, if the profile type has one.
    var keyProvider: ApiProvider? {
        switch self {
        case .bot(let c):      return c.llmConfig.apiProvider
        case .agent(let c):    return c.llmConfig.apiProvider
        case .code(let c):     return c.llmConfig.apiProvider
        case .imageGen(let c): return c.llmConfig.apiProvider
        case .workflow:        return nil
        }
    }

    /// True when this configuration's provider takes no API key (Ollama, MLX), so the profile has
    /// nothing to read from or write to the Keychain. A workflow has no provider and is NOT keyless
    /// in this sense — it simply has no key path at all (`keyProvider == nil`).
    var isKeylessProvider: Bool {
        keyProvider.map { !$0.usesAPIKey } ?? false
    }

    /// The `GlobalProviderKeys` account holding this configuration's key, or nil when the key is
    /// stored per profile (or the type has none). See `GlobalProviderKeys.isShared`.
    var sharedKeyAccount: String? {
        keyProvider.flatMap(GlobalProviderKeys.account(for:))
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
