// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolResultBudget.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Which part of a result survives a cut

/// What to keep when a tool result is larger than the room the model has.
/// Chosen globally in the context gauge and per tool in its settings popover; `.automatic` exists because
/// the relevant part varies (a build log's verdict is at the end, a file's relevance at the start).
enum ContextCutStrategy: String, Codable, CaseIterable, Sendable {
    case automatic
    case keepStart
    case keepEnd
    case keepStartAndEnd

    var label: String {
        switch self {
        case .automatic:       "Automatic"
        case .keepStart:       "Start"
        case .keepEnd:         "End"
        case .keepStartAndEnd: "Start + end"
        }
    }

    /// The app-wide default, set from the context gauge. `UserDefaults` rather than the profile
    /// blob: the user asked for ONE global setting, and a per-profile field would be a profile
    /// schema change for what is a preference.
    static let defaultsKey = "contextCutStrategy"

    static var globalDefault: ContextCutStrategy {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(ContextCutStrategy.init(rawValue:)) ?? .automatic
    }

    /// What `.automatic` means for one tool — decided by the SHAPE of its output.
    static func automaticChoice(forTool toolName: String) -> ContextCutStrategy {
        switch toolName {
        // Command output: the verdict, the failing test, the final error are at the end.
        case "run_command", "get_task_output", "batch_command":
            return .keepEnd
        // Reads, listings, searches: what matters is what comes first.
        case "read_file", "list_directory", "glob_files", "project_tree", "file_overview",
             "find_definition", "code_search_text", "code_search_symbol", "code_search_files",
             "code_search", "spotlight_search", "web_search", "web_fetch":
            return .keepStart
        // Anything else — git, diffs, MCP servers we know nothing about: keep both ends.
        default:
            return .keepStartAndEnd
        }
    }

    /// Never `.automatic` — the concrete cut to apply.
    func resolved(forTool toolName: String) -> ContextCutStrategy {
        self == .automatic ? Self.automaticChoice(forTool: toolName) : self
    }
}

/// The strategies in force for one run: the global default plus any per-tool overrides from the
/// profile's Tool Library. Built once in `AgentConnect`, read by the native fit and the scratchpad.
struct ToolCutPolicy: Sendable, Equatable {
    var defaultStrategy: ContextCutStrategy = .automatic
    var overrides: [String: ContextCutStrategy] = [:]

    /// Per-tool override wins; otherwise the default. Always resolved to a concrete cut.
    func strategy(forTool toolName: String) -> ContextCutStrategy {
        (overrides[toolName] ?? defaultStrategy).resolved(forTool: toolName)
    }

    /// The policy for a run: the gauge's global setting plus each configured tool's override.
    static func forRun(tools: [Tool]) -> ToolCutPolicy {
        var policy = ToolCutPolicy(defaultStrategy: ContextCutStrategy.globalDefault)
        for tool in tools { if let s = tool.cutStrategy { policy.overrides[tool.name] = s } }
        return policy
    }
}

enum ToolResultBudget {

    /// Never cut a result below this, even when the prefix has already eaten the budget. A result
    /// that small is useless, and a prefix over budget is already being warned about by compaction.
    static let minimumChars = 1_000

    /// The most characters each of `resultsInBatch` results may carry: all the room that is free.
    /// `payloadBudgetChars` of 0 means not set (nothing is cut); `protectedChars` are the turns compaction never drops.
    /// Parallel results share the room; there is no ceiling below what fits, and no dependence on `maxIterations`.
    static func limit(payloadBudgetChars: Int, protectedChars: Int, resultsInBatch: Int) -> Int {
        guard payloadBudgetChars > 0 else { return Int.max }
        let room = (payloadBudgetChars - max(0, protectedChars)) / max(1, resultsInBatch)
        return max(minimumChars, room)
    }

    /// `raw`, cut to `limit` characters per `strategy`, with a note for the model on what is omitted and how to get it.
    /// Returned unchanged when it fits. `.automatic` is resolved by the caller (`ToolCutPolicy`); here it means start + end.
    static func fit(_ raw: String, limit: Int, strategy: ContextCutStrategy = .keepStartAndEnd) -> String {
        guard raw.count > limit else { return raw }
        // Sized with the largest count the note could print, so the result never exceeds `limit`.
        let keep = limit - omissionNote(raw.count, strategy).count
        guard keep >= 200 else {
            // Too small to cut usefully: the note alone would swamp it. Head only, still labelled.
            let label = "\n[… result truncated to fit the context]"
            return String(raw.prefix(max(0, limit - label.count))) + label
        }
        // Every cut lands on a line boundary so no kept part starts or ends mid-token; skipped when a part has no newline.
        // Snapping only shortens, so the result still fits.
        func headOf(_ n: Int) -> String {
            let head = String(raw.prefix(n))
            guard let lastBreak = head.lastIndex(of: "\n") else { return head }
            return String(head[..<lastBreak])
        }
        func tailOf(_ n: Int) -> String {
            let tail = String(raw.suffix(n))
            guard let firstBreak = tail.firstIndex(of: "\n") else { return tail }
            return String(tail[tail.index(after: firstBreak)...])
        }
        switch strategy {
        case .keepStart:
            let head = headOf(keep)
            return head + omissionNote(raw.count - head.count, strategy)
        case .keepEnd:
            let tail = tailOf(keep)
            return omissionNote(raw.count - tail.count, strategy) + tail
        case .keepStartAndEnd, .automatic:
            let head = headOf(keep / 2)
            let tail = tailOf(keep - keep / 2)
            return head + omissionNote(raw.count - head.count - tail.count, strategy) + tail
        }
    }

    private static func omissionNote(_ omitted: Int, _ strategy: ContextCutStrategy) -> String {
        let (where_, shown): (String, String) = switch strategy {
        case .keepStart:                   ("from the end", "The start is shown.")
        case .keepEnd:                     ("from the start", "The end is shown.")
        case .keepStartAndEnd, .automatic: ("from the middle", "The start and the end are shown.")
        }
        return "\n\n[… \(omitted) characters omitted \(where_) of this result to fit the context window. "
            + "\(shown) To see the omitted part, ask for a narrower slice — "
            + "a line range, a more specific search, or get_task_output with since_line.]\n\n"
    }
}
