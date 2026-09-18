// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatTemplateRepair.swift
//  Devgentic
//
//  Repairs KNOWN corruptions in downloaded chat templates before they render.
//
//  WHY THIS EXISTS (field incident, 2026-08-21). `mlx-community/Qwen2.5-3B-Instruct-4bit` ships a
//  chat template whose tool-call formatting example reads, inside a Jinja string literal:
//
//      <tool_call>\n{{\"name\": <function-name>, \"arguments\": <args-json-object>}}\n</tool_call>
//
//  Inside a string literal, `{{` is two literal characters — so every renderer shows the model an
//  example with DOUBLED braces. The official Qwen template (verified against the installed
//  Qwen2.5-VL-3B and bodega-raptor copies) has single braces; this one artifact carries a Python
//  f-string escaping mistake by whoever converted it. At temperature 0.1 the model copies the
//  malformed example faithfully — `{{"name": ...}}` — which is invalid JSON, which the MLX
//  framework's strict tool-call decoder then silently discards, surfacing as "the model returned
//  nothing" after ~2s of real generation. Three debugging sessions and two wrong root causes
//  (sampling config, prompt wrapping) preceded the [PROMPT-RENDERED] dump that exposed it.
//
//  DESIGN RULES, in force for every repair added here:
//    1. EXACT-SUBSTRING ONLY. A repair keys on the full corrupt byte sequence, never on a shape
//       or a regex over template structure. The repo has a documented content-corruption class
//       (three transforms that silently rewrote payloads by shape-matching); this file must never
//       join it. The corrupt pattern below is not valid Jinja under any grammar — `{{\"name\": <x>`
//       cannot parse as an expression — so an exact match can never break a working template.
//    2. IDEMPOTENT. Repairing repaired output is a no-op, so the caller never needs to track
//       whether a template has already been through here.
//    3. NEVER FAILS. An unrecognised template passes through byte-identical with `applied` empty.
//       The caller decides what to do with the verdict; this type only rewrites what it can prove.
//    4. EVERY FIRING IS OBSERVABLE. Each repair carries a human-readable description that the
//       caller logs — a silent repair of someone else's artifact would be the same sin as the
//       silent discard this exists to prevent.
//
//  Applied at RENDER time (MLXService), not at extraction: the primary render path uses the
//  tokenizer's own embedded template, so sanitizing only the app's extracted copy would fix the
//  fallback path while the corrupt bytes kept reaching the model on the main one. The stored
//  `ChatTemplateSource.extracted` stays RAW on purpose — it is the evidence of what the artifact
//  actually shipped, and the analysis log's "(2509 chars)" stays true.
//

import Foundation

enum ChatTemplateRepair {

    /// One known corruption: the exact corrupt bytes, the exact correct bytes, and the
    /// description a caller must log when it fires.
    private struct KnownCorruption {
        let corrupt: String
        let fixed: String
        let description: String
    }

    /// The register of proven template corruptions. Additions require: the corrupt bytes observed
    /// in a real artifact, proof the pattern cannot occur in a valid template, and a test.
    private static let knownCorruptions: [KnownCorruption] = [
        // mlx-community/Qwen2.5-3B-Instruct-4bit (observed 2026-08-21): doubled braces around the
        // tool-call example inside the Jinja string literal. `\\n` and `\\\"` below are the
        // template's own escape sequences (backslash-n / backslash-quote INSIDE the Jinja string),
        // not Swift rendering artifacts.
        KnownCorruption(
            corrupt: "<tool_call>\\n{{\\\"name\\\": <function-name>, \\\"arguments\\\": <args-json-object>}}\\n</tool_call>",
            fixed: "<tool_call>\\n{\\\"name\\\": <function-name>, \\\"arguments\\\": <args-json-object>}\\n</tool_call>",
            description: "doubled-brace tool-call example ({{\"name\"...}} -> {\"name\"...}) — teaches the model to emit invalid JSON that the tool-call parser then discards"
        )
    ]

    /// The outcome: the (possibly rewritten) template plus a description of every repair applied,
    /// in register order. `applied.isEmpty` means the template passed through byte-identical.
    struct Result: Equatable {
        let template: String
        let applied: [String]
    }

    /// Applies every known corruption fix that matches. Pure, total, idempotent.
    nonisolated static func repair(_ template: String) -> Result {
        var repaired = template
        var applied: [String] = []
        for corruption in knownCorruptions where repaired.contains(corruption.corrupt) {
            repaired = repaired.replacingOccurrences(of: corruption.corrupt, with: corruption.fixed)
            applied.append(corruption.description)
        }
        return Result(template: repaired, applied: applied)
    }
}
