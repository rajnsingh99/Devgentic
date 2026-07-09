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
}
