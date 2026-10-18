// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectMemorySuggestions.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "ProjectMemory")

// MARK: - Suggestion

/// A fact proposed by the optional end-of-run memory pass, validated like `remember`; nothing reaches
/// `.devgentic/memory/` until the user accepts it.
struct ProjectMemorySuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let conversationID: UUID
    /// The answer the suggestion is shown under.
    let messageID: UUID
    let projectPath: String
    /// The entry exactly as accepting it would write it.
    let entryText: String
    let createdAt: Date

    var entry: ProjectMemoryEntry? {
        ProjectMemoryEntry.parse(entryText, fileStem: "suggestion")
    }
}

/// Pending suggestions, one JSON file each at App Support/Devgentic/ProjectMemorySuggestions/
/// <conversation>/<id>.json — outside the repository, because a suggestion is not memory yet.
final class ProjectMemorySuggestionStore: @unchecked Sendable {

    static let shared = ProjectMemorySuggestionStore(rootDirectory: defaultRootDirectory)

    static var defaultRootDirectory: URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-memory-suggestions-testhost", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Devgentic/ProjectMemorySuggestions", isDirectory: true)
    }

    let rootDirectory: URL
    private let lock = NSLock()

    init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    private func url(for suggestion: ProjectMemorySuggestion) -> URL {
        rootDirectory
            .appendingPathComponent(suggestion.conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("\(suggestion.id.uuidString).json")
    }

    func add(_ suggestion: ProjectMemorySuggestion) {
        lock.lock(); defer { lock.unlock() }
        let target = url(for: suggestion)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(suggestion).write(to: target, options: .atomic)
        } catch {
            logger.error("[MEMORY_SUGGEST] Could not store a suggestion for '\(URL(fileURLWithPath: suggestion.projectPath).lastPathComponent)': \(error.localizedDescription). CONSEQUENCE: it is not shown; nothing was written to project memory either.")
        }
    }

    private func all() -> [ProjectMemorySuggestion] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: nil) else { return [] }
        return folders.flatMap { folder -> [ProjectMemorySuggestion] in
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }
                .compactMap { try? JSONDecoder().decode(ProjectMemorySuggestion.self, from: Data(contentsOf: $0)) }
        }
    }

    /// The suggestions shown under one answer, oldest first.
    func suggestions(conversationID: UUID, messageID: UUID) -> [ProjectMemorySuggestion] {
        lock.lock(); defer { lock.unlock() }
        let folder = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ProjectMemorySuggestion.self, from: Data(contentsOf: $0)) }
            .filter { $0.messageID == messageID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Every pending suggestion for a project, newest first — the panel's "Suggested" section.
    func suggestions(projectPath: String) -> [ProjectMemorySuggestion] {
        lock.lock(); defer { lock.unlock() }
        let wanted = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return all().filter { URL(fileURLWithPath: $0.projectPath).standardizedFileURL.path == wanted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Writes the suggested entry to project memory and drops the suggestion. The user's accept is
    /// the review, so it is not re-checked here — a command's evidence lives only as long as the
    /// app does, and an accept after a relaunch must still work.
    @discardableResult
    func accept(_ suggestion: ProjectMemorySuggestion) throws -> ProjectMemoryEntry {
        guard let parsed = suggestion.entry else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The suggestion is unreadable."])
        }
        let note = "suggested after a run, accepted by the user"
        let entry = ProjectMemoryEntry(
            name: parsed.name, type: parsed.type, summary: parsed.summary, details: parsed.details,
            files: parsed.files, command: parsed.command,
            evidence: [parsed.evidence, note].filter { !$0.isEmpty }.joined(separator: "; "),
            updated: RememberTool.day(Date()), extraFields: parsed.extraFields)
        try ProjectMemoryStore(projectPath: suggestion.projectPath).save(entry)
        remove(suggestion)
        logger.info("[MEMORY_SUGGEST] Accepted '\(entry.name)' into the memory of '\(URL(fileURLWithPath: suggestion.projectPath).lastPathComponent)'.")
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: suggestion.projectPath)
        return entry
    }

    func dismiss(_ suggestion: ProjectMemorySuggestion) {
        remove(suggestion)
        logger.info("[MEMORY_SUGGEST] Dismissed a suggestion for '\(URL(fileURLWithPath: suggestion.projectPath).lastPathComponent)'. CONSEQUENCE: nothing is saved.")
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: suggestion.projectPath)
    }

    private func remove(_ suggestion: ProjectMemorySuggestion) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(for: suggestion))
    }
}

