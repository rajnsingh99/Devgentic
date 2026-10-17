// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolNameResolver.swift
//  Devgentic
//
//  Resolves emitted tool names against the runtime registry using three tiers:
//
//    1. Exact match    — emitted name is in `registeredTools`.
//    2. Alias map      — well-known hallucination → canonical (e.g. `final_summary` → `final_answer`).
//    3. Fuzzy match    — Jaro-Winkler similarity ≥ threshold AND arg-schema compatible.
//
//  The arg-schema compatibility gate prevents name-similar but semantically-unrelated
//  mismatches (e.g. `delete_file` → `delete_folder`). A fuzzy name is only promoted
//  if its arguments would fit the target tool's schema.
//
//  Also provides a forgive-then-audit path for argument *key* mismatches on otherwise-valid
//  tool calls (`filename` → `path`). Cloud providers occasionally emit these under prompt
//  pressure; rejecting them wastes an iteration when a clean rename would work.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ToolNameResolver")

// MARK: - Resolution Result

/// The outcome of resolving an emitted (toolName, arguments) pair against the registry.
enum ToolNameResolution: Sendable, Equatable {

    /// Exact match — no remapping needed.
    case exact(name: String, arguments: [String: JSONValue])

    /// Name was remapped to a registered tool via alias or fuzzy match.
    /// Arguments may also have been remapped via `ArgNameAliasResolver`.
    case remapped(
        originalName: String,
        canonicalName: String,
        arguments: [String: JSONValue],
        remappedArgKeys: [(from: String, to: String)]
    )

    /// Arguments didn't fit the target tool's schema even after alias rescue.
    /// Executor should surface `.argSchemaMismatch` as the parse failure.
    case argSchemaMismatch(
        originalName: String,
        canonicalName: String,
        missingArgs: [String],
        unexpectedArgs: [String]
    )

    /// No registered tool matches (by name, alias, or fuzzy). Executor should surface
    /// `.unknownToolName` with suggestions.
    case unknown(attempted: String, suggestions: [String])

    static func == (lhs: ToolNameResolution, rhs: ToolNameResolution) -> Bool {
        switch (lhs, rhs) {
        case (.exact(let n1, _), .exact(let n2, _)):
            return n1 == n2
        case (.remapped(let o1, let c1, _, _), .remapped(let o2, let c2, _, _)):
            return o1 == o2 && c1 == c2
        case (.argSchemaMismatch(let o1, let c1, let m1, let u1),
              .argSchemaMismatch(let o2, let c2, let m2, let u2)):
            return o1 == o2 && c1 == c2 && m1 == m2 && u1 == u2
        case (.unknown(let a1, let s1), .unknown(let a2, let s2)):
            return a1 == a2 && s1 == s2
        default:
            return false
        }
    }
}

// MARK: - Tool Name Resolver

struct ToolNameResolver: Sendable {

    /// Runtime tool registry for this agent invocation.
    let registeredTools: [AgentTool]

    /// Jaro-Winkler similarity threshold for fuzzy matching. Catches `finalanswer` → `final_answer`.
    ///
    /// ⚠️ READINESS CR-51 (2026-10-12). This comment used to claim 0.85 blocks `delete_file` →
    /// `delete_folder`. It does not: that pair scores ≈ 0.93, and `create_file` → `create_folder`
    /// ≈ 0.94 — so a `create_file(path: "notes.md", content: …)` the registry lacked ran as
    /// `create_folder`, made a DIRECTORY named `notes.md` and dropped the content. Similarity is not
    /// a safety gate. Two guards in `resolve` are: `namesDifferOnlyByTypos` (a different WORD is a
    /// different tool) and `carriesForeignArguments` (arguments the target doesn't take mean the
    /// model meant another tool).
    static let fuzzyThreshold: Double = 0.85

    /// Static alias table for well-known terminator hallucinations. These are the
    /// cases where weak local models reliably invent wrong names for the *exit*
    /// action — the arg-schema check still runs so we don't promote a garbage call.
    static let wellKnownAliases: [String: String] = [
        "final_summary":  "final_answer",
        "final_outcome":  "final_answer",
        "final_response": "final_answer",
        "final_result":   "final_answer",
        "final":          "final_answer",
        "finish":         "final_answer",
        "complete":       "final_answer",
        "done":           "final_answer",
        "respond":        "final_answer",
    ]

    init(registeredTools: [AgentTool]) {
        self.registeredTools = registeredTools
    }

    // MARK: - Primary API

