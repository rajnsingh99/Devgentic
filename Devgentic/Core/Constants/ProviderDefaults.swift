// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderDefaults.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Canonical default endpoints for every supported API provider.
/// Used by model-listing services, AgentConnect's runtime fallback, placeholder display and the ImageGen factories.
enum ProviderDefaults {

    // MARK: - Base URLs

    /// Anthropic Claude API root.
    static let anthropicBaseURL = URL(string: "https://api.anthropic.com/v1/")!

    /// OpenAI API root.
    static let openAIBaseURL = URL(string: "https://api.openai.com/v1/")!

    /// Google Gemini (Generative Language) API root.
    static let geminiBaseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!

    /// Ollama local server default.
    static let ollamaBaseURL = URL(string: "http://localhost:11434")!

    /// OpenRouter API root (OpenAI-compatible aggregator).
    static let openRouterBaseURL = URL(string: "https://openrouter.ai/api/v1/")!

    /// Placeholder/hint for a custom OpenAI-compatible endpoint. There is no
    /// canonical default (the user must supply one) — this is only the UI
    /// placeholder, pre-filled to LM Studio's local server for discoverability.
    static let openAICompatibleHintURL = URL(string: "http://localhost:1234/v1")!

    /// HuggingFace Inference Providers' OpenAI-compatible router, offered as a preset.
    /// Not in `baseURL(for:)`: no `ApiProvider` case maps to it, because `.openAICompatible` already drives it.
    static let huggingFaceRouterBaseURL = URL(string: "https://router.huggingface.co/v1")!

    // MARK: - Provider Lookup

    /// Returns the canonical default base URL for a given provider.
    static func baseURL(for provider: ApiProvider) -> URL {
        switch provider {
        case .anthropic:        return anthropicBaseURL
        case .openAI:           return openAIBaseURL
        case .google:           return geminiBaseURL
        case .ollama:           return ollamaBaseURL
        case .openRouter:       return openRouterBaseURL
        case .openAICompatible: return openAICompatibleHintURL
        case .mlx:              return URL(string: "local://mlx")!
        }
    }

    /// String form for UI display and config defaults.
    static func baseURLString(for provider: ApiProvider) -> String {
        switch provider {
        case .mlx: return "Local Engine"
        default:   return baseURL(for: provider).absoluteString
        }
    }

    // MARK: - Configured-endpoint resolution (register B21)

    private static let logger = DGLogger(category: "ProviderDefaults")

    /// Whether a URL can actually carry an API request: a real http(s) scheme and a non-empty host.
    /// `URL(string:)` is more permissive than usable (`"://nope"` parses). `http` stays allowed for local providers.
    static func isUsableEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    // Why: an unparseable endpoint falls back to the default and logs an error, since force-unwrapping a free-text field would crash.
    /// Resolves a profile's configured endpoint, falling back to the vendor default.
    /// Every request path uses this so a configured gateway is honoured everywhere, never only for model listing.
    static func resolvedBaseURL(configured: String?, fallback: URL) -> URL {
        guard let configured, !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isUsableEndpoint(url) else {
            logger.error(
                "[PROFILE] The configured endpoint '\(trimmed)' is not a usable URL. CONSEQUENCE: "
                + "this request goes to the DEFAULT host \(fallback.absoluteString) instead — "
                + "including its API key. Fix the endpoint field or clear it."
            )
            return fallback
        }
        return url
    }

    /// Same resolution, for a provider's canonical default.
    static func resolvedBaseURL(configured: String?, for provider: ApiProvider) -> URL {
        resolvedBaseURL(configured: configured, fallback: baseURL(for: provider))
    }
}
