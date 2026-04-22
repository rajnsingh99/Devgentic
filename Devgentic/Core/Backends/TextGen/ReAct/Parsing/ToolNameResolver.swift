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

    /// Jaro-Winkler similarity threshold for fuzzy matching.
    /// 0.85 is tight enough to avoid false positives like `delete_file` → `delete_folder`
    /// while still catching `finalanswer` → `final_answer`.
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

        // 3. Fuzzy match — only promote if args fit
        let candidates = registeredTools
            .map { (tool: $0, score: Self.jaroWinkler(emittedName, $0.name)) }
            .filter { $0.score >= Self.fuzzyThreshold }
            .sorted { $0.score > $1.score }

        for (tool, score) in candidates {
            let repaired = ArgNameAliasResolver.repair(arguments: arguments, forTool: tool)
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
        if let bestCandidate = candidates.first {
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
