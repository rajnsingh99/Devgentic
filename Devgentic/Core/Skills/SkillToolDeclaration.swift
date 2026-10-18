// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillToolDeclaration.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Reads a skill's `allowed-tools` frontmatter declaration and reports what it means in this app,
/// making it visible. It does not translate tool names or enforce the declaration; the profile's tools
/// still decide what runs.
enum SkillToolDeclaration {

    // MARK: - Caps

    /// Most elements kept from one declaration. Anything past this is dropped and REPORTED.
    static let maxElements = 32

    /// Most characters kept per element. A real tool name is well under 40; this is slack for
    /// scoped forms like `Bash(git add:*)`, not an invitation.
    static let maxElementChars = 96

    // MARK: - Status

    /// What a declared name means for the profile being looked at.
    enum Status: Equatable, Sendable {

        /// Exact match for a tool this profile actually has.
        case availableHere

        /// A name this app knows, that this profile has not enabled. The skill's steps that need it
        /// will fail; the user can fix it in the Tool Library.
        case knownButNotInThisProfile

        /// Not a name this app has: usually a Claude Code name (`Read`, `Bash`), a typo, or an MCP tool from a
        /// disconnected server. Reported as unknown to this app, never as "you do not have it".
        case foreign
    }

    struct Entry: Equatable, Sendable, Identifiable {
        /// The author's text, sanitized for display but never rewritten into another vocabulary.
        let declared: String
        let status: Status
        /// Secondary prose for a recognised foreign name. Never replaces `declared`.
        let hint: String?
        var id: String { declared }
    }

    struct Reading: Equatable, Sendable {
        var entries: [Entry] = []
        /// Elements dropped by `maxElements`. Surfaced so a truncated list never reads as complete.
        var droppedForCount = 0
        /// True when the author wrote `allowed-tools: []` — "no tools", which is not the same as
        /// saying nothing at all.
        var declaresNone = false
    }

    // MARK: - Reading

    /// Classifies a declaration against what the app knows and what this profile has.
    /// `declared` is as parsed (nil is absent, not `[]`); `knownToApp` is matched case-sensitively.
    /// `availableHere` is the profile's resolved names, nil when no profile is in context.
    static func classify(
        _ declared: [String]?,
        knownToApp: Set<String>,
        availableHere: Set<String>?
    ) -> Reading? {
        guard let declared else { return nil }

        var reading = Reading()
        reading.declaresNone = declared.isEmpty

        let sanitized = declared.compactMap(sanitize(_:))
        if sanitized.count > maxElements {
            reading.droppedForCount = sanitized.count - maxElements
        }

        reading.entries = sanitized.prefix(maxElements).map { element in
            let base = baseName(of: element)
            let status: Status
            if availableHere?.contains(base) == true {
                status = .availableHere
            } else if knownToApp.contains(base) {
                status = .knownButNotInThisProfile
            } else {
                status = .foreign
            }
            return Entry(
                declared: element,
                status: status,
                hint: status == .foreign ? foreignHint(for: base)?.prose : nil
            )
        }
        return reading
    }

    /// The name before any scope parenthesis: `Bash(git add:*)` becomes `Bash`.
    /// Scoped forms must not be matched whole, or they would read as a typo.
    static func baseName(of element: String) -> String {
        guard let paren = element.firstIndex(of: "(") else { return element }
        return String(element[element.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
    }

    /// Collapses control characters and whitespace runs, caps length, drops empties.
    /// Elements come straight off disk with no charset or length check, and reach a label and a log line.
    static func sanitize(_ element: String) -> String? {
        let collapsed = element
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxElementChars else { return collapsed }
        return String(collapsed.prefix(maxElementChars)) + "…"
    }

    // MARK: - Foreign vocabulary hints (display copy, drift-tested)

    /// Prose shown beside a recognised Claude Code name, plus the native names that prose mentions.
    /// `candidates` is not used for matching; a drift test asserts each still exists in
    /// `NativeToolCatalog`.
    struct ForeignHint: Sendable {
        let prose: String
        let candidates: [String]
    }

    /// Recognised names from Claude Code's vocabulary.
    /// `Task`, `TodoWrite`, `NotebookEdit`, `SlashCommand` and `mcp__*` have no analogue here, so they get
    /// no hint.
    static let foreignHints: [String: ForeignHint] = [
        "Read": ForeignHint(
            prose: "Claude Code's file reader. The closest here is read_file — it also handles DOCX, XLSX and PPTX, but not notebooks or images.",
            candidates: ["read_file"]),
        "Write": ForeignHint(
            prose: "Claude Code's file writer. Here that is create_new_file for a new file, or overwrite_file to replace one.",
            candidates: ["create_new_file", "overwrite_file"]),
        "Edit": ForeignHint(
            prose: "Claude Code's in-place editor. Here that is edit_code_single, or edit_code_batch for several edits to one file.",
            candidates: ["edit_code_single", "edit_code_batch"]),
        "Bash": ForeignHint(
            prose: "A shell. Here that is run_command, with start_background_task for something you will not wait for.",
            candidates: ["run_command", "start_background_task"]),
        "Glob": ForeignHint(
            prose: "Filename pattern matching. The closest here is glob_files.",
            candidates: ["glob_files"]),
        "Grep": ForeignHint(
            prose: "Content search. The closest here is code_search_text, or code_search_files.",
            candidates: ["code_search_text", "code_search_files"]),
        "WebFetch": ForeignHint(
            prose: "Fetching a URL. The closest here is http_request.",
            candidates: ["http_request"])
    ]

    static func foreignHint(for baseName: String) -> ForeignHint? { foreignHints[baseName] }
}
