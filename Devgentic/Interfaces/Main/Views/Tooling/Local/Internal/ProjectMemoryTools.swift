// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectMemoryTools.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - remember

/// `remember`, `forget` and `recall`: a Code run's only way to change or read project memory (`ProjectMemoryStore`).
/// `remember` checks what it is told before writing; a refusal returns an `Error:` line saying what to do instead.
struct RememberTool: DevgenticTool {

    let name = "remember"
    let category = "Internal"
    let description = """
    Saves ONE fact to this project's memory, which is shown to you in every later conversation. \
    Save only what the files cannot tell you: a command you ran successfully, a rule or decision the \
    user stated, a trap that cost you a retry, or how the user likes to work. Never save a \
    description of the code, its structure or its files — read them instead. Do not call this \
    unless the user asked you to remember something or one of those facts just happened; it is \
    never a step of the user's task. The same name replaces the earlier entry.
    """

    let projectPath: String
    let conversationID: UUID?
    /// The answer of the run this tool serves — what the change is recorded against, so that
    /// answer can show it and undo it. Nil records nothing (the write itself still happens).
    let messageID: UUID?
    /// Where `command` evidence is looked up. Injected so a test can use its own registry.
    let registry: BackgroundProcessRegistry
    let ledger: ProjectMemoryLedger
    let now: @Sendable () -> Date

    init(projectPath: String,
         conversationID: UUID?,
         messageID: UUID? = nil,
         registry: BackgroundProcessRegistry = .shared,
         ledger: ProjectMemoryLedger = .shared,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.projectPath = projectPath
        self.conversationID = conversationID
        self.messageID = messageID
        self.registry = registry
        self.ledger = ledger
        self.now = now
    }

    struct Arguments: Decodable, Sendable {
        let type: String
        let name: String
        let summary: String
        let details: String?
        let files: [String]?
        let command: String?

        private enum CodingKeys: String, CodingKey { case type, name, summary, details, files, command }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            name = try container.decode(String.self, forKey: .name)
            summary = try container.decode(String.self, forKey: .summary)
            details = try container.decodeIfPresent(String.self, forKey: .details)
            command = try container.decodeIfPresent(String.self, forKey: .command)
            // Small models send a list as one comma-separated string as often as an array.
            if let list = try? container.decodeIfPresent([String].self, forKey: .files) {
                files = list
            } else if let joined = try? container.decodeIfPresent(String.self, forKey: .files) {
                files = joined.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else {
                files = nil
            }
        }
    }

