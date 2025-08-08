//
//  SecureKeyStorage.swift
//  Devgentic
//
//  Created by Raj Singh on 28/07/25.
//

import Foundation
import Security
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SecureKeyStorage")

/// A service for securely saving, retrieving, and deleting sensitive data like API keys from the system Keychain.
struct SecureKeyStorage {

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue!,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                logger.error("Error retrieving from keychain. Status: \(status)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
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
