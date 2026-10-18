// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatTemplateRepair.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Repairs known corruptions in downloaded chat templates before they render.
/// Repairs match the exact corrupt byte sequence only and are idempotent.
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
        // Qwen2.5-3B-Instruct-4bit ships doubled braces around the tool-call example inside the Jinja string literal.
        // `\\n` and `\\\"` below are the template's own escape sequences, not Swift rendering artifacts.
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
