// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WebSearchKeyStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: callers that write based on the answer must use `read()`, never `load()`.
/// Keychain home for the web-search API key.
/// An enum with one service and a `KeychainAccessing` seam, mirroring `ProviderKeyStore`.
enum WebSearchKeyStore {

    private static let logger = DGLogger(category: "WebSearchKeyStore")

    // Why: changing this orphans the stored key; nothing migrates it.
    /// Keychain service identifier.
    static let service = "com.devgentic.websearch"

    /// One key per user, not per profile. This is the GOOGLE account: it predates multiple
    /// providers, and keeping it means an already-stored Google key stays readable.
    static let account = "apiKey"

    /// The Keychain account for a provider. Google keeps the legacy `apiKey`; the others are
    /// named after themselves so no two providers can ever read each other's secret.
    static func keychainAccount(for provider: WebSearchProvider) -> String {
        provider == .google ? account : provider.rawValue
    }

    /// Test seam, same shape as `ProviderKeyStore.storage`: mutated only by `setStorageForTesting`; production never
    /// reassigns it.
    nonisolated(unsafe) private static var storage: KeychainAccessing = SecureKeyStorage()

    /// Swaps the Keychain backend. Test-only — pass nil to restore the real one.
    static func setStorageForTesting(_ replacement: KeychainAccessing?) {
        storage = replacement ?? SecureKeyStorage()
    }

    // MARK: - API

    /// Stores the key. A blank value is treated as a clear so an empty credential is never written.
    /// - Returns: whether the Keychain now holds it. `false` means the key is stored NOWHERE — this
    ///   store never falls back to plaintext, which is the whole point of its existence.
    @discardableResult
    static func save(_ key: String, for provider: WebSearchProvider = .google) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(for: provider) }

        let status = storage.save(value: trimmed, service: service, account: keychainAccount(for: provider))
        guard status == errSecSuccess else {
            logger.error(
                "[SECRETS] Failed to write the web-search API key to the Keychain (OSStatus \(status)). "
                + "CONSEQUENCE: the key is NOT stored — not in the Keychain and, deliberately, not in "
                + "UserDefaults either — so web search stays disabled and the user must enter it again "
                + "once the Keychain is writable (unlock it, or re-grant access after an app update "
                + "changed the code signature)."
            )
            return false
        }
        return true
    }

    /// The key, or nil when none is stored or the read failed.
    /// Only for callers that merely need a value to send; anything that writes based on the answer must use `read()`.
    static func load(for provider: WebSearchProvider = .google) -> String? {
        guard case .found(let key) = storage.read(service: service, account: keychainAccount(for: provider)) else { return nil }
        return key
    }

    /// Reads the key, distinguishing "none stored" from "the read failed".
    static func read(for provider: WebSearchProvider = .google) -> KeychainReadOutcome {
        let outcome = storage.read(service: service, account: keychainAccount(for: provider))
        if case .failed(let status) = outcome {
            logger.error(
                "[SECRETS] Could not read the web-search API key from the Keychain (OSStatus \(status)) "
                + "— this is NOT the same as no key being stored. CONSEQUENCE: web search presents as "
                + "not configured for this session; the stored key is left untouched and comes back "
                + "once the Keychain is readable again."
            )
        }
        return outcome
    }

    /// Removes the key. Returns true when the key is gone from the Keychain; `errSecItemNotFound` counts as success.
    @discardableResult
    static func delete(for provider: WebSearchProvider = .google) -> Bool {
        let status = storage.delete(service: service, account: keychainAccount(for: provider))
        guard status != errSecSuccess && status != errSecItemNotFound else { return true }
        logger.error(
            "[SECRETS] Failed to remove the web-search API key from the Keychain (OSStatus \(status)). "
            + "CONSEQUENCE: web search is switched off for this session, but the key is STILL in the "
            + "Keychain and will be read back — and the feature re-enabled — on the next launch. The "
            + "user believes it was removed."
        )
        return false
    }
}
