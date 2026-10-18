// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectMemoryStore.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "ProjectMemory")

// MARK: - Entry

/// What kind of fact an entry is. The set is closed: each case is something a run cannot
/// rediscover from the files alone.
enum ProjectMemoryType: String, CaseIterable, Sendable {
    case command
    case convention
    case decision
    case gotcha
    case preference

    /// Model-facing meaning, used in the tool schema.
    var meaning: String {
        switch self {
        case .command:    return "a build/test/lint/run command you ran successfully in this conversation"
        case .convention: return "a house rule the user stated (naming, structure, style)"
        case .decision:   return "why something is the way it is, as the user explained it"
        case .gotcha:     return "a trap that cost a retry, and how to avoid it"
        case .preference: return "how the user likes to work"
        }
    }
}

struct ProjectMemoryEntry: Equatable, Sendable {
    /// The file stem and the handle `recall` / `forget` take. Lowercase letters, digits, `-`.
    let name: String
    let type: ProjectMemoryType
    /// One line, shown in the index on every message.
    let summary: String
    /// Read on demand through `recall`, or inline while the whole store is small.
    let details: String
    /// Project-relative paths the fact is about.
    let files: [String]
    /// The exact command, for `.command` entries.
    let command: String?
    /// Where the fact came from, written by the app — never by the model.
    let evidence: String
    /// `yyyy-MM-dd`.
    let updated: String
    /// Front-matter keys this type does not know, kept in order so a hand edit survives the
    /// next rewrite of the entry.
    var extraFields: [(key: String, value: String)] = []

    static func == (lhs: ProjectMemoryEntry, rhs: ProjectMemoryEntry) -> Bool {
        lhs.name == rhs.name && lhs.type == rhs.type && lhs.summary == rhs.summary
            && lhs.details == rhs.details && lhs.files == rhs.files && lhs.command == rhs.command
            && lhs.evidence == rhs.evidence && lhs.updated == rhs.updated
            && lhs.extraFields.map(\.key) == rhs.extraFields.map(\.key)
            && lhs.extraFields.map(\.value) == rhs.extraFields.map(\.value)
    }

    /// One index line: `- [command] test-command — Tests run with pytest -q`.
    var indexLine: String { "- [\(type.rawValue)] \(name) — \(summary)" }
}

extension ProjectMemoryEntry: Identifiable {
    /// The name is unique within a project — it is the file stem.
    var id: String { name }
}

// MARK: - File format

extension ProjectMemoryEntry {

    private static let knownKeys = ["name", "type", "summary", "command", "files", "evidence", "updated"]

    /// The entry as its file: front matter between `---` lines, then the details.
    func rendered() -> String {
        var lines = ["---", "name: \(name)", "type: \(type.rawValue)", "summary: \(summary)"]
        if let command { lines.append("command: \(command)") }
        if !files.isEmpty { lines.append("files: \(files.joined(separator: ", "))") }
        lines.append("evidence: \(evidence)")
        lines.append("updated: \(updated)")
        for field in extraFields { lines.append("\(field.key): \(field.value)") }
        lines.append("---")
        let body = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.joined(separator: "\n") + "\n" + (body.isEmpty ? "" : body + "\n")
    }

