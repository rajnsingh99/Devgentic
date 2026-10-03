// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AppProviderKeyStore.swift
//  Devgentic
//
//  Global Keychain storage for remote provider API keys across the app's lifetime.
//  Once a user supplies an API key for a provider (e.g. Anthropic, OpenAI, Hugging Face,
//  Google Gemini, OpenRouter), it is stored securely and reused across all profiles.
//
//  ⚠️ ONE KEY PER PROVIDER (2026-10-03). For OpenAI, Anthropic, Google and OpenRouter this is the
//  ONLY home of the key: profiles carry it in memory (injected by `BackendProfile.details`) and never
//  store a copy. It used to be copied into every profile (`ProviderKeyStore`, keyed by profile id)
//  and again into a Code-mode slot, so one OpenRouter key became several Keychain items — one access
//  prompt each whenever the app's signature changed — and replacing the key here left stale copies
//  in the profiles, which kept sending the old one. `.openAICompatible` stays per profile: each such
//  profile can point at a different server with its own credential.
//

import Foundation
import os
import Security
import SwiftUI

private let logger = DGLogger(category: "AppProviderKeyStore")

/// The Keychain core of the global provider keys: thread-safe, cached, and usable from any
/// isolation — `BackendProfile.details` reads it from SwiftData model code, not the main actor.
///
/// ⚠️ CACHED FOR THE PROCESS. Every profile fetch and every view render used to decrypt the key
/// again (one launch read the same item 7 times from 6 callers; a single screen visit read the
/// global key 5 times from a view body). Each read of an item whose ACL no longer matches the app
/// is a separate access prompt, and each one blocks the calling thread — the main thread, for every
/// caller above. The cache makes it one Keychain read per account per process. All writes go
/// through here and update it, so it cannot go stale within the app.
///
/// ⚠️ A FAILED read is cached too, but only for `failedReadRetryInterval`: retrying on every
/// render would re-raise a prompt the user just denied, once per frame. `retry(account:)` is the
/// explicit way past it (the profile's Try Again button).
enum GlobalProviderKeys {

    /// Keychain service identifier for globally scoped provider credentials. ⚠️ Changing this
    /// orphans every stored key — items are looked up by (service, account) and nothing migrates.
    static let service = "com.devgentic.provider.global"

    /// How long a failed read is answered from the cache before the Keychain is asked again.
    static let failedReadRetryInterval: TimeInterval = 60

    /// Providers whose key is shared by every profile on them. Everything else keeps a per-profile
    /// key (`ProviderKeyStore`): local providers mostly need none, and an OpenAI-compatible profile
    /// is tied to its own server.
    static func isShared(_ provider: ApiProvider) -> Bool {
        switch provider {
        case .openAI, .anthropic, .google, .openRouter: return true
        case .openAICompatible, .ollama, .mlx: return false
        }
    }

    /// The Keychain account for a provider's shared key, or nil when the provider has none.
    static func account(for provider: ApiProvider) -> String? {
        isShared(provider) ? provider.providerString : nil
    }

    private enum Entry {
        case found(String)
        case notFound
        case failed(OSStatus, at: Date)
    }

    /// Test seam. Mutated only by `setStorageForTesting`; production never reassigns it.
    nonisolated(unsafe) private static var storage: KeychainAccessing = SecureKeyStorage()
    private static let cache = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Swaps the Keychain backend and empties the cache. Test-only — pass nil to restore the real one.
    static func setStorageForTesting(_ replacement: KeychainAccessing?) {
        storage = replacement ?? SecureKeyStorage()
        cache.withLock { $0.removeAll() }
    }

    /// Forgets every cached answer, so the next read of each account asks the Keychain.
    static func discardCache() {
        cache.withLock { $0.removeAll() }
    }

    /// ⚠️ TEST ISOLATION. A shared key is process-wide state — one test's "anthropic" key is every
    /// later test's "anthropic" key, where per-profile keys never collided (each test's profiles have
    /// fresh ids). The test bundle calls this before every test case. No-op outside a test host.
    static func resetForTestIsolation() {
        guard TestHost.isRunning else { return }
        TestHostKeychain.shared.removeAll(service: service)
        setStorageForTesting(nil)
    }

    /// The key for `account`, distinguishing "none stored" from "the read failed" (register B2).
    static func read(account: String) -> KeychainReadOutcome {
        let cached = cache.withLock { $0[account] }
        switch cached {
        case .found(let key)?:
            return .found(key)
        case .notFound?:
            return .notFound
        case .failed(let status, let at)? where Date().timeIntervalSince(at) < failedReadRetryInterval:
            return .failed(status)
        case .failed?, nil:
            return readThrough(account: account)
        }
    }

