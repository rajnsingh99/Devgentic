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
//  Keys go through `ProviderKeyStore` (the Keychain), never UserDefaults — `CodeProjectState` strips
//  them for exactly that reason.
//

import Foundation

private let logger = DGLogger(category: "CodeProviderKeys")

enum CodeProviderKeys {

    /// A fixed, recognisable Keychain account per provider. The prefix is not a profile id and can
    /// never collide with one (profile ids are random v4 UUIDs; this is not a valid v4 layout).
    static func slotID(for provider: ApiProvider) -> UUID {
        let index = ApiProvider.allCases.firstIndex(of: provider) ?? 0
        return UUID(uuidString: String(format: "C0DE0000-0000-0000-0000-%012X", index))!
    }

    static func remember(_ key: String?, for provider: ApiProvider) {
        guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if ProviderKeyStore.save(key, for: slotID(for: provider)) {
            logger.info("[CODE_KEYS] Saved the \(provider.rawValue) key to its Code Keychain slot.")
        } else {
            logger.error("[CODE_KEYS] Could not save the \(provider.rawValue) key to its Code Keychain slot. CONSEQUENCE: this project still has it on the profile, but after switching to a project on another provider and back, its model is restored WITHOUT a key and the first send fails authentication.")
        }
    }

    static func key(for provider: ApiProvider) -> String? {
        ProviderKeyStore.load(for: slotID(for: provider))
    }
}
