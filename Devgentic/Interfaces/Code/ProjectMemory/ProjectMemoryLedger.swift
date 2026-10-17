// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProjectMemoryLedger.swift
//  Devgentic
//
//  Every change `remember` / `forget` makes to project memory, recorded against the answer of the
//  run that made it — so that answer can show "Saved 1 memory" and undo it.
//
//  One JSON file per change at App Support/Devgentic/ProjectMemoryChanges/<conversation>/<id>.json.
//  The entry's whole text before and after is kept: an entry is at most a few hundred characters,
//  so a copy is cheaper and more exact than a patch.
//
//  ⚠️ Undo restores ONLY when the entry still holds exactly what the change wrote. If anything
//  touched it since — a later `remember`, the user's editor, the Memory panel — Undo says so and
//  changes nothing, the same rule `EditUndo` applies to code edits.
//

import Foundation

private let logger = DGLogger(category: "ProjectMemory")

extension Notification.Name {
    /// Posted after anything writes project memory, with the project path as `object`. The Code
    /// session refreshes its display copy (the Context gauge and the inspector) from it.
    static let projectMemoryDidChange = Notification.Name("devgentic.projectMemoryDidChange")
}

struct ProjectMemoryChange: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case saved      // a new entry
        case replaced   // an entry of the same name was overwritten
        case removed    // `forget`
    }

    let id: UUID
    let conversationID: UUID
    /// The answer of the run that made the change — what the "Saved" card renders on.
    let messageID: UUID
    let projectPath: String
    let name: String
    let kind: Kind
    /// The entry's summary after the change, or before it for `.removed` — for display only.
    let summary: String
    /// The entry file's text before the change; nil when there was no entry.
    let before: String?
    /// The entry file's text after the change; nil when it was removed.
    let after: String?
    let at: Date
    var revertedAt: Date?
}

final class ProjectMemoryLedger: @unchecked Sendable {

    static let shared = ProjectMemoryLedger(rootDirectory: defaultRootDirectory)

    /// A test host is redirected to a temp directory, as the command logs and edit patches are.
    static var defaultRootDirectory: URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("devgentic-memory-changes-testhost", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Devgentic/ProjectMemoryChanges", isDirectory: true)
    }

    let rootDirectory: URL
    private let lock = NSLock()

    init(rootDirectory: URL) { self.rootDirectory = rootDirectory }

    private func url(conversationID: UUID, id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("\(id.uuidString).json")
    }

    func record(_ change: ProjectMemoryChange) {
        lock.lock(); defer { lock.unlock() }
        save(change)
    }

    private func save(_ change: ProjectMemoryChange) {
        let target = url(conversationID: change.conversationID, id: change.id)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(change).write(to: target, options: .atomic)
        } catch {
            logger.error("[PROJECT_MEMORY] Could not record the change to '\(change.name)': \(error.localizedDescription). CONSEQUENCE: the entry was written, but its answer shows no Undo for it.")
        }
    }

    /// The changes one run made, oldest first.
    func changes(conversationID: UUID, messageID: UUID) -> [ProjectMemoryChange] {
        let folder = rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ProjectMemoryChange.self, from: Data(contentsOf: $0)) }
            .filter { $0.messageID == messageID }
            .sorted { $0.at < $1.at }
    }

    enum UndoResult: Equatable {
        case undone
        case alreadyUndone
        /// The entry no longer holds what the change wrote.
        case changedSince
        case failed(String)
    }

    /// Puts the entry back the way it was before `change`. See the file header for the one rule.
    func undo(_ change: ProjectMemoryChange) -> UndoResult {
        lock.lock(); defer { lock.unlock() }
        guard let stored = try? JSONDecoder().decode(ProjectMemoryChange.self, from: Data(contentsOf: url(conversationID: change.conversationID, id: change.id))) else {
            return .failed("the record of this change is gone")
        }
        guard stored.revertedAt == nil else { return .alreadyUndone }

        let store = ProjectMemoryStore(projectPath: change.projectPath)
        let file = store.fileURL(for: change.name)
        let current = try? String(contentsOf: file, encoding: .utf8)
        guard current == change.after else {
            logger.notice("[PROJECT_MEMORY] Undo of '\(change.name)' refused: the entry changed after this run wrote it. CONSEQUENCE: nothing is changed; the user is told to edit it in the Memory panel.")
            return .changedSince
        }
        do {
            if let before = change.before {
                try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                try before.write(to: file, atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            try store.writeIndex()
        } catch {
            return .failed(error.localizedDescription)
        }
        var reverted = stored
        reverted.revertedAt = Date()
        save(reverted)
        logger.info("[PROJECT_MEMORY] Undid the \(change.kind.rawValue) of '\(change.name)' in '\(URL(fileURLWithPath: change.projectPath).lastPathComponent)'.")
        NotificationCenter.default.post(name: .projectMemoryDidChange, object: change.projectPath)
        return .undone
    }
}