// MARK: - Run evidence

/// What a run did, collected from its event stream as the events pass through `AgentConnect`.
final class ProjectMemoryRunEvidence: @unchecked Sendable {

    struct ToolOutcome: Sendable, Equatable {
        let name: String
        let params: String
        let succeeded: Bool
        /// The first line of the output — enough to say what went wrong, never a whole file.
        let firstLine: String
    }

    let startedAt: Date
    private let lock = NSLock()
    private var outcomes: [ToolOutcome] = []

    init(startedAt: Date = Date()) { self.startedAt = startedAt }

    var toolOutcomes: [ToolOutcome] {
        lock.lock(); defer { lock.unlock() }
        return outcomes
    }

    func observe(_ event: AgentStreamEvent) {
        let output: ToolOutput
        let succeeded: Bool
        switch event {
        case .toolSucceeded(let tool, _, _): output = tool; succeeded = true
        case .toolFailed(let tool, _, _, _): output = tool; succeeded = false
        default: return
        }
        let firstLine = output.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        lock.lock(); defer { lock.unlock() }
        outcomes.append(ToolOutcome(name: output.toolName, params: String(output.params.prefix(300)),
                                    succeeded: succeeded, firstLine: String(firstLine.prefix(200))))
    }
}

// MARK: - The pass

