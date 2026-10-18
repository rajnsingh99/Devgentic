// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ArgNameAliasResolver.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "ArgNameAliasResolver")

// MARK: - Repair Result

/// The outcome of attempting to repair an emitted argument dict against a tool's schema.
struct ArgRepairResult: Sendable {
    /// The (possibly remapped) argument dict.
    let arguments: [String: JSONValue]
    /// Which emitted keys were renamed to canonical ones.
    let remappedKeys: [(from: String, to: String)]
    /// Required schema keys still missing after repair.
    let missingArgs: [String]
    /// Emitted keys that don't match any schema key or alias.
    /// Kept in `arguments` — we forgive extras rather than drop them, so the
    /// tool implementation can decide whether to ignore or error on them.
    let unexpectedArgs: [String]
}

// MARK: - Resolver

enum ArgNameAliasResolver {

    /// Alias map: emitted key → canonical key.
    /// Keys are normalized to lowercase for matching; canonical values keep their schema casing.
    /// Order within value list doesn't matter — a canonical target is looked up in the tool's
    /// declared properties before remapping.
    private static let aliasTable: [String: [String]] = [
        // file path variants
        "path":          ["filepath", "file_path", "filename", "file_name", "file", "filePath", "fileName"],
        "directory":     ["dir", "folder", "dirpath", "dir_path", "folder_path"],
        "source":        ["src", "from", "source_path", "src_path"],
        "destination":   ["dest", "dst", "to", "destination_path", "dest_path", "target"],

        // content / text variants
        "content":       ["text", "body", "data", "payload"],
        "text":          ["content", "body"],

        // search / query variants
        "query":         ["q", "search", "search_query", "searchQuery", "term", "search_term"],
        "pattern":       ["regex", "regexp", "expr", "expression"],
        "search_term":   ["term", "query", "q"],

        // command / shell variants
        "command":       ["cmd", "shell_command", "script", "exec"],

        // terminator variants (final_answer accepts several)
        "answer":        ["response", "content", "text", "message", "final_answer", "summary", "output"],

        // http variants
        "url":           ["uri", "endpoint", "link"],
        "method":        ["verb", "http_method"],

        // question / prompt variants (ask_user)
        "question":      ["prompt", "query", "ask"],
    ]

    /// Attempts to repair the emitted argument dict so it fits `tool.parameters`.
    /// Conservative: only aliases declared in `aliasTable` are remapped. Keys with
    /// no declared alias that aren't in the schema are preserved as "unexpected".
    static func repair(arguments: [String: JSONValue], forTool tool: AgentTool) -> ArgRepairResult {
        let schemaKeys = Set(tool.parameters.properties.keys)
        let requiredKeys = Set(tool.parameters.required)

        // Fast path: all emitted keys already match schema, all required present.
        let emittedKeys = Set(arguments.keys)
        if emittedKeys.isSuperset(of: requiredKeys) && emittedKeys.isSubset(of: schemaKeys) {
            return ArgRepairResult(
                arguments: arguments,
                remappedKeys: [],
                missingArgs: [],
                unexpectedArgs: []
            )
        }

        var repaired: [String: JSONValue] = [:]
        var remapped: [(from: String, to: String)] = []
        var unexpected: [String] = []

        for (emittedKey, value) in arguments {
            // Already canonical
            if schemaKeys.contains(emittedKey) {
                repaired[emittedKey] = value
                continue
            }

            // Look for an alias that resolves to a schema key
            if let canonical = findCanonical(for: emittedKey, in: schemaKeys) {
                // Don't overwrite if the canonical key is already present — the model
                // supplied both, keep the explicit one and drop the alias.
                if repaired[canonical] == nil {
                    repaired[canonical] = value
                    remapped.append((from: emittedKey, to: canonical))
                }
                continue
            }

            // Unknown key — keep it so the tool can error on it if it wants.
            repaired[emittedKey] = value
            unexpected.append(emittedKey)
        }

        let present = Set(repaired.keys)
        let missing = requiredKeys.subtracting(present).sorted()

        if !remapped.isEmpty || !missing.isEmpty || !unexpected.isEmpty {
            logger.debug("Arg repair for '\(tool.name)': remapped=\(remapped.map { "\($0.from)→\($0.to)" }), missing=\(missing), unexpected=\(unexpected)")
        }

        return ArgRepairResult(
            arguments: repaired,
            remappedKeys: remapped,
            missingArgs: missing,
            unexpectedArgs: unexpected
        )
    }

    // MARK: - Internals

    /// Finds a canonical schema key that `emittedKey` is a known alias for.
    /// Checks both directions: emitted key appears as an alias for a canonical,
    /// AND the canonical is actually in the target tool's schema.
    private static func findCanonical(for emittedKey: String, in schemaKeys: Set<String>) -> String? {
        let lowered = emittedKey.lowercased()

        for (canonical, aliases) in aliasTable {
            // Skip canonicals not in this tool's schema
            guard schemaKeys.contains(canonical) else { continue }

            // Check alias list (case-insensitive)
            for alias in aliases where alias.lowercased() == lowered {
                return canonical
            }
        }

        // Last-ditch: case-insensitive schema match (camelCase vs snake_case only)
        for schemaKey in schemaKeys where schemaKey.lowercased() == lowered && schemaKey != emittedKey {
            return schemaKey
        }

        return nil
    }
}
