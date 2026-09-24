// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ToolResultBudget.swift
//  Devgentic
//
//  How much of ONE tool result the model gets to see on the native tool-call path.
//
//  ⚠️⚠️ WHY THIS EXISTS (2026-09-24). The native path used to reuse the SCRATCHPAD's per-entry cap,
//  which was `8% of the window ÷ maxIterations`, floored at 200. For an 8K local model that is
//  `max(200, 2,620 ÷ 15)` = 200 characters — for every tool result, in every interface: Chat
//  agents, Code, workflow agent nodes and delegated sub-agents all run through `ReActAgentExecutor`.
//  A seven-task `command_output` listing reached the model as three lines; a 17-entry
//  `list_directory` reached it as three filenames and "(truncated listing)"; `read_file` could
//  barely show a function. Worse, the cap moved the WRONG way: a larger iteration budget made each
//  result SMALLER, because it divided by an iteration limit that is a safety stop, not an estimate of
//  how many results sit in context at once.
//
//  The scratchpad's budget was never the right instrument for this path. The native path carries
//  the whole conversation as turns, is bounded by `nativeContextBudgetChars`, and compacts the
//  OLDEST exchanges when it outgrows that — so the only thing a single result must not do is exceed
//  the room that compaction can never free: the budget minus the protected prefix (system prompt,
//  history, kickoff). That is what `limit` computes.
//

import Foundation

// MARK: - Which part of a result survives a cut

/// What to keep when a tool result is larger than the room the model has.
///
/// ⚠️ The user's choice (2026-09-24), offered in the context gauge (global) and in each tool's
/// settings popover (per-tool override). `.automatic` exists because no single answer is right:
/// a build log's verdict is at the END, a file's or a search's relevance is at the START, and a
/// traceback needs both.
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
        case "run_command", "command_output", "execute_shell", "batch_command":
            return .keepEnd
        // Reads, listings, searches: what matters is what comes first.
        case "read_file", "list_directory", "glob_files", "codebase_map", "file_overview",
             "find_definition", "code_search_text", "code_search_symbol", "code_search_files",
             "code_search", "fs_smart_search", "web_search", "web_fetch":
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

    /// The most characters each of `resultsInBatch` results may carry: ALL THE ROOM THAT IS FREE.
    ///
    /// - Parameters:
    ///   - payloadBudgetChars: `AgentInput.nativeContextBudgetChars`; 0 means "not set", and then
    ///     nothing is cut — there is no window to measure against, and guessing one is how the
    ///     200-character cap happened.
    ///   - protectedChars: the chars of the turns compaction will never drop.
    ///   - resultsInBatch: parallel results share the room; one result alone gets all of it.
    ///
    /// ⚠️ The user's rule (2026-09-24): NO LIMIT BELOW WHAT FITS. There was a second ceiling here —
    /// a third of the payload budget — that cut a result even when the room was free; it is gone.
    /// Managing the window is the user's call (the context gauge shows it); cutting under the room
    /// is not ours. ⚠️ Deliberately not a function of `maxIterations` either — see the file header.
    static func limit(payloadBudgetChars: Int, protectedChars: Int, resultsInBatch: Int) -> Int {
        guard payloadBudgetChars > 0 else { return Int.max }
        let room = (payloadBudgetChars - max(0, protectedChars)) / max(1, resultsInBatch)
        return max(minimumChars, room)
    }

    /// `raw`, cut to `limit` characters according to `strategy`, with a note saying exactly what
    /// was removed and how to get it. Returned unchanged when it already fits.
    ///
    /// ⚠️ The note is written for the MODEL. A bare "...[truncated]" told it nothing, and on
    /// 2026-09-24 it answered "(status truncated in output)" instead of asking for the rest.
    /// ⚠️ `.automatic` is resolved by the caller (`ToolCutPolicy`); here it means start + end.
    static func fit(_ raw: String, limit: Int, strategy: ContextCutStrategy = .keepStartAndEnd) -> String {
        guard raw.count > limit else { return raw }
        // Sized with the LARGEST count it could print (raw.count), so the final note — which
        // prints the smaller real count — can only be the same length or shorter. The result
        // therefore never exceeds `limit`.
        let keep = limit - omissionNote(raw.count, strategy).count
        guard keep >= 200 else {
            // Too small to cut usefully: the note alone would swamp it. Head only, still labelled.
            let label = "\n[… result truncated to fit the context]"
            return String(raw.prefix(max(0, limit - label.count))) + label
        }
        // Every cut lands on a LINE BOUNDARY, so no kept part ends or starts mid-token — the
        // 2026-09-21 build log reached the model ending in `Linting 'RangeStore+F`. Skipped when
        // a part holds no newline: one enormous line is better delivered clipped than dropped.
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
            + "a line range, a more specific search, or command_output with since_line.]\n\n"
    }
}