    /// Resolves an emitted (name, args) pair against the registry.
    /// Never throws — returns a typed `ToolNameResolution` the caller interprets.
    func resolve(
        emittedName: String,
        arguments: [String: JSONValue]
    ) -> ToolNameResolution {
        // 1. Exact match
        if let tool = registeredTools.first(where: { $0.name == emittedName }) {
            // Even on exact match, try to repair any obvious arg-key mismatches (forgive-then-audit).
            let repaired = ArgNameAliasResolver.repair(arguments: arguments, forTool: tool)
            if repaired.missingArgs.isEmpty {
                if repaired.remappedKeys.isEmpty {
                    return .exact(name: tool.name, arguments: repaired.arguments)
                }
                logger.info("🔧 Arg keys repaired for '\(tool.name)': \(repaired.remappedKeys.map { "\($0.from)→\($0.to)" }.joined(separator: ", "))")
                return .remapped(
                    originalName: emittedName,
                    canonicalName: tool.name,
                    arguments: repaired.arguments,
                    remappedArgKeys: repaired.remappedKeys
                )
            }
            // Required args still missing even after repair — surface as typed mismatch.
            return .argSchemaMismatch(
                originalName: emittedName,
                canonicalName: tool.name,
                missingArgs: repaired.missingArgs,
                unexpectedArgs: repaired.unexpectedArgs
            )
        }

        // 2. Well-known alias
        if let canonical = Self.wellKnownAliases[emittedName],
           let tool = registeredTools.first(where: { $0.name == canonical }) {
            let repaired = ArgNameAliasResolver.repair(arguments: arguments, forTool: tool)
            if repaired.missingArgs.isEmpty {
                logger.info("🔧 Alias resolved: '\(emittedName)' → '\(tool.name)'")
                return .remapped(
                    originalName: emittedName,
                    canonicalName: tool.name,
                    arguments: repaired.arguments,
                    remappedArgKeys: repaired.remappedKeys
                )
            }
            return .argSchemaMismatch(
                originalName: emittedName,
                canonicalName: tool.name,
                missingArgs: repaired.missingArgs,
                unexpectedArgs: repaired.unexpectedArgs
            )
        }

        // 3. Fuzzy match — only promote if args fit AND the names are length-compatible
        // (#15.4: a typo keeps near-equal lengths; the length gate filters prefix-fragment
        // matches that Jaro-Winkler's prefix boost over-scores).
        let candidates = registeredTools
            .map { (tool: $0, score: Self.jaroWinkler(emittedName, $0.name)) }
            .filter { $0.score >= Self.fuzzyThreshold && Self.lengthCompatible(emittedName, $0.tool.name) }
            .filter { candidate in
                guard Self.namesDifferOnlyByTypos(emittedName, candidate.tool.name) else {
                    logger.notice("[TOOLRESOLVE] Fuzzy match '\(emittedName)' → '\(candidate.tool.name)' (jw=\(String(format: "%.2f", candidate.score))) REJECTED: the names differ by a whole word, not a typo. CONSEQUENCE: not run as that tool; the model is told the name is unknown and offered suggestions.")
                    return false
                }
                return true
            }
            .sorted { $0.score > $1.score }

        var foreignArgumentRejects = Set<String>()
        for (tool, score) in candidates {
            let repaired = ArgNameAliasResolver.repair(arguments: arguments, forTool: tool)
            if repaired.missingArgs.isEmpty, !repaired.unexpectedArgs.isEmpty {
                foreignArgumentRejects.insert(tool.name)
                logger.notice("[TOOLRESOLVE] Fuzzy match '\(emittedName)' → '\(tool.name)' (jw=\(String(format: "%.2f", score))) REJECTED: the call carries argument(s) \(repaired.unexpectedArgs.sorted()) that '\(tool.name)' doesn't take. CONSEQUENCE: not run — running it would silently drop those arguments; the model gets an argument-fit nudge instead.")
                continue
            }
            if repaired.missingArgs.isEmpty {
                logger.info("🔧 Fuzzy resolved: '\(emittedName)' → '\(tool.name)' (jw=\(String(format: "%.2f", score)))")
                return .remapped(
                    originalName: emittedName,
                    canonicalName: tool.name,
                    arguments: repaired.arguments,
                    remappedArgKeys: repaired.remappedKeys
                )
            }
        }

        // If we had fuzzy candidates but none were arg-compat, surface the best one
        // as a typed arg-mismatch so the model gets a targeted nudge about the fit.
        // A candidate rejected for FOREIGN arguments is skipped: the call is evidence the model
        // meant a different tool, so nudging it toward this one would be wrong — it falls through
        // to "unknown" with suggestions instead.
        if let bestCandidate = candidates.first(where: { !foreignArgumentRejects.contains($0.tool.name) }) {
            let repaired = ArgNameAliasResolver.repair(arguments: arguments, forTool: bestCandidate.tool)
            logger.info("⚠️ Fuzzy candidate '\(bestCandidate.tool.name)' rejected on arg fit for '\(emittedName)'")
            return .argSchemaMismatch(
                originalName: emittedName,
                canonicalName: bestCandidate.tool.name,
                missingArgs: repaired.missingArgs,
                unexpectedArgs: repaired.unexpectedArgs
            )
        }

        // 4. Totally unknown — return name-similarity suggestions (top 3 at lower threshold)
        let suggestions = registeredTools
            .map { (name: $0.name, score: Self.jaroWinkler(emittedName, $0.name)) }
            .filter { $0.score >= 0.65 }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map(\.name)

        logger.warning("❓ Unknown tool '\(emittedName)'; suggestions: \(suggestions.isEmpty ? "<none>" : suggestions.joined(separator: ", "))")
        return .unknown(attempted: emittedName, suggestions: Array(suggestions))
    }

