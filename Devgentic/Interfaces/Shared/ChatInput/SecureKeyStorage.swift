// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorage.swift
//  Devgentic
//
//  Created by Raj Singh on 28/07/25.
//

import Foundation
import Security
import os

private let logger = DGLogger(category: "SecureKeyStorage")

/// The three genuinely different results of a Keychain read. Register B2.
///
/// ⚠️ `notFound` and `failed` MUST NOT collapse into one `nil`. They mean opposite things: the
/// first says the user has no credential stored, the second says we could not look. Acting on the
/// wrong one is destructive — a caller that treats "could not look" as "none stored" will happily
/// overwrite or delete a credential that is perfectly intact. This is the same distinction
/// `BackendConfigUnavailability` draws for a profile lookup (register A32) and the same lesson
/// register A47 records for the profile list: "you have none" must never render as "I couldn't
/// read them".
enum KeychainReadOutcome: Equatable {
    case found(String)
    case notFound
    case failed(OSStatus)
}

/// The Keychain operations `ProviderKeyStore` depends on, so its failure branches are testable.
/// ⚠️ Registers B2 / B19: a failed READ and a failed DELETE are both destructive if mistaken for
/// success, and neither could be exercised while the backend was a concrete `private static let`.
protocol KeychainAccessing: Sendable {
    func save(value: String, service: String, account: String) -> OSStatus
    func read(service: String, account: String) -> KeychainReadOutcome
    func delete(service: String, account: String) -> OSStatus
}

/// A service for securely saving, retrieving, and deleting sensitive data like API keys from the system Keychain.
struct SecureKeyStorage: KeychainAccessing {

    /// ⚠️ TEST SEAM (register KC-9). When set, receives EXACTLY the message a first-time item ADD
    /// would log — the one branch of `save` whose result used to be returned unlogged, so a
    /// credential write that failed on its very first attempt (the pairing case: nothing existed
    /// yet, `SecItemUpdate` missed, `SecItemAdd` was the only real write) did so in complete
    /// silence. Same shape as `ShellProcess.stderrLogSinkForTesting`: one message for the logger
    /// and the sink alike, so the seam cannot drift from the log.
    nonisolated(unsafe) static var addResultLogSinkForTesting: (@Sendable (String) -> Void)?

    /// The Keychain Access "Kind" column for every item this app writes. Registers KC-25 / KC-30.
    static let itemDescription = "Devgentic credential"

    /// The Keychain Access "Name" column. Registers KC-25 / KC-30.
    ///
    /// ⚠️ Without a label Keychain Access shows the bare service string, and most accounts are
    /// opaque UUIDs — so the app's own "delete it manually from Keychain Access" advice (a failed
    /// MCP purge, a failed profile-key delete) named items nobody could find. Every label starts
    /// with "Devgentic", so searching Keychain Access for that one word lists everything the app
    /// has ever stored; for an app with no uninstaller that is the whole "remove my credentials"
    /// story (KC-36). Derived from the address rather than a per-store name table, so no second
    /// copy of the service strings exists to drift from the ones KC-56 pins.
    static func itemLabel(service: String, account: String) -> String {
        "Devgentic — \(service) — \(account)"
    }

    /// The log line for a first-time item ADD — success and failure. Register KC-9.
    ///
    /// A pure function so both texts are pinnable without driving the real Security framework into
    /// a failure it cannot be forced into deterministically. `logAddResult` is the only caller.
    static func addResultMessage(status: OSStatus, service: String, account: String) -> String {
        if status == errSecSuccess {
            return "Added a new keychain item for service: \(service), account: \(account)."
        }
        return "[SECRETS] Failed to ADD a first-time keychain item for service '\(service)', "
            + "account '\(account)' (\(osStatusName(status))). CONSEQUENCE: the credential is stored "
            + "NOWHERE — the caller must treat this as a failure; a user who is told otherwise "
            + "has a pairing, token or API key that silently will not exist after relaunch."
    }

    /// Logs the ADD result through `addResultMessage`, to the sink when one is installed.
    private static func logAddResult(_ status: OSStatus, service: String, account: String) {
        let message = addResultMessage(status: status, service: service, account: account)
        if let sink = addResultLogSinkForTesting {
            sink(message)
            return
        }
        if status == errSecSuccess {
            logger.log(message)
        } else {
            logger.error(message)
        }
    }

    /// Human names for the OSStatus values this subsystem actually produces. Register KC-51: every
    /// log used to carry a bare integer, and `OSStatus -25308` tells a reader nothing that
    /// "errSecInteractionNotAllowed — the Keychain is locked, or an ACL prompt was denied" does.
    /// Unmapped codes degrade to the raw number — a wrong name would be worse than none.
    static func osStatusName(_ status: OSStatus) -> String {
        switch status {
        case errSecSuccess:                 return "errSecSuccess"
        case errSecItemNotFound:            return "errSecItemNotFound (the item does not exist)"
        case errSecAuthFailed:              return "errSecAuthFailed (locked Keychain, or an ACL prompt was denied)"
        case errSecInteractionNotAllowed:   return "errSecInteractionNotAllowed (locked Keychain, or an ACL prompt is pending)"
        case errSecMissingEntitlement:      return "errSecMissingEntitlement (keychain-access-groups / signing problem)"
        case errSecDecode:                  return "errSecDecode (the item's payload could not be decoded)"
        case errSecDuplicateItem:           return "errSecDuplicateItem"
        case errSecParam:                   return "errSecParam"
        default:                            return "OSStatus \(status) (unmapped)"
        }
    }

