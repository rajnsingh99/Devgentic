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
}
