// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CompatibleEndpointPreset.swift
//  Devgentic
//
//  Known endpoints that already work through "Custom (OpenAI-Compatible)".
//

import Foundation

/// One-click endpoints for the `.openAICompatible` provider.
///
/// ⚠️ THIS EXISTS BECAUSE THE CAPABILITY WAS ALREADY THERE AND UNFINDABLE. HuggingFace Inference
/// Providers speak the OpenAI wire format at `https://router.huggingface.co/v1`, so the existing
/// `.openAICompatible` path already drives them end to end — `OpenAILLMProvider` appends
/// `chat/completions`, streams SSE, and `AgentConnect` routes it through the native tool-call
/// generator, so Agent profiles work and not just Bot. Nothing needed building. What was missing
/// was any way for a user to discover it: the field is a bare URL box with a localhost hint.
///
/// ⚠️ A PRESET, NOT AN `ApiProvider` CASE. An 8th case would have to be handled in 23 exhaustive
/// switches across the app, and a profile saved under it cannot be decoded by an older build —
/// `ProviderConfig.init(from:)` THROWS on an unknown provider rather than falling back. A preset
/// buys the same user-visible capability for none of that, and leaves the door open to promote
/// HuggingFace to a first-class provider later if it earns its own model picker and rate limits.
enum CompatibleEndpointPreset {

    struct Preset: Equatable, Identifiable {
        let name: String
        let url: String
        /// What the endpoint's key looks like, shown beside the API Key field. Nil when the
        /// endpoint needs no key at all (a local server).
        let keyHint: String?
        /// True when `HuggingFaceTokenStore` holds the credential this endpoint wants, so the
        /// user can reuse the token they already pasted for model downloads.
        let usesHuggingFaceToken: Bool

        var id: String { name }
    }

    /// ⚠️ Order is the order shown. HuggingFace first: it is the one a user cannot otherwise
    /// guess, while a local server's URL is printed in that server's own UI.
    nonisolated static let all: [Preset] = [
        Preset(
            name: "HuggingFace",
            url: ProviderDefaults.huggingFaceRouterBaseURL.absoluteString,
            keyHint: "hf_…",
            usesHuggingFaceToken: true
        ),
        Preset(
            name: "LM Studio",
            url: ProviderDefaults.openAICompatibleHintURL.absoluteString,
            keyHint: nil,
            usesHuggingFaceToken: false
        ),
    ]

    /// The preset a base URL currently matches, if any — so the UI can show which is selected and
    /// offer the matching credential.
    ///
    /// Compares on the normalised origin+path so a trailing slash or a case difference in the
    /// host does not lose the match. Pure and `nonisolated`, in the house style, so the rule is
    /// testable without building any view.
    nonisolated static func matching(_ baseURL: String?) -> Preset? {
        guard let baseURL else { return nil }
        // ⚠️ SCHEME AND HOST ONLY. Lowercasing the whole string folded the PATH too, so
        // `https://router.huggingface.co/V1` matched the preset: the chip tinted as selected and
        // the "Use saved HuggingFace token" button appeared, asserting a known-good endpoint —
        // while `OpenAILLMProvider` would POST to `/V1/chat/completions`, and HTTP paths are
        // case-sensitive. Scheme and host are the only parts where case is insignificant.
        let normalise: (String) -> String? = { raw in
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            guard !s.isEmpty, var components = URLComponents(string: s) else { return nil }
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            return components.string
        }
        guard let target = normalise(baseURL) else { return nil }
        return all.first { normalise($0.url) == target }
    }
}
