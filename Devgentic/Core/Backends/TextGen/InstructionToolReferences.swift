// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  InstructionToolReferences.swift
//  Devgentic
//
//  Finds tool names in a profile's system instructions that the profile cannot actually call.
//
//  ⚠️ WHY (2026-10-04). Agent 3's instructions said "use fs_smart_search first". That tool had been
//  renamed `spotlight_search` nine days earlier, and the profile did not have it enabled under
//  either name — so every run told the model to call a tool that was not in its loadout. Nothing
//  said so: the `[TOOLS]` log line only lists what IS offered. The model coped by guessing paths,
//  costing a wasted step per run.
//
//  ⚠️ DESCRIBES, NEVER GATES (standing directive: capability metadata may label, never block). The
//  findings become an ADVISORY in `ProfileValidator` and a log line in `AgentConnect`; a profile
//  that mentions a tool it lacks still saves and still runs.
//
//  Matching is by EXACT name against declared vocabularies — the native catalogue, the injected
//  control-plane tools, and the retired-name lists — never by "looks like a tool". Only names
//  containing an underscore are considered, so prose words that happen to equal a one-word tool
//  name (`git`) are never flagged.
//

import Foundation

enum InstructionToolReference: Equatable, Sendable {
    /// A real tool, not enabled on this profile.
    case notEnabled(name: String)
    /// A tool that was renamed; `replacementEnabled` says whether the new name is in the loadout.
    case renamed(old: String, new: String, replacementEnabled: Bool)
    /// A tool that no longer exists.
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
    ///
    /// - Parameters:
    ///   - enabledToolNames: names the profile actually offers the model.
    ///   - knownToolNames: every real tool name (defaults to the native catalogue). Tests inject.
    ///   - alwaysAvailable: tools every run carries regardless of the profile (control plane).
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
