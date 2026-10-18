// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderKeyStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

/// Keychain home for cloud-provider API keys, keyed on profile ID.
/// The key is stripped at the persistence seam (`BackendProfileSD`) and injected on read, never stored in the blob.
enum ProviderKeyStore {

    private static let logger = DGLogger(category: "ProviderKeyStore")

    /// Keychain service identifier; changing it orphans every stored key, since items are looked up by (service, account).
    static let service = "com.devgentic.provider"

    /// The storage backend, replaceable so tests can exercise failed Keychain writes and reads.
    /// Mutated only by `setStorageForTesting`; production never reassigns it.
    nonisolated(unsafe) private static var storage: KeychainAccessing = SecureKeyStorage()

    /// How long a failed read is answered from the cache before a fresh fetch asks again.
    static let failedReadRetryInterval: TimeInterval = 60

    // Why: SwiftData hands out a new profile instance per fetch, so without this every refetch re-reads the Keychain.
    /// Process-wide answers keyed by account (profile id); same shape as `GlobalProviderKeys`.
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
            // Report the real outcome: a failed delete that reads as a successful clear lets the surviving Keychain item
            // be re-injected into the profile on the next read.
            return delete(for: profileID, reason: .keyCleared)
        }

        let status = storage.save(value: trimmed, service: service, account: profileID.uuidString)
        // On failure the item's state is unknown — drop the entry so the next read asks the Keychain.
        cache.withLock { $0[profileID.uuidString] = status == errSecSuccess ? .found(trimmed) : nil }
        guard status == errSecSuccess else {
            // State both cases: with an existing key it stays where it was, on a fresh profile it is stored nowhere.
            // Name the consequence: a live API key in plaintext in the SwiftData blob is the threat this store exists to close.
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

    /// Reads the API key for a profile, or nil when none is stored or the read failed.
    /// Only for callers that need a value to send; anything that writes based on the answer must use `read(for:)`.
    static func load(for profileID: UUID) -> String? {
        guard case .found(let key) = read(for: profileID) else { return nil }
        return key
    }

    /// Reads the API key, distinguishing "none stored" from "the read failed".
    /// - Parameter bypassingFailedRead: ask the Keychain even when a recent read failed, for callers that retry themselves.
    /// Found and not-found answers are still served from the cache, since they change only through `save` or `delete`.
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

    /// Removes a profile's key, when the profile is deleted or the user clears the field.
    /// - Returns: whether the Keychain now lacks the item (`errSecItemNotFound` counts as success).
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

    /// Whether this profile type has a system-instructions field at all.
    /// Distinct from an empty field: `.imageGen` and `.workflow` have none, so nil must not raise a guidance advisory.
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
    /// Used both to strip before encoding and to re-inject after decoding, so both halves act on the same field.
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
