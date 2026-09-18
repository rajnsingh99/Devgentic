// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  KnownModelContextWindows.swift
//  Devgentic
//
//  Static lookup table for known model context window sizes.
//  Used for system instruction length warnings in the prompt editor.
//  For local models (MLX/Ollama), the context window is read from ModelMetadata instead.
//

import Foundation

enum KnownModelContextWindows {

    /// Returns the context window size (in tokens) for a known cloud model.
    /// Returns `nil` for unknown models — callers should fall back gracefully.
    static func lookup(_ modelName: String) -> Int? {
        let lower = modelName.lowercased()

        // Anthropic Claude
        if lower.contains("claude") { return 200_000 }

        // OpenAI
        if lower.contains("gpt-4o") || lower.contains("gpt-4-turbo") { return 128_000 }
        if lower.contains("gpt-4") { return 8_192 }
        if lower.contains("gpt-3.5") { return 16_385 }
        if lower.contains("o1") || lower.contains("o3") || lower.contains("o4") { return 200_000 }

        // Google Gemini
        if lower.contains("gemini-2") || lower.contains("gemini-1.5") { return 1_048_576 }
        if lower.contains("gemini") { return 32_768 }

        return nil
    }

    /// Resolves the context window for a model, checking local metadata first,
    /// then falling back to the static lookup table.
    static func resolve(modelName: String, localContextWindow: Int?) -> Int? {
        localContextWindow ?? lookup(modelName)
    }
}
