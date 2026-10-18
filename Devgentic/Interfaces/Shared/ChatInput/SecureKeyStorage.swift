// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SecureKeyStorage.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Security
import os

private let logger = DGLogger(category: "SecureKeyStorage")

/// The three genuinely different results of a Keychain read.
/// `notFound` and `failed` must not collapse into one nil: "no credential stored" and "could not look" call for
/// opposite actions.
enum KeychainReadOutcome: Equatable {
    case found(String)
    case notFound
    case failed(OSStatus)
}

/// The Keychain operations `ProviderKeyStore` depends on, so its failure branches are testable.
/// A failed read or delete is destructive if mistaken for success.
protocol KeychainAccessing: Sendable {
    func save(value: String, service: String, account: String) -> OSStatus
    func read(service: String, account: String) -> KeychainReadOutcome
    func delete(service: String, account: String) -> OSStatus
}

/// A service for securely saving, retrieving, and deleting sensitive data like API keys from the system Keychain.
struct SecureKeyStorage: KeychainAccessing {

    /// Test seam: when set, receives exactly the message a first-time item add would log.
    /// One message feeds the logger and the sink alike, so the seam cannot drift from the log.
    nonisolated(unsafe) static var addResultLogSinkForTesting: (@Sendable (String) -> Void)?

    /// The Keychain Access "Kind" column for every item this app writes.
    static let itemDescription = "Devgentic credential"

    /// Returns the Keychain Access "Name" label for an item; every label starts with "Devgentic" so one search lists
    /// everything the app stored.
    /// Derived from the address rather than a per-store name table.
    static func itemLabel(service: String, account: String) -> String {
        "Devgentic — \(service) — \(account)"
    }

    /// The log line for a first-time item add, success and failure.
    /// A pure function so both texts are testable; `logAddResult` is the only caller.
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

    /// Human names for the `OSStatus` values this subsystem produces, so logs say more than a bare integer.
    /// Unmapped codes degrade to the raw number.
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

    /// The log line for an in-place update of an existing item: tag, service, account, and on failure the consequence
    /// and a named status.
    static func updateResultMessage(status: OSStatus, service: String, account: String) -> String {
        if status == errSecSuccess {
            return "[SECRETS] Updated an existing keychain item for service '\(service)', account '\(account)'."
        }
        return "[SECRETS] Failed to UPDATE an existing keychain item for service '\(service)', "
            + "account '\(account)' (\(osStatusName(status))). CONSEQUENCE: the caller receives the "
            + "failure; an add attempt may follow, and if that also fails the credential is stored "
            + "NOWHERE — see the ADD log line."
    }

    /// The log line for a delete, failure only; a successful delete and a delete of an absent item are unremarkable.
    static func deleteResultMessage(status: OSStatus, service: String, account: String) -> String {
        return "[SECRETS] Failed to DELETE a keychain item for service '\(service)', "
            + "account '\(account)' (\(osStatusName(status))). CONSEQUENCE: the credential REMAINS "
            + "stored — the caller must not report it as cleared or removed."
    }

    /// The log line for a failed read, including the account, since many items share one service.
    /// The consequence is the reason the message exists.
    // MARK: - Access-prompt tracing

    /// A `SecItem*` call slower than this almost certainly showed the macOS "Devgentic wants to use
    /// your confidential information" dialog: the call BLOCKS until the user answers it, while an
    /// ordinary hit or miss returns in well under 10 ms.
    static let accessPromptSuspectThreshold: TimeInterval = 0.25

    /// Correlates the start and end of one call in the log.
    private static let traceSequence = OSAllocatedUnfairLock(initialState: 0)

    /// Runs one `SecItem*` call and logs its operation, item, status and duration.
    /// Diagnoses the keychain prompt seen at launch, which appears when an item's ACL names a different code signature;
    /// slow calls log the call stack.
    static func traced(
        _ operation: String,
        service: String,
        account: String,
        _ call: () -> OSStatus
    ) -> OSStatus {
        let id = traceSequence.withLock { value -> Int in value += 1; return value }
        let started = Date()
        let status = call()
        let elapsed = Date().timeIntervalSince(started)
        let ms = Int((elapsed * 1000).rounded())
        let line = "[KEYCHAIN_TRACE] #\(id) \(operation) service='\(service)' account='\(account)' → \(osStatusName(status)) in \(ms) ms"
        if elapsed >= accessPromptSuspectThreshold {
            let stack = Thread.callStackSymbols.dropFirst(2).prefix(14).joined(separator: "\n")
            logger.notice("\(line) — SLOW: a Keychain access prompt was probably shown and waited on. CONSEQUENCE: this call blocked its thread until the user answered. Caller stack:\n\(stack)")
        } else {
            logger.info(line)
        }
        return status
    }