    /// Asks the Keychain again now, ignoring a cached failure — the user pressed Try Again.
    @discardableResult
    static func retry(account: String) -> KeychainReadOutcome {
        readThrough(account: account)
    }

    private static func readThrough(account: String) -> KeychainReadOutcome {
        // Outside the lock: a read can block for as long as an access prompt stays on screen.
        let outcome = storage.read(service: service, account: account)
        let entry: Entry
        switch outcome {
        case .found(let key): entry = .found(key)
        case .notFound: entry = .notFound
        case .failed(let status):
            entry = .failed(status, at: Date())
            logger.error("[GLOBAL_KEYS] Could not read the shared '\(account)' API key (\(SecureKeyStorage.osStatusName(status))) — this is NOT the same as having no key. CONSEQUENCE: every profile on this provider behaves as unconfigured and nothing deletes or overwrites the stored key; the Keychain is asked again in \(Int(failedReadRetryInterval)) s or on Try Again.")
        }
        cache.withLock { $0[account] = entry }
        return outcome
    }

    /// Stores `key` for `account`. Callers handle the empty case — this never deletes.
    static func save(_ key: String, account: String) -> OSStatus {
        let status = storage.save(value: key, service: service, account: account)
        // On failure the item's state is unknown — drop the entry so the next read asks the Keychain.
        cache.withLock { cache in
            if status == errSecSuccess { cache[account] = .found(key) } else { cache[account] = nil }
        }
        if status == errSecSuccess { noteChanged() }
        return status
    }

    /// Removes the key for `account`. `errSecItemNotFound` counts as success.
    static func delete(account: String) -> OSStatus {
        let status = storage.delete(service: service, account: account)
        let gone = status == errSecSuccess || status == errSecItemNotFound
        cache.withLock { $0[account] = gone ? .notFound : nil }
        if gone { noteChanged() }
        return status
    }

    /// Re-renders views observing `AppProviderKeyStore.revision`, from whichever isolation wrote.
    private static func noteChanged() {
        Task { @MainActor in AppProviderKeyStore.shared.revision &+= 1 }
    }
}

@Observable
@MainActor
final class AppProviderKeyStore {

    @ObservationIgnored static let shared = AppProviderKeyStore()

    /// Keychain service identifier for globally scoped provider credentials.
    static let service = GlobalProviderKeys.service

    /// Test seam for mocking Keychain operations. Also empties the shared-key cache.
    static func setStorageForTesting(_ replacement: KeychainAccessing?) {
        GlobalProviderKeys.setStorageForTesting(replacement)
    }

    /// Revision counter that increments on key changes to trigger SwiftUI view updates.
    var revision: Int = 0

    private init() {}

    // MARK: - Vendor Account Resolution

    /// The Hugging Face token's account name in the catalog. ⚠️ Its ONLY home is
    /// `HuggingFaceTokenStore` (service `com.devgentic.huggingface`) — the MLX downloader reads it
    /// there. This store used to ALSO write a copy under the shared provider service, so one token
    /// was two Keychain items (two access prompts after a signature change), and clearing it left
    /// the copy behind for the fallback read below to resurrect.
    static let huggingFaceAccount = "huggingface"

    static func account(for provider: ApiProvider) -> String {
        provider.providerString
    }

    // MARK: - Key Read / Write / Delete API

    /// Reads the API key for an ApiProvider.
    static func load(for provider: ApiProvider) -> String? {
        load(forAccount: account(for: provider))
    }

    /// Reads the API key for a custom vendor account string (e.g. "huggingface").
    static func load(forAccount account: String) -> String? {
        // A keyless provider (Ollama, MLX) has no key to find — don't ask the Keychain. Reached
        // when a local model is picked in the model catalog, which loads "the key" for every pick.
        if let provider = ApiProvider.allCases.first(where: { $0.providerString == account }), !provider.usesAPIKey {
            return nil
        }
        if account == huggingFaceAccount {
            guard let hf = HuggingFaceTokenStore.shared.token, !hf.isEmpty else { return nil }
            return hf
        }

        guard case .found(let key) = GlobalProviderKeys.read(account: account) else {
            return nil
        }
        return key
    }

    /// Checks whether an API key exists and is non-empty.
    func hasKey(for provider: ApiProvider) -> Bool {
        _ = revision // Observe revision
        let account = Self.account(for: provider)
        return hasKey(forAccount: account)
    }

