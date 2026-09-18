// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillToolDeclaration.swift
//  Devgentic
//
//  Reads a skill's `allowed-tools` frontmatter declaration and says what it means HERE.
//
//  ## What this does, and the three things it deliberately does not
//
//  A SKILL.md may declare `allowed-tools: Read, Grep`. In Claude Code that RESTRICTS the tools
//  available while the skill runs. This app carried the field as far as a dictionary and then
//  dropped it, so a skill declaring two read-only tools imported clean and ran with whatever the
//  profile had, shell included, with nothing shown to anyone.
//
//  This type closes that by making the declaration VISIBLE. It does not close it by enforcing.
//
//  ### 1. It does not translate names
//
//  The obvious design is a table: `Bash → execute_shell`, `Read → read_file`. It is wrong here, for
//  reasons that are properties of this codebase rather than matters of taste:
//
//    - **The target depends on the profile.** `execute_shell` is `.libraryExceptCode` and is hidden
//      outright in a Code profile, where `batch_command` is the shell tool. `Bash → execute_shell`
//      is therefore wrong for exactly the profile kind most likely to run a code-shaped skill. A
//      static table has no profile in hand; the right answer is not a function of the string alone.
//    - **Several are 1:N in both directions.** `Edit` is `edit_code` outside Code and
//      `edit_code_single`/`edit_code_batch` inside it; `Write` is `write_file`/`create_file` or
//      `create_new_file`/`overwrite_file`. `Read` is not even a superset — it covers notebooks and
//      images this app cannot read, and misses the DOCX/XLSX/PPTX that `read_file` handles.
//    - **It would be hand-maintained list #3.** `NativeToolCatalog`'s own header records what two
//      unchecked parallel lists cost last time: 11 unreachable tools, 25 dispatchable tools in no
//      picker, one struct dispatched under two names. A `[String: String]` of native names as
//      string literals has no compile-time link to the catalogue and no drift test can see it.
//    - **MCP servers choose their own names.** Nothing reserves `Read` or `Bash`. Rewriting a
//      declared `Bash` to `execute_shell` on a profile whose MCP server offers a `Bash` would point
//      the user at a different program with different limits — the exact substitution
//      `AgentConnect` paid to remove at the dispatch layer.
//
//  And the decisive one: translation destroys the single most useful bit in the string — that the
//  name is FOREIGN. Verbatim `Bash` reads as "written for Claude Code, wants a shell". Rendered as
//  `execute_shell` it reads as a tool the user already has in their own library.
//
//  So the declared text is shown exactly as the author wrote it, always. Recognised foreign names
//  get a secondary PROSE hint, and the hint's candidate names are drift-tested against the
//  catalogue so they cannot rot into a lie.
//
//  ### 2. It does not gate anything
//
//  Nothing consults this before dispatching a tool call, and `classify` returns a description, not
//  a decision. The neighbouring precedent is exact: the profile's skills card used to auto-add
//  `execute_shell` when a skill bundled a `scripts/` directory, and that was removed because a
//  disk-shaped fact was deciding a capability — "capability metadata describes; it never enforces"
//  (invariant 14). What survives of it is `SkillCapabilityHints`, which only ever returns a Bool for
//  a sentence and a button. `allowed-tools` is the same input class with WEAKER evidence:
//  `hasScripts` is an observed filesystem fact, this is a free-text claim by the author of a file
//  that may have arrived in a .zip. If a directory listing was not trustworthy enough to name a
//  capability, a string in frontmatter is not either.
//
//  ⚠️ Honouring it as a NARROWING — subtract-only, never grant — is a coherent position and the
//  machinery exists (the G6 per-iteration gate in `ReActAgentExecutor` already filters the schema
//  and refuses dispatch). It is not built here because it is the user's call to make, not a default
//  to pick.
//
//  ### 3. It does not reach the model
//
//  These strings are not put into the prompt or into a tool result. Two reasons, both concrete:
//  foreign names in context invite `Bash` calls that land in the hallucinated-tool path and burn
//  iterations against the circuit breaker; and an element is the least-validated string in the
//  whole skill format — `name` is charset-validated, `description` is collapsed and capped, and
//  this had no validation at all. Rendering author-controlled text inside a sentence spoken in the
//  APP's voice ("you may use X") would hand an imported file a way to assert things about the
//  user's configuration that the model has every reason to trust more than the skill body.
//
//  The caps below exist anyway, because this text does reach the UI and the log.
//