    var parameterSchema: ToolParameters {
        let types = ProjectMemoryType.allCases.map { "\($0.rawValue) = \($0.meaning)" }.joined(separator: "; ")
        return SchemaBuilder.object(
            properties: [
                ("type", "string", "One of: \(types)."),
                ("name", "string", "Short handle, e.g. 'test-command'. Reusing a name replaces that entry."),
                ("summary", "string", "One line, at most \(ProjectMemoryStore.Limits.summaryChars) characters."),
                ("details", "string", "Optional. At most \(ProjectMemoryStore.Limits.detailsChars) characters."),
                ("files", "array", "Optional. Project files the fact is about; each must exist."),
                ("command", "string", "Required for type 'command': the exact command, as you ran it with run_command."),
            ],
            required: ["type", "name", "summary"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        switch validate(arguments) {
        case .refused(let reason):
            return "Error: not saved — \(reason)"
        case .accepted(let entry, let replaced):
            let store = ProjectMemoryStore(projectPath: projectPath)
            let before = try? String(contentsOf: store.fileURL(for: entry.name), encoding: .utf8)
            do {
                try store.save(entry)
            } catch {
                return "Error: could not write \(store.fileURL(for: entry.name).path): \(error.localizedDescription)"
            }
            ProjectMemoryChangeRecorder.record(
                kind: replaced ? .replaced : .saved, name: entry.name, summary: entry.summary,
                before: before, after: entry.rendered(), projectPath: projectPath,
                conversationID: conversationID, messageID: messageID, ledger: ledger, at: now())
            return "Saved memory '\(entry.name)' (\(entry.type.rawValue))\(replaced ? ", replacing the earlier entry" : ""). It appears in the project memory from the next message on."
        }
    }

    enum Verdict: Equatable {
        case accepted(ProjectMemoryEntry, replaced: Bool)
        case refused(String)
    }

    /// Every check `remember` makes, without writing. Separate so each rule is testable alone.
    func validate(_ arguments: Arguments) -> Verdict {
        typealias Limits = ProjectMemoryStore.Limits

        guard let type = ProjectMemoryType(rawValue: arguments.type.trimmingCharacters(in: .whitespaces).lowercased()) else {
            return .refused("type must be one of \(ProjectMemoryType.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let name = ProjectMemoryStore.normalizedName(arguments.name) else {
            return .refused("name needs at least one letter or digit.")
        }
        let summary = arguments.summary.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !summary.isEmpty else { return .refused("summary is empty.") }
        guard summary.count <= Limits.summaryChars else {
            return .refused("summary is \(summary.count) characters; the limit is \(Limits.summaryChars). Keep it to one short line.")
        }
        let details = (arguments.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard details.count <= Limits.detailsChars else {
            return .refused("details are \(details.count) characters; the limit is \(Limits.detailsChars). Save the fact, not an explanation of the code.")
        }

        // A command is remembered only once it has WORKED here.
        var command: String?
        var evidence = "stated in conversation \(conversationTag)"
        if type == .command {
            guard let raw = arguments.command?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return .refused("type 'command' needs the exact command in `command`.")
            }
            guard let run = successfulRun(of: raw) else {
                return .refused("`\(raw)` has not run successfully in this conversation. Run it with run_command first; only a command that exited 0 can be remembered.")
            }
            command = raw
            evidence = "run_command exited 0 in conversation \(conversationTag) (\(run.id))"
        }

        var files: [String] = []
        for raw in arguments.files ?? [] where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            switch projectRelativePath(raw) {
            case .some(let relative): files.append(relative)
            case .none: return .refused("`\(raw)` is not a file or folder in this project.")
            }
        }

        let probe = [summary, details, command ?? ""].joined(separator: "\n")
        if MCPRedaction.redact(text: probe) != probe {
            return .refused("it looks like it contains a secret (a key, token or password). Describe where the secret comes from instead of saving it.")
        }

        let store = ProjectMemoryStore(projectPath: projectPath)
        let existing = store.entry(named: name)
        if existing == nil, store.entries().count >= Limits.entries {
            return .refused("project memory is full (\(Limits.entries) entries). Call forget on one that no longer matters first.")
        }

        return .accepted(ProjectMemoryEntry(
            name: name, type: type, summary: summary, details: details, files: files,
            command: command, evidence: evidence, updated: Self.day(now()),
            extraFields: existing?.extraFields ?? []), replaced: existing != nil)
    }

    private var conversationTag: String { conversationID.map { String($0.uuidString.prefix(8)) } ?? "unknown" }

    /// The run of `command` in this conversation that exited 0. Whitespace runs are collapsed on
    /// both sides; nothing else is normalised — the point is that THIS command worked.
    private func successfulRun(of command: String) -> BackgroundProcessRegistry.Snapshot? {
        guard let conversationID else { return nil }
        let wanted = Self.collapsed(command)
        return registry.snapshots(conversationID: conversationID).last {
            $0.status == .exited(code: 0) && Self.collapsed($0.command) == wanted
        }
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The project-relative form of `raw` when it names something inside the project that exists.
    private func projectRelativePath(_ raw: String) -> String? {
        let root = URL(fileURLWithPath: projectPath).standardizedFileURL
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let url = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed).standardizedFileURL
            : root.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(url.path.dropFirst(rootPath.count))
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - forget

struct ForgetTool: DevgenticTool {

    let name = "forget"
    let category = "Internal"
    let description = "Removes ONE entry from this project's memory, by name — for a fact that is wrong or no longer true."

    let projectPath: String
    var conversationID: UUID? = nil
    var messageID: UUID? = nil
    var ledger: ProjectMemoryLedger = .shared

    struct Arguments: Decodable, Sendable {
        let name: String
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [("name", "string", "The entry's name, as listed in the project memory.")],
            required: ["name"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = ProjectMemoryStore(projectPath: projectPath)
        let existing = store.entry(named: arguments.name)
        let before = existing.flatMap { try? String(contentsOf: store.fileURL(for: $0.name), encoding: .utf8) }
        do {
            if try store.remove(named: arguments.name) {
                let name = ProjectMemoryStore.normalizedName(arguments.name) ?? arguments.name
                ProjectMemoryChangeRecorder.record(
                    kind: .removed, name: name, summary: existing?.summary ?? "",
                    before: before, after: nil, projectPath: projectPath,
                    conversationID: conversationID, messageID: messageID, ledger: ledger, at: Date())
                return "Removed memory '\(name)'."
            }
        } catch {
            return "Error: could not remove '\(arguments.name)': \(error.localizedDescription)"
        }
        return "Error: there is no memory named '\(arguments.name)'. \(ProjectMemoryLookup.knownNames(in: store))"
    }
}

// MARK: - recall

struct RecallTool: DevgenticTool {

    let name = "recall"
    let category = "Internal"
    let description = "Returns ONE project-memory entry in full, by name, when the one-line summary in your prompt is not enough."

    let projectPath: String

    struct Arguments: Decodable, Sendable {
        let name: String
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [("name", "string", "The entry's name, as listed in the project memory.")],
            required: ["name"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        let store = ProjectMemoryStore(projectPath: projectPath)
        guard let entry = store.entry(named: arguments.name) else {
            return "Error: there is no memory named '\(arguments.name)'. \(ProjectMemoryLookup.knownNames(in: store))"
        }
        var lines = ["\(entry.name) (\(entry.type.rawValue), updated \(entry.updated))", entry.summary]
        if let command = entry.command { lines.append("Command: \(command)") }
        if !entry.files.isEmpty { lines.append("Files: \(entry.files.joined(separator: ", "))") }
        if !entry.details.isEmpty { lines.append(contentsOf: ["", entry.details]) }
        return lines.joined(separator: "\n")
    }
}

/// Records a change in the ledger and tells the Code session memory changed.
enum ProjectMemoryChangeRecorder {
    static func record(kind: ProjectMemoryChange.Kind, name: String, summary: String,
                       before: String?, after: String?, projectPath: String,
                       conversationID: UUID?, messageID: UUID?, ledger: ProjectMemoryLedger, at: Date) {
        if let conversationID, let messageID {
            ledger.record(ProjectMemoryChange(
                id: UUID(), conversationID: conversationID, messageID: messageID, projectPath: projectPath,
                name: name, kind: kind, summary: summary, before: before, after: after, at: at))
        }
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: projectPath)
    }
}

enum ProjectMemoryLookup {
    static func knownNames(in store: ProjectMemoryStore) -> String {
        let names = store.entries().map(\.name)
        return names.isEmpty ? "The project memory is empty." : "Known entries: \(names.joined(separator: ", "))."
    }
}