    static func readFailureMessage(status: OSStatus, service: String, account: String) -> String {
        return "[SECRETS] Keychain read FAILED for service '\(service)', account '\(account)' "
            + "(\(osStatusName(status))). CONSEQUENCE: the caller is told the read FAILED rather "
            + "than that no value exists, so it must not overwrite or delete the stored credential."
    }

    // Why: the test host is the real app, so tests must be structurally unable to touch real secrets.
    /// Under XCTest every `SecureKeyStorage()` uses a process-private in-memory store instead of the developer's
    /// Keychain.
    /// A caller that wants the real Keychain opts in with `init(bypassingTestHostRedirect: true)`.
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

    /// Saves a string value (like an API key) to the Keychain, updating it if it exists or adding it otherwise.
    /// `service` identifies the service the key belongs to and `account` the key name.
    /// - Returns: An `OSStatus`; `errSecSuccess` on success.
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

        // The label rides on the update too, so older items are relabelled the next time they are written.
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: Self.itemLabel(service: service, account: account),
            kSecAttrDescription as String: Self.itemDescription
        ]

        let status = Self.traced("update", service: service, account: account) {
            SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        }
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
            let addStatus = Self.traced("add", service: service, account: account) {
                SecItemAdd(newQuery as CFDictionary, nil)
            }
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
    /// - Parameters: `service` and `account` the key was saved under.
    /// - Returns: The value, or `nil` if it is not found or an error occurs.
    func retrieve(service: String, account: String) -> String? {
        guard case .found(let value) = read(service: service, account: account) else { return nil }
        return value
    }

    /// Reads a value, distinguishing "nothing stored" from "the read failed".
    /// `retrieve` is a thin wrapper for callers that only need value-or-nothing; anything that writes based on the
    /// answer must use this.
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
        let status = Self.traced("read", service: service, account: account) {
            SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecItemNotFound { return .notFound }

        // A success status whose payload is not decodable data is a failure, not an absence: the item exists but cannot be
        // read.
        guard status == errSecSuccess, let data = item as? Data else {
            logger.error(Self.readFailureMessage(status: status, service: service, account: account))
            return .failed(status)
        }
        // The item exists but its bytes are not valid UTF-8; reported as `errSecDecode`.
        guard let value = String(data: data, encoding: .utf8) else {
            logger.error(Self.readFailureMessage(status: errSecDecode, service: service, account: account))
            return .failed(errSecDecode)
        }

        return .found(value)
    }

    /// Deletes a value from the Keychain.
    /// - Parameters: `service` and `account` the key was saved under.
    /// - Returns: An `OSStatus`; `errSecSuccess` on success.
    func delete(service: String, account: String) -> OSStatus {
        if redirectsToMemory {
            return TestHostKeychain.shared.delete(service: service, account: account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = Self.traced("delete", service: service, account: account) {
            SecItemDelete(query as CFDictionary)
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error(Self.deleteResultMessage(status: status, service: service, account: account))
        }
        return status
    }
}

// MARK: - Test-host stand-in

/// The process-private Keychain `SecureKeyStorage` routes to under XCTest.
/// One dictionary for the whole process, so one store's writes are visible to another; statuses mirror `SecItem*`.
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
        // The shared provider keys are cached above this store; a stale cache would answer with keys that were deleted
        // here.
        GlobalProviderKeys.discardCache()
        ProviderKeyStore.discardCache()
    }

    /// Empties one service. For test isolation only — see `GlobalProviderKeys.resetForTestIsolation`.
    func removeAll(service: String) {
        let prefix = service + "\u{0}"
        lock.withLock { items = items.filter { !$0.key.hasPrefix(prefix) } }
    }
}
