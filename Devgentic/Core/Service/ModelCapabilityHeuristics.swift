// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCapabilityHeuristics.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Heuristics for whether a model supports tool calling that template or tokenizer analysis cannot answer, chiefly for
/// reasoning-only models (deepseek-r1, qwq, magistral, OpenAI o-series). Callers check `isReasoningOnly` before family or
/// template heuristics and short-circuit to `.none` when it matches.
enum ModelCapabilityHeuristics {

    // Why: do not add `qwen3` (supports thinking AND tool calling); check `claude-*-thinking` and `o4-mini` per model first.
    /// Substring patterns identifying reasoning-only models that don't support native tool calling.
    /// Matched case-insensitively across name, family and families; a `^` prefix anchors to the start of the string.
    static let reasoningOnlyPatterns: [String] = [
        "deepseek-r1",   // DeepSeek-R1 family — reasoning-only
        "qwq",           // Alibaba QwQ — reasoning-only fine-tune
        "magistral",     // Mistral Magistral — reasoning-only
        "gpt-oss",       // OpenAI GPT-OSS — reasoning-only
        "^o1-",          // OpenAI o1 family (anchored — short prefix)
        "^o3-",          // OpenAI o3 family
        "^o4-",          // OpenAI o4 family
    ]

    /// Returns true if any name candidate matches a reasoning-only pattern, comparing lowercased strings.
    /// Takes several candidates because sources differ: a distilled deepseek-r1 reports family "qwen2", but its
    /// name still matches.
    static func isReasoningOnly(nameCandidates: String...) -> Bool {
        isReasoningOnly(in: nameCandidates)
    }

    /// Array form for callers that already have `[String]`. Variadic version above
    /// forwards to this to avoid duplicating the match logic.
    static func isReasoningOnly(in candidates: [String]) -> Bool {
        let lowered = candidates.map { $0.lowercased() }
        return reasoningOnlyPatterns.contains { pattern in
            if pattern.hasPrefix("^") {
                let prefix = String(pattern.dropFirst())
                return lowered.contains { $0.hasPrefix(prefix) }
            }
            return lowered.contains { $0.contains(pattern) }
        }
    }

    /// Model-name substrings of families whose instruction-tuned variants support native tool calling, for remote-catalog
    /// classification where chat templates cannot be inspected. Kept broad: a false positive costs less than hiding
    /// tool-capable models. Callers should AND with `!isReasoningOnly(...)`.
    static let toolCapableFamilyPatterns: [String] = [
        // Explicit tool-use indicators
        "tool", "function", "hermes", "firefunction", "gorilla", "nexusraven",
        // Qwen 2.5+ and Qwen 3 support tool calls natively
        "qwen2.5", "qwen-2.5", "qwen3", "qwen-3",
        // Llama 3.1+ supports tool calls; 3.0 does not
        "llama-3.1", "llama3.1", "llama-3.2", "llama3.2", "llama-3.3", "llama3.3",
        // Mistral: Nemo, Small v2+, Large, Ministral, Mixtral 8x22B, v0.3 instruct
        "mistral-nemo", "mistral-small", "mistral-large", "ministral",
        "mixtral-8x22b", "mistral-7b-instruct-v0.3",
        // Phi 3.5+ and Phi 4
        "phi-3.5", "phi3.5", "phi-4", "phi4",
        // Cohere Command-R / R+
        "command-r", "command_r", "commandr",
        // IBM Granite 3+
        "granite-3", "granite3",
        // Mistral Devstral
        "devstral",
        // THUDM GLM-4+
        "glm-4", "glm4", "glm-4.5", "glm4.5",
        // DeepSeek V2+ (V2/V3/Coder-V2) — reasoning-only variants filtered separately
        "deepseek-v2", "deepseek-v3", "deepseek-coder-v2",
        // Moonshot Kimi K2+
        "kimi-k2", "kimi2",
        // Yi 1.5 Large
        "yi-1.5-34b", "yi-large",
    ]

    /// Returns true if the model name suggests a tool-capable family, excluding reasoning-only distills
    /// (e.g. `deepseek-r1-distill-qwen-7b` inherits a base name but does not support tool use).
    static func isLikelyToolCapable(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        if isReasoningOnly(nameCandidates: modelId) { return false }
        return toolCapableFamilyPatterns.contains { lower.contains($0) }
    }
}
