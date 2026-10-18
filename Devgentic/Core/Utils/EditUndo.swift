// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EditUndo.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "EditUndo")

/// Undo for agent file edits in Code conversations: Undo reverses one turn's edits, Rewind also every later turn's.
/// Patches apply backwards per file, newest first; a file is all-or-nothing, and a conflict leaves it untouched.
enum EditUndo {

    /// One write to undo, as the timeline recorded it.
    struct Write: Equatable {
        let toolEventID: UUID
        let path: String
    }

    enum FileOutcome: Equatable {
        /// `exact`: the file was still as the agent left it, so this is the original byte for byte.
        case restore(content: String, exact: Bool)
        /// The edits created the file, and it is unchanged since: it goes to the Trash.
        case moveToTrash
        case conflict(String)
        case cannotUndo(String)
        case alreadyUndone

        var willChangeDisk: Bool {
            switch self {
            case .restore, .moveToTrash: return true
            default: return false
            }
        }
    }

    struct FilePlan: Identifiable, Equatable {
        let path: String
        var id: String { path }
        var fileName: String { (path as NSString).lastPathComponent }
        let outcome: FileOutcome
        /// Hash of the file when planned; applying re-checks it so a save made in between wins.
        let plannedHash: String?
        let patches: [EditPatch]
    }

    struct Plan: Equatable {
        let files: [FilePlan]
        var changing: [FilePlan] { files.filter { $0.outcome.willChangeDisk } }
    }

    // MARK: - Which writes

    /// A message's successful file writes, in the order they happened.
    @MainActor
    static func writes(in message: ChatMessage) -> [Write] {
        message.flattenedTimelineEvents.compactMap { event in
            guard case .toolExecution(let data) = event, data.isSuccess == true, let effect = data.effect else { return nil }
            return Write(toolEventID: data.id, path: URL(fileURLWithPath: effect.path).standardizedFileURL.path)
        }
    }

    /// Writes for Undo (`throughLatest == false`: this message only) or Rewind (this message and
    /// every later one), NEWEST FIRST. `newestFirst` is the transcript in `currentChatMessages`
    /// order.
    @MainActor
    static func writes(from message: ChatMessage, newestFirst: [ChatMessage], throughLatest: Bool) -> [Write] {
        let messages: [ChatMessage]
        if throughLatest, let index = newestFirst.firstIndex(where: { $0.id == message.id }) {
            messages = Array(newestFirst[...index])
        } else {
            messages = [message]
        }
        return messages.flatMap { writes(in: $0).reversed() }
    }

    // MARK: - Planning

    /// Pure apart from `read`. `writes` must be newest first.
    static func plan(writes: [Write], conversationID: UUID, store: EditPatchStore,
                     read: (String) -> String?) -> Plan {
        var order: [String] = []
        var byPath: [String: [Write]] = [:]
        for write in writes {
            if byPath[write.path] == nil { order.append(write.path) }
            byPath[write.path, default: []].append(write)
        }

        let files = order.map { path -> FilePlan in
            let loaded = byPath[path]!.map { store.load(conversationID: conversationID, toolEventID: $0.toolEventID) }
            guard loaded.allSatisfy({ $0 != nil }) else {
                return FilePlan(path: path, outcome: .cannotUndo("No undo record — it expires after 7 days, and none is kept for files over 512 KB."),
                                plannedHash: nil, patches: [])
            }
            let pending = loaded.compactMap { $0 }.filter { $0.revertedAt == nil }
            guard let newest = pending.first else {
                return FilePlan(path: path, outcome: .alreadyUndone, plannedHash: nil, patches: [])
            }
            let current = read(path)
            let currentHash = current.map(EditPatch.hash)
            var content = current
            var deleted = false
            for patch in pending {
                switch patch.revert(current: content) {
                case .content(let reverted):
                    content = reverted
                case .deleteFile:
                    content = nil
                    deleted = true
                case .conflict(let hunks):
                    let reason = current == nil
                        ? "The file no longer exists."
                        : "Lines these edits changed were edited since (part \(hunks.map(String.init).joined(separator: ", ")))."
                    return FilePlan(path: path, outcome: .conflict(reason), plannedHash: currentHash, patches: pending)
                }
            }
            let exact = currentHash == newest.afterHash
            if deleted {
                return FilePlan(path: path, outcome: .moveToTrash, plannedHash: currentHash, patches: pending)
            }
            return FilePlan(path: path, outcome: .restore(content: content ?? "", exact: exact),
                            plannedHash: currentHash, patches: pending)
        }
        return Plan(files: files)
    }

    // MARK: - Applying

    struct Applied: Equatable {
        var changed: [String] = []
        /// Files left alone at apply time, with why.
        var skipped: [(String, String)] = []
        static func == (l: Applied, r: Applied) -> Bool { l.changed == r.changed && l.skipped.map(\.0) == r.skipped.map(\.0) }
    }

    /// Writes the plan. Each file is re-read first: if it changed since planning, it is skipped.
    static func apply(_ plan: Plan, store: EditPatchStore, read: (String) -> String?) -> Applied {
        var result = Applied()
        for file in plan.changing {
            guard read(file.path).map(EditPatch.hash) == file.plannedHash else {
                result.skipped.append((file.path, "it changed after you opened Undo"))
                logger.notice("[UNDO] Skipped '\(file.fileName)': it changed between planning and applying. CONSEQUENCE: left as it is now.")
                continue
            }
            do {
                switch file.outcome {
                case .restore(let content, _):
                    // An atomic write replaces the file, which would drop e.g. a script's
                    // executable bit — carry the permissions across.
                    let permissions = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
                    try content.write(toFile: file.path, atomically: true, encoding: .utf8)
                    if let permissions {
                        try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
                    }
                case .moveToTrash:
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)
                default:
                    continue
                }
                file.patches.forEach { store.markReverted($0) }
                result.changed.append(file.path)
                logger.notice("[UNDO] Undid \(file.patches.count) edit(s) to '\(file.fileName)' (\(file.outcome == .moveToTrash ? "moved to Trash" : "restored")).")
            } catch {
                result.skipped.append((file.path, error.localizedDescription))
                logger.error("[UNDO] Could not undo '\(file.fileName)': \(error.localizedDescription). CONSEQUENCE: the file is unchanged; its undo records are kept.")
            }
        }
        return result
    }

    /// Reads a file as text, or nil when it is missing or unreadable.
    static func readFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
