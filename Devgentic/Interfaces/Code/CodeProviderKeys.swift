// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProviderKeys.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import Security

private let logger = DGLogger(category: "CodeProviderKeys")

/// The Code interface's API key per provider, so a project's remembered cloud model keeps its key after another
/// project switches the permanent Code profile's provider. Keys live in the Keychain, never UserDefaults.
/// OpenAI, Anthropic, Google and OpenRouter use the shared key (`GlobalProviderKeys`); `.openAICompatible` has a slot.
enum CodeProviderKeys {

    /// A fixed, recognisable Keychain account per provider. The prefix is not a profile id and can
    /// never collide with one (profile ids are random v4 UUIDs; this is not a valid v4 layout).
    static func slotID(for provider: ApiProvider) -> UUID {
        let index = ApiProvider.allCases.firstIndex(of: provider) ?? 0
        return UUID(uuidString: String(format: "C0DE0000-0000-0000-0000-%012X", index))!
    }

    static func remember(_ key: String?, for provider: ApiProvider) {
        guard provider.usesAPIKey else { return }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        if let account = GlobalProviderKeys.account(for: provider) {
            let status = GlobalProviderKeys.save(key, account: account)
            if status == errSecSuccess {
                logger.info("[CODE_KEYS] Saved the \(provider.rawValue) key as the shared provider key.")
            } else {
                logger.error("[CODE_KEYS] Could not save the \(provider.rawValue) key as the shared provider key (\(SecureKeyStorage.osStatusName(status))). CONSEQUENCE: this project still has it on the profile until the next fetch, but every \(provider.rawValue) profile — this one included, after a relaunch — runs WITHOUT a key and its first send fails authentication.")
            }
            return
        }
        if ProviderKeyStore.save(key, for: slotID(for: provider)) {
            logger.info("[CODE_KEYS] Saved the \(provider.rawValue) key to its Code Keychain slot.")
        } else {
            logger.error("[CODE_KEYS] Could not save the \(provider.rawValue) key to its Code Keychain slot. CONSEQUENCE: this project still has it on the profile, but after switching to a project on another provider and back, its model is restored WITHOUT a key and the first send fails authentication.")
        }
    }

    static func key(for provider: ApiProvider) -> String? {
        guard provider.usesAPIKey else { return nil }
        if let account = GlobalProviderKeys.account(for: provider) {
            guard case .found(let key) = GlobalProviderKeys.read(account: account) else { return nil }
            return key
        }
        return ProviderKeyStore.load(for: slotID(for: provider))
    }
}
