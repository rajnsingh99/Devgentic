// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderKeyShape.swift
//  Devgentic
//
//  Refuses to send an API key to a provider when the key's own prefix says it belongs to a
//  different vendor.
//
//  ⚠️ WHY (2026-09-27). Keys were stored per PROFILE then, and `switchProvider(to:)` kept the key
//  when the provider changed — so an Anthropic profile switched to OpenRouter sent its `sk-ant-…`
//  key to openrouter.ai on the first request. Since 2026-10-03 keys live once per PROVIDER
//  (`AppProviderKeyStore`), which removes that path, but not the root mistake: a key pasted into the
//  wrong provider's field is now stored as THAT provider's key and sent on every request to it.
//  This is the send-time backstop for both.
//
//  Deliberately narrow: it only speaks when a key carries a prefix that UNAMBIGUOUSLY names a vendor.
//  A bare `sk-…` could be OpenAI, DeepSeek, a LiteLLM proxy or anything else, so it is never
//  treated as evidence, and `.openAICompatible` is never checked — gateways legitimately accept
//  other vendors' keys.
//

import Foundation

enum ProviderKeyShape {

    /// Prefixes that identify exactly one vendor. Order matters: `sk-ant-`/`sk-or-` before the
    /// generic OpenAI project form.
    private static let vendorPrefixes: [(prefix: String, provider: ApiProvider)] = [
        ("sk-ant-", .anthropic),
        ("sk-or-", .openRouter),
        ("AIza", .google),
        ("sk-proj-", .openAI),
    ]

    /// The vendor this key evidently belongs to, when that is not `provider`; nil when the key
    /// matches `provider`, has no identifying prefix, or `provider` is not checked.
    static func mismatchedVendor(key: String?, provider: ApiProvider) -> ApiProvider? {
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        switch provider {
        case .anthropic, .openAI, .google, .openRouter: break
        case .openAICompatible, .ollama, .mlx: return nil
        }
        guard let owner = vendorPrefixes.first(where: { key.hasPrefix($0.prefix) })?.provider else { return nil }
        return owner == provider ? nil : owner
    }

    /// The user-facing refusal.
    static func refusalMessage(keyVendor: ApiProvider, provider: ApiProvider) -> String {
        "This profile's API key looks like a \(keyVendor.rawValue) key, but the profile uses \(provider.rawValue). "
            + "It was not sent. Paste a \(provider.rawValue) key in the profile's API Key field."
    }
}