    // MARK: - Word Gate (CR-51)

    /// Whether two tool names differ only by typos — the same words, possibly misspelt or joined —
    /// rather than by a whole word. `final_answr`/`final_answer` and `finalanswer`/`final_answer`
    /// pass; `create_file`/`create_folder` and `delete_file`/`delete_folder` don't.
    ///
    /// Names are split on `_`, `-` and `.`. With different word counts the names are compared with
    /// the separators removed (a joined or split word). With the same count, each word pair must be
    /// within a typo's distance: at most 1 edit (a swap counts as one), or 2 for words of 8+ characters.
    static func namesDifferOnlyByTypos(_ a: String, _ b: String) -> Bool {
        let separators: (Character) -> Bool = { $0 == "_" || $0 == "-" || $0 == "." }
        let aWords = a.lowercased().split(whereSeparator: separators).map(String.init)
        let bWords = b.lowercased().split(whereSeparator: separators).map(String.init)
        guard aWords.count == bWords.count else {
            return editDistance(aWords.joined(), bWords.joined()) <= 1
        }
        for (x, y) in zip(aWords, bWords) where x != y {
            let allowed = min(x.count, y.count) >= 8 ? 2 : 1
            if editDistance(x, y) > allowed { return false }
        }
        return true
    }

    /// Edit distance where a swap of two adjacent characters counts as ONE edit (optimal string
    /// alignment) — `fiel`/`file` is the typo it looks like, not two substitutions. Tool names are
    /// short, so the O(n·m) table is trivial.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    // MARK: - Length Gate

    /// Length-aware gate for fuzzy matches (#15.4). Jaro-Winkler's prefix boost can over-score
    /// a short emitted name against a much longer tool name (a prefix fragment, e.g. `read` →
    /// `read_file_recursive`, not a typo). Real typos keep near-equal lengths, so require the
    /// shorter name to be at least half the longer and at least 3 chars. The target tool's
    /// arg-schema check (in `resolve`) remains the primary guard against destructive remaps.
    static func lengthCompatible(_ a: String, _ b: String) -> Bool {
        let shorter = min(a.count, b.count)
        let longer = max(a.count, b.count)
        guard longer > 0 else { return false }
        return shorter >= 3 && Double(shorter) / Double(longer) >= 0.5
    }

    // MARK: - Jaro-Winkler Similarity

    /// Jaro-Winkler similarity in [0, 1]. Higher = more similar.
    /// Weighted toward common prefixes, which matches how LLMs hallucinate
    /// (they remember the stem, mangle the suffix). Pure function, thread-safe.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let jaro = jaroSimilarity(a, b)
        guard jaro > 0 else { return 0 }

        // Common prefix length, capped at 4 per the algorithm definition.
        let aChars = Array(a)
        let bChars = Array(b)
        var prefixLen = 0
        let maxPrefix = min(4, min(aChars.count, bChars.count))
        for i in 0..<maxPrefix {
            if aChars[i] == bChars[i] { prefixLen += 1 } else { break }
        }

        let scalingFactor = 0.1 // standard Winkler scaling factor
        return jaro + Double(prefixLen) * scalingFactor * (1 - jaro)
    }

    private static func jaroSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let aChars = Array(a)
        let bChars = Array(b)
        let matchWindow = max(aChars.count, bChars.count) / 2 - 1

        var aMatches = Array(repeating: false, count: aChars.count)
        var bMatches = Array(repeating: false, count: bChars.count)
        var matches = 0

        for i in 0..<aChars.count {
            let windowStart = max(0, i - matchWindow)
            let windowEnd = min(i + matchWindow + 1, bChars.count)
            guard windowStart < windowEnd else { continue }
            for j in windowStart..<windowEnd {
                if bMatches[j] { continue }
                if aChars[i] != bChars[j] { continue }
                aMatches[i] = true
                bMatches[j] = true
                matches += 1
                break
            }
        }

        guard matches > 0 else { return 0.0 }

        // Transpositions: count matched chars out of order
        var transpositions = 0
        var k = 0
        for i in 0..<aChars.count {
            if !aMatches[i] { continue }
            while !bMatches[k] { k += 1 }
            if aChars[i] != bChars[k] { transpositions += 1 }
            k += 1
        }
        let halfTrans = Double(transpositions) / 2.0
        let m = Double(matches)
        return (m / Double(aChars.count) + m / Double(bChars.count) + (m - halfTrans) / m) / 3.0
    }
}