    /// The log line for an in-place UPDATE of an existing item — both outcomes. Register KC-24:
    /// every message this primitive emits carries a tag, the service AND account it concerns,
    /// and — on failure — the consequence and a named OSStatus (KC-51).
    static func updateResultMessage(status: OSStatus, service: String, account: String) -> String {
        if status == errSecSuccess {
            return "[SECRETS] Updated an existing keychain item for service '\(service)', account '\(account)'."
        }
        return "[SECRETS] Failed to UPDATE an existing keychain item for service '\(service)', "
            + "account '\(account)' (\(osStatusName(status))). CONSEQUENCE: the caller receives the "
            + "failure; an add attempt may follow, and if that also fails the credential is stored "
            + "NOWHERE — see the ADD log line."
    }

    /// The log line for a DELETE — failure only (a successful delete and a delete of an absent
    /// item are unremarkable). Register KC-24 / KC-51.
    static func deleteResultMessage(status: OSStatus, service: String, account: String) -> String {
        return "[SECRETS] Failed to DELETE a keychain item for service '\(service)', "
            + "account '\(account)' (\(osStatusName(status))). CONSEQUENCE: the credential REMAINS "
            + "stored — the caller must not report it as cleared or removed."
    }

    /// The log line for a FAILED READ. Register KC-24: this message omitted the ACCOUNT — but all
    /// four ChatOps credentials share one service and every MCP secret shares another, so a read
    /// failure without the account cannot be told apart from its siblings. Register B2: the
    /// consequence is the whole reason this message exists.
    static func readFailureMessage(status: OSStatus, service: String, account: String) -> String {
        return "[SECRETS] Keychain read FAILED for service '\(service)', account '\(account)' "
            + "(\(osStatusName(status))). CONSEQUENCE: the caller is told the read FAILED rather "
            + "than that no value exists, so it must not overwrite or delete the stored credential."
    }

    /// ⚠️⚠️ THE XCTEST HOST IS THE REAL APP, AND THIS IS WHERE THAT STOPPED REACHING THE LOGIN
    /// KEYCHAIN. Registers KC-54 / KC-55. Under XCTest every `SecureKeyStorage()` — including the
    /// ones inside `ProviderKeyStore`, `MCPSecretStore`, `HuggingFaceTokenStore`, `WebSearchKeyStore`
    /// and `ChatOpsConfigManager` — reads and writes a process-private in-memory store instead of
    /// the developer's Keychain. Before this, nine `ProviderKeyStorageTests` wrote a sentinel into
    /// the PRODUCTION `com.devgentic.provider` service, and merely constructing
    /// `ChatOpsConfigManager.shared` ran a copy-then-delete migration against live bot tokens. Once
    /// the repository is public, "runs the test suite" is something strangers do on their own Macs;
    /// a test must be structurally unable to touch their secrets, and a comment asking authors to
    /// install a stub protects nothing — the app constructs these stores before any test is named.
    ///
    /// REDIRECT, NOT REFUSE — `TestHost.permits` explains the split: persistence has a useful test
    /// version (a round trip through memory is a real test); an outward side effect does not.
    ///
    /// ⚠️ A caller that deliberately wants the real Keychain — `SecureKeyStorageTests`, which
    /// exercises the `SecItem*` queries against a throwaway service — opts in BY NAME with
    /// `init(bypassingTestHostRedirect: true)`. Outside the test host the flag changes nothing, and
    /// `SecureKeyStorageTestHostRedirectTests` pins that no production source ever passes it.
    private let bypassesTestHostRedirect: Bool

    init() {
        self.init(bypassingTestHostRedirect: false)
    }

    init(bypassingTestHostRedirect: Bool) {
        self.bypassesTestHostRedirect = bypassingTestHostRedirect
    }

    /// True when this instance must route to `TestHostKeychain` instead of the Security framework.
    private var redirectsToMemory: Bool {
        !bypassesTestHostRedirect && TestHost.isRunning
    }