    /// Checks whether an API key exists for a vendor account string.
    func hasKey(forAccount account: String) -> Bool {
        _ = revision // Observe revision
        if account == Self.huggingFaceAccount {
            return HuggingFaceTokenStore.shared.hasToken
        }
        guard let key = Self.load(forAccount: account), !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    /// Saves or removes an API key for an ApiProvider across the app's lifetime.
    @discardableResult
    static func save(_ key: String?, for provider: ApiProvider) -> Bool {
        save(key, forAccount: account(for: provider))
    }

    /// Saves or removes an API key for a vendor account string across the app's lifetime.
    @discardableResult
    static func save(_ key: String?, forAccount account: String) -> Bool {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)

        if account == huggingFaceAccount {
            let succeeded: Bool
            if let trimmed, !trimmed.isEmpty {
                succeeded = HuggingFaceTokenStore.shared.store(trimmed)
            } else {
                succeeded = HuggingFaceTokenStore.shared.clear()
            }
            shared.revision &+= 1
            return succeeded
        }

        guard let trimmed, !trimmed.isEmpty else {
            let deleted = delete(forAccount: account)
            shared.revision &+= 1
            return deleted
        }

        let status = GlobalProviderKeys.save(trimmed, account: account)
        guard status == errSecSuccess else {
            logger.error("[GLOBAL_KEYS] Failed to write the API key for \(account) to the Keychain: \(SecureKeyStorage.osStatusName(status)).")
            return false
        }

        shared.revision &+= 1
        logger.info("[GLOBAL_KEYS] Successfully saved global API key for provider '\(account)'.")
        return true
    }

    /// Deletes the API key for an ApiProvider.
    @discardableResult
    static func delete(for provider: ApiProvider) -> Bool {
        delete(forAccount: account(for: provider))
    }

    /// Deletes the API key for a vendor account string.
    @discardableResult
    static func delete(forAccount account: String) -> Bool {
        if account == huggingFaceAccount {
            let cleared = HuggingFaceTokenStore.shared.clear()
            shared.revision &+= 1
            return cleared
        }
        let status = GlobalProviderKeys.delete(account: account)
        guard status != errSecSuccess && status != errSecItemNotFound else {
            shared.revision &+= 1
            return true
        }
        logger.error("[GLOBAL_KEYS] Failed to delete API key for \(account) from Keychain: \(SecureKeyStorage.osStatusName(status)).")
        return false
    }

    /// Returns a masked representation of the stored key (e.g. "sk-ant…3a9b").
    func maskedKey(for provider: ApiProvider) -> String? {
        _ = revision
        return maskedKey(forAccount: Self.account(for: provider))
    }

    func maskedKey(forAccount account: String) -> String? {
        _ = revision
        if account == Self.huggingFaceAccount {
            return HuggingFaceTokenStore.shared.maskedToken
        }
        guard let key = Self.load(forAccount: account), !key.isEmpty else { return nil }
        return Self.mask(key)
    }

    static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return "••••••••" }
        let prefix = trimmed.prefix(4)
        let suffix = trimmed.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    // MARK: - Endpoint Storage API

    private static let endpointPrefix = "app_provider_endpoint_"

    /// Reads any custom API endpoint override for an ApiProvider.
    static func loadEndpoint(for provider: ApiProvider) -> String? {
        loadEndpoint(forAccount: account(for: provider))
    }

    /// Reads any custom API endpoint override for a vendor account string.
    static func loadEndpoint(forAccount account: String) -> String? {
        let key = endpointPrefix + account
        guard let value = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Reactive helper reading custom endpoint override for an account.
    func endpoint(forAccount account: String) -> String? {
        _ = revision
        return Self.loadEndpoint(forAccount: account)
    }

    func endpoint(for provider: ApiProvider) -> String? {
        _ = revision
        return Self.loadEndpoint(for: provider)
    }

    /// Saves or removes a custom API endpoint override for an ApiProvider.
    @discardableResult
    static func saveEndpoint(_ endpoint: String?, for provider: ApiProvider) -> Bool {
        saveEndpoint(endpoint, forAccount: account(for: provider))
    }

    /// Saves or removes a custom API endpoint override for a vendor account string.
    @discardableResult
    static func saveEndpoint(_ endpoint: String?, forAccount account: String) -> Bool {
        let key = endpointPrefix + account
        let trimmed = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        shared.revision &+= 1
        return true
    }

    /// Deletes any custom API endpoint override for an ApiProvider.
    @discardableResult
    static func deleteEndpoint(for provider: ApiProvider) -> Bool {
        deleteEndpoint(forAccount: account(for: provider))
    }

    /// Deletes any custom API endpoint override for a vendor account string.
    @discardableResult
    static func deleteEndpoint(forAccount account: String) -> Bool {
        saveEndpoint(nil, forAccount: account)
    }
}
