// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  WebSearchKeyStore.swift
//  Devgentic
//
//  Keychain home for the web-search API key. Register KC-2.
//
//  ⚠️ WHY THIS EXISTS. This was the one credential in the app with no Keychain identity at all:
//  `SettingsCoordinator` wrote it verbatim to `UserDefaults` — `~/Library/Preferences/`, readable by
//  every process running as the user, swept into every backup — and did so by the CURRENT design,
//  not a legacy one. Verified on disk (Keychain readiness §0): a live Google API key sat in
//  cleartext there, and a second copy was left behind intact in the orphaned `com.dev.devgentic`
//  domain after the bundle-id rename.
//
//  Mirrors `ProviderKeyStore`: an enum, one service, a `KeychainAccessing` seam, and the register-B2
//  rule — a caller that WRITES based on the answer must use `read()`, never `load()`.
//

import Foundation

enum WebSearchKeyStore {

    private static let logger = DGLogger(category: "WebSearchKeyStore")

    /// Keychain service identifier. ⚠️ Changing this orphans the stored key — nothing migrates it.
    static let service = "com.devgentic.websearch"

    /// One key per user, not per profile.
    static let account = "apiKey"

    /// The `UserDefaults` key every build before this one wrote the raw key to. Owned HERE rather
    /// than by `ProviderKeyStore.legacyPlaintextDefaultsKeys`, because this key has to be MIGRATED
    /// before it is removed and that purge deletes unconditionally.
    static let legacyDefaultsKey = "webSearchAPIKey"

    /// ⚠️ TEST SEAM, same shape as `ProviderKeyStore.storage`. Mutated only by
    /// `setStorageForTesting`; production never reassigns it.
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
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        let status = storage.save(value: trimmed, service: service, account: account)
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

    /// The key, or nil when none is stored **or the read failed**.
    ///
    /// ⚠️ Only for callers that merely need a value to send. Anything that WRITES based on the
    /// answer must use `read()` — register B2.
    static func load() -> String? {
        guard case .found(let key) = storage.read(service: service, account: account) else { return nil }
        return key
    }

    /// Reads the key, distinguishing "none stored" from "the read failed".
    static func read() -> KeychainReadOutcome {
        let outcome = storage.read(service: service, account: account)
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

    /// Removes the key.
    /// - Returns: whether the Keychain no longer holds it (`errSecItemNotFound` counts as success —
    ///   the desired end state is "gone", not "we did the deleting").
    @discardableResult
    static func delete() -> Bool {
        let status = storage.delete(service: service, account: account)
        guard status != errSecSuccess && status != errSecItemNotFound else { return true }
        logger.error(
            "[SECRETS] Failed to remove the web-search API key from the Keychain (OSStatus \(status)). "
            + "CONSEQUENCE: web search is switched off for this session, but the key is STILL in the "
            + "Keychain and will be read back — and the feature re-enabled — on the next launch. The "
            + "user believes it was removed."
        )
        return false
    }

    // MARK: - Migration from plaintext UserDefaults

    enum MigrationOutcome: Equatable {
        /// No plaintext copy existed.
        case nothingToMigrate
        /// The value is in the Keychain and the plaintext copy is gone.
        case migrated
        /// The Keychain write failed; the plaintext copy was deliberately left where it was.
        case leftInPlace(OSStatus)
    }

    /// Moves a plaintext key left in `UserDefaults` into the Keychain, then removes the plaintext.
    ///
    /// ⚠️ STRIP ONLY IF THE WRITE SUCCEEDED — the same asymmetry as `BackendProfileSD.details`.
    /// Removing the plaintext first and writing second would, on an unwritable Keychain, leave the
    /// key in neither place: the one outcome worse than plaintext.
    ///
    /// The plaintext value WINS over a Keychain value when both exist. Post-fix builds never write
    /// plaintext, so the two coexist only when an older build ran after this one and the user
    /// entered a key there — in which case the plaintext is the more recent action.
    /// `SettingsCoordinator` removes the plaintext copy on every successful save for the same
    /// reason: a stale copy must not be re-migrated over a rotated key on the next launch.
    ///
    /// Idempotent; safe on every launch. `defaults` is injectable so tests never touch the
    /// developer's real preferences domain.
    @discardableResult
    static func migrateFromUserDefaults(defaults: UserDefaults = .standard) -> MigrationOutcome {
        guard let plaintext = defaults.string(forKey: legacyDefaultsKey) else { return .nothingToMigrate }
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: legacyDefaultsKey)
            return .nothingToMigrate
        }

        let status = storage.save(value: trimmed, service: service, account: account)
        guard status == errSecSuccess else {
            logger.error(
                "[SECRETS] Could not migrate the web-search API key into the Keychain (OSStatus "
                + "\(status)). CONSEQUENCE: the plaintext copy in UserDefaults is LEFT IN PLACE — "
                + "removing it now would leave the key nowhere — and it is retried on the next launch."
            )
            return .leftInPlace(status)
        }

        defaults.removeObject(forKey: legacyDefaultsKey)
        logger.notice(
            "[SECRETS] Migrated the web-search API key from plaintext UserDefaults into the Keychain "
            + "and removed the plaintext copy. CONSEQUENCE: ~/Library/Preferences/ no longer holds a "
            + "live web-search API key for this domain; web search keeps working from the Keychain."
        )
        return .migrated
    }
}
