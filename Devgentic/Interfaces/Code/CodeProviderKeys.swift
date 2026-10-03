// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeProviderKeys.swift
//  Devgentic
//
//  The Code interface's API key per PROVIDER, so a project's remembered cloud model still has its
//  key when the user comes back to it (2026-09-24).
//
//  ⚠️ WHY THIS EXISTS. There is one permanent Code profile, and a profile holds ONE key — the one
//  for its current provider. With models remembered per project, opening an OpenAI project after an
//  Anthropic one replaces the profile's provider, and the Anthropic key would go with it: returning
//  to the first project would restore its model with no key, and its first send would fail on auth.
//  Keeping a Keychain slot per provider lets each project's model find its key again.
//
//  Keys go through the Keychain, never UserDefaults — `CodeProjectState` strips them for exactly
//  that reason.
//
//  ⚠️ ONE KEY PER PROVIDER (2026-10-03). For OpenAI, Anthropic, Google and OpenRouter the slot IS
//  the app-wide shared key (`GlobalProviderKeys`) — the same one the model catalog sets and every
//  profile reads. It used to be a separate `C0DE…` item, i.e. a third copy of the same credential.
//  Only `.openAICompatible` (no shared key) still uses a Code slot.
//

import Foundation
import Security

private let logger = DGLogger(category: "CodeProviderKeys")

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
