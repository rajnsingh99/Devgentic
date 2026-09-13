// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ProviderDefaults.swift
//  Devgentic
//
//  Created by Raj Singh on 27/03/26.
//
//  Single source of truth for all provider endpoint defaults.
//  Every service, provider, factory, and UI view resolves its default
//  base URL from this file — no hardcoded URL strings anywhere else.
//

import Foundation

/// Canonical default endpoints for every supported API provider.
///
/// Usage:
/// - **Services** (model listing): `ProviderDefaults.anthropicBaseURL.appendingPathComponent("models")`
/// - **AgentConnect** (runtime fallback): `ProviderDefaults.baseURL(for: provider)`
/// - **UI** (placeholder display): `ProviderDefaults.baseURLString(for: provider)`
/// - **ImageGen factories**: `ProviderDefaults.openAIBaseURL` etc.
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

    /// HuggingFace Inference Providers' OpenAI-compatible router.
    ///
    /// ⚠️ NOT in `baseURL(for:)` below — no `ApiProvider` case maps to it. HuggingFace needs no
    /// provider of its own: the router speaks the OpenAI wire format, so `.openAICompatible`
    /// already drives it end to end, native tool calls included. What was missing was any way to
    /// FIND that out; this constant exists to be offered as a preset.
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

    /// Resolves a profile's configured endpoint, falling back to the vendor default.
    ///
    /// ⚠️ EXTRACTED because the three call sites that needed it had three different behaviours, one
    /// of which was "ignore the setting entirely". `GeminiImageGenService` hardcoded
    /// `geminiBaseURL` in both request builders while `GeminiService.verifyAndFetchModels` — the
    /// model list for the SAME profile — honoured `baseURL`. So a profile pointed at a corporate
    /// gateway listed its models through the gateway and then sent its gateway-scoped key to
    /// `generativelanguage.googleapis.com` on every actual request: a credential leaving the
    /// network it was issued for, to a host the user explicitly configured away from.
    ///
    /// ⚠️ An unparseable endpoint falls back rather than crashing. `OpenAIImageGenService` did
    /// `URL(string: base)!` on a free-text field, so "my gateway" (or a pasted URL with a space)
    /// was a force-unwrap crash on the first generate. Falling back is the wrong host too — hence
    /// the error log; but the failure is now visible and survivable instead of terminal.
    /// Whether a URL can actually carry an API request.
    ///
    /// ⚠️ `URL(string:)` is far more permissive than "usable". `"://nope"` parses with an EMPTY
    /// scheme and a host of `nope`, and `"http:///path"` parses with no host at all — a
    /// `scheme != nil, host != nil` check waves both through, and `URLSession` then fails on
    /// something the user was told was fine. Requiring a real HTTP scheme also rejects a pasted
    /// `file://` path. `http` stays allowed: `http://localhost` is how the local providers work,
    /// and A52 warns about plaintext transport rather than blocking it.
    static func isUsableEndpoint(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

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
