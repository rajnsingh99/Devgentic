// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ModelCapabilityHeuristics.swift
//  Devgentic
//
//  Single source of truth for "does this model support tool calling?"
//  heuristics that can't be answered from template/tokenizer analysis alone.
//
//  Primary use case: reasoning-only fine-tunes (deepseek-r1, qwq, magistral,
//  OpenAI o-series) that DON'T support the `tools` parameter at the API layer,
//  but often inherit from a tool-capable base architecture (deepseek-r1:14b is
//  distilled from qwen2 — Ollama reports family="qwen2", which family-fallback
//  detection would otherwise classify as parallelActions).
//
//  This module is intentionally small: one pattern list, one match function.
//  Consumers (OllamaConnect, MLXTokenizerAnalyzer) should call `isReasoningOnly`
//  BEFORE their existing family/template heuristics and short-circuit to
//  `.none` capability when it matches.
//

import Foundation

enum ModelCapabilityHeuristics {

    /// Substring patterns identifying reasoning-only models that don't support
    /// native tool calling. Matched case-insensitively across model name, family,
    /// and families-array sources — different sources report different identifiers
    /// for the same model, so we check all of them.
    ///
    /// Patterns prefixed with `^` are anchored to the start of the string (not a
    /// substring match anywhere in the name). Used for short distinctive prefixes
    /// like `o1-`, `o3-`, `o4-` where substring matching would produce false
    /// positives (e.g. avoid matching `"pixtral-o3"` — a made-up example, but
    /// illustrates why anchoring matters for very short patterns).
    ///
    /// Explicit exclusions — DO NOT add to this list:
    ///   - `qwen3`: supports BOTH thinking AND tool calling. Adding it here would
    ///     incorrectly force `.none` for a tool-capable family.
    ///   - `claude-*-thinking`, `o4-mini` (with tool support): check per-model before
    ///     adding a family prefix.
    static let reasoningOnlyPatterns: [String] = [
        "deepseek-r1",   // DeepSeek-R1 family — reasoning-only
        "qwq",           // Alibaba QwQ — reasoning-only fine-tune
        "magistral",     // Mistral Magistral — reasoning-only
        "gpt-oss",       // OpenAI GPT-OSS — reasoning-only
        "^o1-",          // OpenAI o1 family (anchored — short prefix)
        "^o3-",          // OpenAI o3 family
        "^o4-",          // OpenAI o4 family
    ]

    /// Returns `true` if any of the provided name candidates matches a
    /// reasoning-only pattern. Strings are lowercased before comparison.
    ///
    /// Accepts multiple candidates because different detection paths have
    /// different identifiers available — e.g. Ollama's `/api/show` reports
    /// `family="qwen2"` for a distilled deepseek-r1 model, but the MODEL NAME
    /// still contains "deepseek-r1". Passing all three (name, family, families
    /// joined) ensures we catch the model regardless of which source preserves
    /// the reasoning-only identity.
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

    /// Model-name substrings identifying families whose instruction-tuned variants
    /// support native tool calling. Used for remote-catalog classification where
    /// we can't read `tokenizer_config.json` for chat-template inspection.
    ///
    /// Kept deliberately broad — false positives (e.g. a base non-instruct variant
    /// shown under "Tool Use") are less harmful than false negatives (popular
    /// tool-capable models like Qwen2.5 hidden entirely).
    ///
    /// NOT included: Gemma 1/2 (limited tool support), ancient Mistral-7B-v0.1/v0.2,
    /// base (non-instruct) models. Callers should AND-combine with
    /// `!isReasoningOnly(...)` to exclude reasoning-only distills.
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

    /// Returns `true` if the model name suggests a tool-capable family.
    /// Combines substring matches from `toolCapableFamilyPatterns` with explicit
    /// exclusion of reasoning-only distills (since those inherit base names like
    /// `deepseek-r1-distill-qwen-7b` but don't support tool use).
    static func isLikelyToolCapable(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        if isReasoningOnly(nameCandidates: modelId) { return false }
        return toolCapableFamilyPatterns.contains { lower.contains($0) }
    }
}
