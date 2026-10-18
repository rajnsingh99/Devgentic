// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CompatibleEndpointPreset.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: `ProviderConfig.init(from:)` throws on an unknown provider, so a new case would break older builds
/// One-click endpoints for the `.openAICompatible` provider, such as HuggingFace Inference Providers.
/// A preset, not an `ApiProvider` case, so saved profiles stay decodable by other builds.
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

    /// Presets in display order; HuggingFace is first because a user cannot otherwise guess its URL.
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
        Preset(
            name: "vLLM",
            url: "http://localhost:8000/v1",
            keyHint: nil,
            usesHuggingFaceToken: false
        ),
        Preset(
            name: "LocalAI",
            url: "http://localhost:8080/v1",
            keyHint: nil,
            usesHuggingFaceToken: false
        ),
        Preset(
            name: "Ollama",
            url: "http://localhost:11434/v1",
            keyHint: nil,
            usesHuggingFaceToken: false
        ),
    ]

    /// The preset a base URL currently matches, if any, so the UI can show which is selected.
    /// Compares the normalised origin and path, so a trailing slash or host case does not lose the match.
    nonisolated static func matching(_ baseURL: String?) -> Preset? {
        guard let baseURL else { return nil }
        // Why: folding the path would match `/V1` to the preset while the provider would POST to the wrong case-sensitive path
        // Lowercases scheme and host only; the path stays case-sensitive.
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
