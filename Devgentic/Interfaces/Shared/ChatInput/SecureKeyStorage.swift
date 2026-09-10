// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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

    /// Saves a string value (like an API key) to the Keychain.
    /// It will update the key if it already exists, or create a new entry if it doesn't.
    ///
    /// - Parameters:
    ///   - value: The string value to save.
    ///   - service: A unique identifier for the service the key belongs to (e.g., your app's bundle ID).
    ///   - account: A unique identifier for the account or key name.
    /// - Returns: An `OSStatus` code indicating the result of the operation. `errSecSuccess` on success.
    func save(value: String, service: String, account: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else {
            logger.error("Failed to encode string to data for saving to keychain.")
            return errSecParam
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if status == errSecItemNotFound {
            let newQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data
            ]
            logger.log("No existing key found. Adding new key to keychain for service: \(service), account: \(account)")
            return SecItemAdd(newQuery as CFDictionary, nil)
        }
        
        if status == errSecSuccess {
            logger.log("Successfully updated existing keychain item for service: \(service), account: \(account)")
        } else {
            logger.error("Error updating keychain item. Status: \(status)")
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

        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            // ⚠️ A success status whose payload will not decode is a FAILURE, not an absence —
            // the item exists and we could not read it, which is precisely the case that must not
            // be mistaken for "none stored".
            logger.error(
                "[SECRETS] Keychain read failed for service '\(service)' (OSStatus \(status)). "
                + "CONSEQUENCE: the caller is told the read FAILED rather than that no value "
                + "exists, so it must not overwrite or delete the stored credential."
            )
            return .failed(status)
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("Error deleting from keychain. Status: \(status)")
        }
        return status
    }
}
