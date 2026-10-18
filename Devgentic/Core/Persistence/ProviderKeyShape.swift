// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderKeyShape.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Refuses to send an API key to a provider when the key's own prefix says it belongs to a different
/// vendor. Narrow: only an unambiguous vendor prefix counts; a bare `sk-` is never evidence and
/// `.openAICompatible` is never checked.
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