    /// Parses an entry file. Nil — never a guess — when the front matter is missing or names no
    /// known type, so a malformed hand edit is skipped and logged rather than half-read.
    static func parse(_ text: String, fileStem: String) -> ProjectMemoryEntry? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fields: [String: String] = [:]
        var extras: [(key: String, value: String)] = []
        for line in lines[1..<close] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if knownKeys.contains(key) { fields[key] = value } else { extras.append((key, value)) }
        }
        guard let rawType = fields["type"], let type = ProjectMemoryType(rawValue: rawType),
              let summary = fields["summary"], !summary.isEmpty else { return nil }

        let details = lines[(close + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (fields["files"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ProjectMemoryEntry(
            name: fields["name"].flatMap { ProjectMemoryStore.normalizedName($0) } ?? fileStem,
            type: type,
            summary: summary,
            details: details,
            files: files,
            command: fields["command"].flatMap { $0.isEmpty ? nil : $0 },
            evidence: fields["evidence"] ?? "",
            updated: fields["updated"] ?? "",
            extraFields: extras)
    }
}

// MARK: - Store

/// Reads and writes one project's memory. A value type over a folder: every call reads the disk,
/// so an entry the user edits by hand is what the next run sees.
struct ProjectMemoryStore: Sendable {

    enum Limits {
        static let summaryChars = 150
        static let detailsChars = 600
        static let entries = 40
        static let nameChars = 40
        /// While every entry's details together fit in this many characters, the prompt carries
        /// them inline and `recall` is never needed.
        static let inlineDetailsChars = 2_000
    }

    static let folder = ".devgentic/memory"
    static let indexFileName = "INDEX.md"

    let projectRoot: URL

    init(projectRoot: URL) { self.projectRoot = projectRoot.standardizedFileURL }
    init(projectPath: String) { self.init(projectRoot: URL(fileURLWithPath: projectPath)) }

    var directory: URL { projectRoot.appendingPathComponent(Self.folder, isDirectory: true) }

    func fileURL(for name: String) -> URL { directory.appendingPathComponent("\(name).md") }

    /// Lowercase letters, digits and single hyphens; nil when nothing usable is left.
    static func normalizedName(_ raw: String) -> String? {
        var slug = ""
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, slug.last != "-" {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        guard !slug.isEmpty else { return nil }
        return String(slug.prefix(Limits.nameChars))
    }

    /// Every readable entry, sorted by type then name so the index is stable between messages
    /// (it sits in the cached prompt prefix).
    func entries() -> [ProjectMemoryEntry] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var result: [ProjectMemoryEntry] = []
        for url in urls where url.pathExtension == "md" && url.lastPathComponent != Self.indexFileName {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let entry = ProjectMemoryEntry.parse(text, fileStem: stem) {
                result.append(entry)
            } else {
                logger.warning("[PROJECT_MEMORY] Skipped '\(url.lastPathComponent)' in \(directory.path): no readable front matter (needs `---`, a known `type:` and a `summary:`). CONSEQUENCE: this entry is not in the prompt until the file is fixed.")
            }
        }
        let order = Dictionary(uniqueKeysWithValues: ProjectMemoryType.allCases.enumerated().map { ($1, $0) })
        return result.sorted { (order[$0.type] ?? 0, $0.name) < (order[$1.type] ?? 0, $1.name) }
    }

    func entry(named name: String) -> ProjectMemoryEntry? {
        guard let name = Self.normalizedName(name) else { return nil }
        return entries().first { $0.name == name }
    }

    /// Writes one entry (replacing one of the same name) and regenerates the index.
    func save(_ entry: ProjectMemoryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try entry.rendered().write(to: fileURL(for: entry.name), atomically: true, encoding: .utf8)
        try writeIndex()
    }

    /// Removes one entry and regenerates the index. False when there was no such entry.
    @discardableResult
    func remove(named name: String) throws -> Bool {
        guard let name = Self.normalizedName(name) else { return false }
        let url = fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.removeItem(at: url)
        try writeIndex()
        return true
    }

    /// `INDEX.md`, for people browsing the folder. Derived, never read back: the prompt is built
    /// from the entries themselves, so the two cannot disagree.
    func writeIndex() throws {
        let all = entries()
        var text = "# Project memory\n\n"
        text += "<!-- Generated by Devgentic from the entry files in this folder. Edit or delete an entry file; this index is rewritten from them. -->\n\n"
        text += all.isEmpty ? "_No entries yet._\n" : all.map(\.indexLine).joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent(Self.indexFileName), atomically: true, encoding: .utf8)
    }

    /// The memory as the prompt carries it: one line per entry, with the details inline while
    /// they are small. Nil when there are no entries.
    func promptListing() -> String? {
        let all = entries()
        guard !all.isEmpty else { return nil }
        let detailChars = all.reduce(0) { $0 + $1.details.count }
        let inline = detailChars <= Limits.inlineDetailsChars
        let lines = all.map { entry -> String in
            var line = entry.indexLine
            let stale = staleFiles(of: entry)
            if !stale.isEmpty { line += " (may be stale: \(stale.joined(separator: ", ")) changed since — check before relying on it)" }
            guard inline, !entry.details.isEmpty else { return line }
            let indented = entry.details.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")
            return line + "\n" + indented
        }
        return lines.joined(separator: "\n")
    }

    /// Returns the files an entry names that were modified after the entry was last written, a cheap staleness signal.
    /// Compares against the entry file's own timestamp, not its date-only `updated` field.
    /// Empty when nothing changed, the entry names no files, or a timestamp cannot be read.
    func staleFiles(of entry: ProjectMemoryEntry) -> [String] {
        guard !entry.files.isEmpty,
              let written = Self.modificationDate(of: fileURL(for: entry.name)) else { return [] }
        return entry.files.filter { relative in
            Self.modificationDate(of: projectRoot.appendingPathComponent(relative)).map { $0 > written } ?? false
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - AGENTS.md

/// The repository's own instructions for coding agents: `AGENTS.md` at the project root, the
/// cross-tool convention. Written and owned by people; the app only reads it.
enum ProjectInstructionsFile {
    static let fileName = "AGENTS.md"

    /// Past this, the content is still injected in full; the log says what it costs.
    static let largeChars = 4_000

    static func url(inProject projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath).appendingPathComponent(fileName)
    }

    /// The file's text, or nil when it is missing or blank.
    static func read(inProject projectPath: String) -> String? {
        guard let text = try? String(contentsOf: url(inProject: projectPath), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > largeChars {
            logger.notice("[PROJECT_MEMORY] \(fileName) in '\(URL(fileURLWithPath: projectPath).lastPathComponent)' is \(trimmed.count) chars. CONSEQUENCE: it is injected in full on every message; on a small context window that leaves less room for history and tool results.")
        }
        return trimmed
    }
}