actor ProjectMemorySuggester {

    static let shared = ProjectMemorySuggester()

    /// At most this many suggestions per answer.
    static let maxSuggestions = 3

    private var running: [UUID: Task<Void, Never>] = [:]

    /// Whether this run gets a pass: a Code profile with a folder, the project's setting on.
    static func isEnabled(for details: ProfileDetails, defaults: UserDefaults = .standard) -> Bool {
        guard case .code(let config) = details, let projectPath = config.projectPath else { return false }
        return CodeQuickSettingsStore.settings(for: projectPath, defaults: defaults).suggestMemories == true
    }

    /// A new send in the conversation: whatever the previous answer's pass was doing is moot.
    func cancel(conversationID: UUID) {
        guard let task = running.removeValue(forKey: conversationID) else { return }
        task.cancel()
        logger.info("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — a new run started; the previous answer's memory pass is cancelled. CONSEQUENCE: that answer gets no suggestions.")
    }

    /// Starts the pass in the background and returns at once. `generate` is the conversation's
    /// own model; a test passes a stand-in.
    @discardableResult
    func schedule(
        evidence: ProjectMemoryRunEvidence,
        userRequest: String,
        answer: String,
        projectPath: String,
        conversationID: UUID,
        messageID: UUID,
        registry: BackgroundProcessRegistry = .shared,
        suggestions: ProjectMemorySuggestionStore = .shared,
        generate: @escaping @Sendable ([[String: String]]) async throws -> String
    ) -> Task<Void, Never>? {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        let outcomes = evidence.toolOutcomes
        guard !outcomes.isEmpty else {
            logger.info("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — the run used no tools, so there is nothing it learned about '\(name)'. CONSEQUENCE: no memory pass, no extra model call.")
            return nil
        }
        running[conversationID]?.cancel()
        let commands = registry.snapshots(conversationID: conversationID).filter { $0.startedAt >= evidence.startedAt }
        let existing = ProjectMemoryStore(projectPath: projectPath).entries()
        let messages = Self.messages(userRequest: userRequest, answer: answer, outcomes: outcomes,
                                     commands: commands, existing: existing)
        let task = Task {
            logger.info("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — memory pass for '\(name)' started (\(outcomes.count) tool call(s), \(commands.count) command(s)). CONSEQUENCE: one extra model call, after the answer; nothing is saved without the user.")
            do {
                let reply = try await generate(messages)
                try Task.checkCancellation()
                let kept = Self.suggestions(
                    from: reply, projectPath: projectPath, conversationID: conversationID,
                    messageID: messageID, registry: registry, existing: existing)
                for suggestion in kept { suggestions.add(suggestion) }
                logger.info("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — memory pass for '\(name)' finished: \(kept.count) suggestion(s).")
                if !kept.isEmpty {
                    NotificationCenter.default.post(name: .projectMemoryDidChange, object: projectPath)
                }
            } catch is CancellationError {
                logger.info("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — memory pass cancelled before it finished. CONSEQUENCE: nothing stored.")
            } catch {
                logger.warning("[MEMORY_SUGGEST] conv \(conversationID.uuidString.prefix(8)) — memory pass failed: \(error.localizedDescription). CONSEQUENCE: no suggestions for this answer; the answer itself is unaffected.")
            }
            await self.finished(conversationID: conversationID)
        }
        running[conversationID] = task
        return task
    }

    private func finished(conversationID: UUID) {
        running.removeValue(forKey: conversationID)
    }

    // MARK: Prompt

    static func messages(
        userRequest: String,
        answer: String,
        outcomes: [ProjectMemoryRunEvidence.ToolOutcome],
        commands: [BackgroundProcessRegistry.Snapshot],
        existing: [ProjectMemoryEntry]
    ) -> [[String: String]] {
        let types = ProjectMemoryType.allCases.map { "- \($0.rawValue): \($0.meaning)" }.joined(separator: "\n")
        let system = """
        You review ONE finished coding session and propose at most \(maxSuggestions) facts worth saving to the project's memory, for future sessions.

        Save only what the project's files cannot tell a future session:
        \(types)

        Never propose a description of the code, its structure or its files. Never repeat a fact already in the memory. If nothing qualifies — the usual case — reply with [].

        Reply with ONLY a JSON array, no prose:
        [{"type": "command", "name": "test-command", "summary": "one line", "details": "optional", "command": "the exact command, for type command", "files": ["optional/project/paths"]}]
        """

        var evidence = "User's request:\n\(String(userRequest.prefix(1_500)))\n"
        if !commands.isEmpty {
            evidence += "\nCommands run (exact text → result):\n"
            evidence += commands.map { "- `\($0.command)` → \($0.status.label)" }.joined(separator: "\n") + "\n"
        }
        let failures = outcomes.filter { !$0.succeeded }
        if !failures.isEmpty {
            evidence += "\nTool calls that failed:\n"
            evidence += failures.map { "- \($0.name)(\($0.params)) → \($0.firstLine)" }.joined(separator: "\n") + "\n"
        }
        evidence += "\nOther tool calls: " + outcomes.filter(\.succeeded).map(\.name).joined(separator: ", ") + "\n"
        evidence += "\nThe answer given:\n\(String(answer.prefix(1_500)))\n"
        evidence += "\nAlready in memory:\n" + (existing.isEmpty ? "(nothing)" : existing.map(\.indexLine).joined(separator: "\n"))

        return [["role": "system", "content": system], ["role": "user", "content": evidence]]
    }

    // MARK: Reading the reply

    /// The JSON objects in the reply's first array, as `remember` arguments. Anything unreadable is
    /// dropped — a malformed pass costs a suggestion, never an entry.
    static func proposals(from reply: String) -> [RememberTool.Arguments] {
        guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"), open < close,
              let array = try? JSONSerialization.jsonObject(with: Data(reply[open...close].utf8)) as? [Any] else { return [] }
        return array.compactMap { item in
            guard let object = item as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(RememberTool.Arguments.self, from: data)
        }
    }

    /// The proposals that pass `remember`'s own checks, are not already in memory, capped.
    static func suggestions(
        from reply: String,
        projectPath: String,
        conversationID: UUID,
        messageID: UUID,
        registry: BackgroundProcessRegistry,
        existing: [ProjectMemoryEntry],
        now: Date = Date()
    ) -> [ProjectMemorySuggestion] {
        let checker = RememberTool(projectPath: projectPath, conversationID: conversationID, registry: registry)
        var kept: [ProjectMemorySuggestion] = []
        var names = Set<String>()
        for proposal in proposals(from: reply) {
            guard kept.count < maxSuggestions else { break }
            switch checker.validate(proposal) {
            case .refused(let reason):
                logger.info("[MEMORY_SUGGEST] Dropped a proposal ('\(proposal.name)'): \(reason)")
            case .accepted(let entry, _):
                if existing.contains(where: { $0.name == entry.name && $0.summary == entry.summary }) || names.contains(entry.name) {
                    logger.info("[MEMORY_SUGGEST] Dropped '\(entry.name)': already in memory.")
                    continue
                }
                names.insert(entry.name)
                kept.append(ProjectMemorySuggestion(
                    id: UUID(), conversationID: conversationID, messageID: messageID,
                    projectPath: projectPath, entryText: entry.rendered(), createdAt: now))
            }
        }
        return kept
    }
}