    /// Saves a string value (like an API key) to the Keychain.
    /// It will update the key if it already exists, or create a new entry if it doesn't.
    ///
    /// - Parameters:
    ///   - value: The string value to save.
    ///   - service: A unique identifier for the service the key belongs to (e.g., your app's bundle ID).
    ///   - account: A unique identifier for the account or key name.
    /// - Returns: An `OSStatus` code indicating the result of the operation. `errSecSuccess` on success.
    func save(value: String, service: String, account: String) -> OSStatus {
        if redirectsToMemory {
            return TestHostKeychain.shared.save(value: value, service: service, account: account)
        }
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to encode string to data for saving to keychain.")
            return errSecParam
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        // The label rides on the UPDATE too, so an item created by a build that predates KC-25
        // is labelled the next time it is written — there is no separate backfill pass to forget.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.itemLabel(service: service, account: account),
            kSecAttrDescription as String: Self.itemDescription
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            let newQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrLabel as String: Self.itemLabel(service: service, account: account),
                kSecAttrDescription as String: Self.itemDescription,
                kSecValueData as String: data
            ]
            logger.log("No existing key found. Adding new key to keychain for service: \(service), account: \(account)")
            let addStatus = SecItemAdd(newQuery as CFDictionary, nil)
            Self.logAddResult(addStatus, service: service, account: account)
            return addStatus
        }
        
        if status == errSecSuccess {
            logger.log(Self.updateResultMessage(status: status, service: service, account: account))
        } else {
            logger.error(Self.updateResultMessage(status: status, service: service, account: account))
        }

        return status
    }

    /// Retrieves a string value from the Keychain.
    ///
    /// - Parameters:
    ///   - service: The service identifier the key was saved under.
    ///   - account: The account name the key was saved under.
    /// - Returns: The retrieved string value, or `nil` if it's not found or an error occurs.
    func retrieve(service: String, account: String) -> String? {
        guard case .found(let value) = read(service: service, account: account) else { return nil }
        return value
    }

    /// Reads a value, distinguishing "nothing stored" from "the read failed".
    ///
    /// ⚠️ register B2 — this used to be the body of `retrieve`, which returned `nil` for BOTH. A
    /// locked Keychain, or a denied ACL prompt after a re-sign or a Sparkle update, therefore read
    /// as "the user has no key", and the next opportunistic profile save deleted the credential
    /// permanently. `retrieve` survives as a thin wrapper for callers that genuinely only need
    /// "value or nothing"; anything that WRITES based on the answer must use this instead.
    func read(service: String, account: String) -> KeychainReadOutcome {
        if redirectsToMemory {
            return TestHostKeychain.shared.read(service: service, account: account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { return .notFound }

        // ⚠️ A SUCCESS status whose payload will not come back as decodable data is a FAILURE,
        // not an absence — the item exists and we could not read it, which is precisely the case
        // that must not be mistaken for "none stored". Register B2.
        guard status == errSecSuccess, let data = item as? Data else {
            logger.error(Self.readFailureMessage(status: status, service: service, account: account))
            return .failed(status)
        }
        // Register KC-23: a decode failure used to return `.failed(errSecSuccess)` and log
        // "OSStatus 0" — a self-contradicting log line. The item exists but its bytes are not
        // valid UTF-8 (another tool wrote it, or a success arrived with no payload); that is
        // errSecDecode, and the log now says so.
        guard let value = String(data: data, encoding: .utf8) else {
            logger.error(Self.readFailureMessage(status: errSecDecode, service: service, account: account))
            return .failed(errSecDecode)
        }

        return .found(value)
    }

    /// Deletes a value from the Keychain.
    ///
    /// - Parameters:
    ///   - service: The service identifier the key was saved under.
    ///   - account: The account name the key was saved under.
    /// - Returns: An `OSStatus` code indicating the result of the operation. `errSecSuccess` on success.
    func delete(service: String, account: String) -> OSStatus {
        if redirectsToMemory {
            return TestHostKeychain.shared.delete(service: service, account: account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error(Self.deleteResultMessage(status: status, service: service, account: account))
        }
        return status
    }
}

// MARK: - Test-host stand-in

/// The process-private Keychain `SecureKeyStorage` routes to under XCTest. See the redirect note on
/// `SecureKeyStorage.bypassesTestHostRedirect` for why it exists.
///
/// One dictionary for the whole process, so a value written through one store instance is readable
/// through another — the same shape as the real Keychain, which every production store relies on
/// (a token saved by the pairing service is read back by the config manager's restore). Statuses
/// mirror `SecItem*`: a delete of an absent item is `errSecItemNotFound`, so caller code that
/// branches on it behaves identically against both backends.
final class TestHostKeychain: KeychainAccessing, @unchecked Sendable {

    static let shared = TestHostKeychain()

    private let lock = NSLock()
    private var items: [String: String] = [:]

    private init() {
        logger.notice(
            "[TESTHOST] Keychain access is REDIRECTED to an in-memory store because this process is "
            + "an XCTest host. CONSEQUENCE: nothing a test writes reaches the developer's login "
            + "Keychain, and nothing stored there is visible to tests — a test that needs a "
            + "credential must store it first."
        )
    }

    private func key(_ service: String, _ account: String) -> String {
        service + "\u{0}" + account
    }

    func save(value: String, service: String, account: String) -> OSStatus {
        lock.withLock { items[key(service, account)] = value }
        return errSecSuccess
    }

    func read(service: String, account: String) -> KeychainReadOutcome {
        lock.withLock {
            guard let value = items[key(service, account)] else { return .notFound }
            return .found(value)
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        lock.withLock {
            items.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    /// Empties the store. For test isolation only.
    func removeAll() {
        lock.withLock { items.removeAll() }
    }
}