import Foundation

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

        /// Not a name this app has. Almost always a Claude Code name (`Read`, `Bash`), sometimes a
        /// typo, sometimes an MCP tool from a server that is not connected.
        ///
        /// ⚠️ Reported as "this app does not know it", never as "you do not have it". The second is
        /// a claim about the user's configuration that this app is not entitled to make about a
        /// name from a foreign vocabulary.
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
    ///
    /// - Parameters:
    ///   - declared: elements exactly as parsed from the frontmatter. Nil means the field was
    ///     absent, which is NOT the same as `[]`.
    ///   - knownToApp: every tool name this app can dispatch — native catalogue plus any resolved
    ///     MCP names. Matched CASE-SENSITIVELY: native names are lowercase `snake_case` and Claude
    ///     Code's are PascalCase, so a case-insensitive match would only ever create false hits,
    ///     and `task`/`edit`/`read` are plausible MCP tool names.
    ///   - availableHere: the tool names this profile resolved. Nil when there is no profile in
    ///     context (the library, which is profile-independent) — every known name then reads as
    ///     `knownButNotInThisProfile`, since no profile has been named to check against.
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

    /// The name before any scope parenthesis: `Bash(git add:*)` → `Bash`.
    ///
    /// Scoped forms are a real part of the format and must not be matched whole — `Bash(git add:*)`
    /// would compare equal to nothing and read as a typo rather than as a scoped shell grant.
    static func baseName(of element: String) -> String {
        guard let paren = element.firstIndex(of: "(") else { return element }
        return String(element[element.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
    }

    /// Collapses control characters and whitespace runs, caps length, drops empties.
    ///
    /// ⚠️ These are the least-validated strings the skill format produces: no charset check, no
    /// length limit, straight off disk from a file that may have come out of a .zip. An element can
    /// be four kilobytes of prose containing newlines. It reaches a SwiftUI label and a log line,
    /// and neither should be the place that discovers this.
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
    ///
    /// ⚠️ `candidates` exists so this cannot rot. It is not used for matching or rewriting — it is
    /// the list of names the prose refers to, asserted by `SkillToolDeclarationDriftTests` to still
    /// exist in `NativeToolCatalog`. Rename a tool and the test fails with the hint that lies,
    /// which is the failure mode a bare `[String: String]` table could never produce.
    struct ForeignHint: Sendable {
        let prose: String
        let candidates: [String]
    }

    /// Recognised names from Claude Code's vocabulary.
    ///
    /// Note what is absent: `Task`, `TodoWrite`, `NotebookEdit`, `SlashCommand` and `mcp__*` have no
    /// analogue here, so they get NO hint and render as foreign with nothing added. Inventing a
    /// near-equivalent for them would be the overclaiming this whole file exists to avoid.
    static let foreignHints: [String: ForeignHint] = [
        "Read": ForeignHint(
            prose: "Claude Code's file reader. The closest here is read_file — it also handles DOCX, XLSX and PPTX, but not notebooks or images.",
            candidates: ["read_file"]),
        "Write": ForeignHint(
            prose: "Claude Code's file writer. Here that is write_file or create_file, and create_new_file / overwrite_file in a Code profile.",
            candidates: ["write_file", "create_file", "create_new_file", "overwrite_file"]),
        "Edit": ForeignHint(
            prose: "Claude Code's in-place editor. Here that is edit_code, and edit_code_single / edit_code_batch in a Code profile.",
            candidates: ["edit_code", "edit_code_single", "edit_code_batch"]),
        "Bash": ForeignHint(
            prose: "A shell. Here that is execute_shell, or batch_command in a Code profile, where execute_shell is not offered.",
            candidates: ["execute_shell", "batch_command"]),
        "Glob": ForeignHint(
            prose: "Filename pattern matching. The closest here is glob_files.",
            candidates: ["glob_files"]),
        "Grep": ForeignHint(
            prose: "Content search. The closest here is grep_files, or code_search in a Code profile.",
            candidates: ["grep_files", "code_search"]),
        "WebFetch": ForeignHint(
            prose: "Fetching a URL. The closest here is http_request.",
            candidates: ["http_request"])
    ]

    static func foreignHint(for baseName: String) -> ForeignHint? { foreignHints[baseName] }
}
