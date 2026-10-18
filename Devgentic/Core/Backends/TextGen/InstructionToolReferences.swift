// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InstructionToolReferences.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Finds tool names in a profile's system instructions that the profile cannot actually call.
/// Findings are advisory and logged, never a gate; matching is by exact name against declared vocabularies.
/// Only names containing an underscore are considered, so one-word prose like `git` is never flagged.
enum InstructionToolReference: Equatable, Sendable {
    /// A real tool, not enabled on this profile.
    case notEnabled(name: String)
    /// A tool that was renamed; `replacementEnabled` says whether the new name is in the loadout.
    case renamed(old: String, new: String, replacementEnabled: Bool)
    /// A tool name from the retired-name lists.
    case removed(name: String)

    var name: String {
        switch self {
        case .notEnabled(let name), .removed(let name): return name
        case .renamed(let old, _, _): return old
        }
    }

    /// One user-facing sentence.
    var message: String {
        switch self {
        case .notEnabled(let name):
            return "Instructions mention `\(name)`, which isn't enabled for this profile. Enable it in the Tool Library, or remove it from the instructions."
        case .renamed(let old, let new, true):
            return "Instructions mention `\(old)`, which was renamed to `\(new)`. Update the instructions to use `\(new)`."
        case .renamed(let old, let new, false):
            return "Instructions mention `\(old)`, which was renamed to `\(new)` — and `\(new)` isn't enabled for this profile either. Update the instructions, and enable `\(new)` if the agent needs it."
        case .removed(let name):
            return "Instructions mention `\(name)`, which no longer exists. Remove it from the instructions."
        }
    }
}

enum InstructionToolReferences {

    /// Snake_case identifiers: at least one underscore, letters/digits otherwise.
    private static let identifierPattern = try! NSRegularExpression(pattern: #"\b[A-Za-z][A-Za-z0-9]*(?:_[A-Za-z0-9]+)+\b"#)

    /// The findings for `instructions`, in order of first mention, one per name.
    /// - Parameters: `enabledToolNames` is what the profile offers; `knownToolNames` defaults to the native catalogue.
    ///   `alwaysAvailable` lists control-plane tools every run carries regardless of the profile.
    static func check(
        instructions: String?,
        enabledToolNames: Set<String>,
        knownToolNames: Set<String> = NativeToolCatalog.allToolNames,
        alwaysAvailable: Set<String> = NativeToolCatalog.injectedToolNames,
        renamed: [String: String] = NativeToolCatalog.renamedTools,
        removed: Set<String> = NativeToolCatalog.removedTools
    ) -> [InstructionToolReference] {
        guard let instructions, !instructions.isEmpty else { return [] }
        let available = enabledToolNames.union(alwaysAvailable)
        let range = NSRange(instructions.startIndex..., in: instructions)

        var seen = Set<String>()
        var findings: [InstructionToolReference] = []
        for match in identifierPattern.matches(in: instructions, range: range) {
            guard let r = Range(match.range, in: instructions) else { continue }
            let name = String(instructions[r])
            guard seen.insert(name).inserted, !available.contains(name) else { continue }

            if let new = renamed[name] {
                findings.append(.renamed(old: name, new: new, replacementEnabled: available.contains(new)))
            } else if removed.contains(name) {
                findings.append(.removed(name: name))
            } else if knownToolNames.contains(name) {
                findings.append(.notEnabled(name: name))
            }
            // Anything else is prose (`user_name`, `report_1_log`) — not ours to judge.
        }
        return findings
    }
}
