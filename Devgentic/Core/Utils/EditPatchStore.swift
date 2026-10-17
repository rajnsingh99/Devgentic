// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  EditPatchStore.swift
//  Devgentic
//
//  Where `EditPatch`es live: `~/Library/Application Support/Devgentic/EditPatches/<conversation>/
//  <tool event>.json`, one file per agent write. Kept 7 days, 1 GB in total, oldest removed first —
//  the same retention as command logs (user decision 2026-10-04).
//
//  ⚠️ Not in the message's timeline blob. That blob is re-encoded whole on every flush and decoded
//  on every conversation load; a patch has no size cap.
//

import Foundation
import os

private let logger = DGLogger(category: "EditPatch")

final class EditPatchStore: @unchecked Sendable {

    static let shared = EditPatchStore(rootDirectory: defaultRootDirectory)

    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let defaultTotalBytes: UInt64 = 1024 * 1024 * 1024

    /// A test host never writes into the user's folder (as `BackgroundProcessRegistry`).
    static var defaultRootDirectory: URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory.appendingPathComponent("devgentic-edit-patches-testhost", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Devgentic/EditPatches", isDirectory: true)
    }

    let rootDirectory: URL
    private let maxTotalBytes: UInt64
    private let lock = NSLock()
    private var sweepTimer: DispatchSourceTimer?

    init(rootDirectory: URL, maxTotalBytes: UInt64 = EditPatchStore.defaultTotalBytes, sweeps: Bool = true) {
        self.rootDirectory = rootDirectory
        self.maxTotalBytes = maxTotalBytes
        if sweeps { startSweeping() }
    }

    func url(conversationID: UUID, toolEventID: UUID) -> URL {
        rootDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
            .appendingPathComponent("\(toolEventID.uuidString).json")
    }

    // MARK: - Recording

    /// The one entry point both completion paths call (`ActiveStreamManager` for top-level rows,
    /// `CapabilityCardRouter` for rows inside a plan/reflection card). Code conversations only —
    /// Undo is a Code feature, and nothing else should copy file contents into Application Support.
    @MainActor
    static func recordIfCode(_ data: ToolExecutionData, in message: ChatMessage, store: EditPatchStore = .shared) {
        guard message.profileType == .code else { return }
        store.record(data, conversationID: message.conversationId, messageID: message.id)
    }

    /// Records a finished write from its timeline row, off the caller's thread. A row with no
    /// before-snapshot (file unreadable or over the snapshot cap) gets no patch — logged, since its
    /// Undo will then say it cannot undo this write.
    @MainActor
    func record(_ data: ToolExecutionData, conversationID: UUID, messageID: UUID) {
        guard data.isSuccess == true, data.effect != nil,
              let action = TimelineFileViewerAction.resolve(data: data),
              action.isWrite, let after = action.inlineContent else { return }
        guard let before = action.preWriteContent else {
            logger.notice("[PATCH] No undo record for '\(action.fileName)' (\(data.id.uuidString.prefix(8))): no before-copy was taken (unreadable, or over the snapshot cap). CONSEQUENCE: Undo will report this write as one it cannot undo.")
            return
        }
        let path = action.filePath
        let toolEventID = data.id
        Task.detached(priority: .utility) { [self] in
            guard let patch = EditPatch.make(before: before, after: after, path: path, conversationID: conversationID,
                                             messageID: messageID, toolEventID: toolEventID, createdFile: before.isEmpty) else { return }
            self.save(patch)
        }
    }

    func save(_ patch: EditPatch) {
        let target = url(conversationID: patch.conversationID, toolEventID: patch.toolEventID)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(patch)
            try data.write(to: target, options: .atomic)
            logger.info("[PATCH] Saved undo record for '\((patch.path as NSString).lastPathComponent)' — \(patch.hunks.count) hunk(s), \(data.count) bytes.")
        } catch {
            logger.error("[PATCH] Could not save the undo record for '\(patch.path)': \(error.localizedDescription). CONSEQUENCE: this write cannot be undone.")
        }
    }

    func load(conversationID: UUID, toolEventID: UUID) -> EditPatch? {
        let source = url(conversationID: conversationID, toolEventID: toolEventID)
        guard let data = try? Data(contentsOf: source) else { return nil }
        do {
            return try JSONDecoder().decode(EditPatch.self, from: data)
        } catch {
            logger.error("[PATCH] Undo record \(source.lastPathComponent) is unreadable: \(error.localizedDescription). CONSEQUENCE: that write is treated as one that cannot be undone.")
            return nil
        }
    }

    func markReverted(_ patch: EditPatch, at date: Date = Date()) {
        var updated = patch
        updated.revertedAt = date
        save(updated)
    }

    // MARK: - Retention

    private func startSweeping() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 24 * 60 * 60, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.sweep() }
        lock.lock(); sweepTimer = timer; lock.unlock()
        timer.resume()
    }

    /// Patches untouched for `retention` go; then, past `maxTotalBytes`, the oldest. Internal so
    /// tests can run one pass.
    func sweep(now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let folders = try? fm.contentsOfDirectory(at: rootDirectory, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return }
        struct Item { let url: URL; let modified: Date; let bytes: UInt64 }
        var items: [Item] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                           options: [.skipsHiddenFiles]) else { continue }
            for file in files {
                guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { continue }
                items.append(Item(url: file, modified: values.contentModificationDate ?? .distantPast,
                                  bytes: UInt64(values.fileSize ?? 0)))
            }
        }
        let cutoff = now.addingTimeInterval(-Self.retention)
        var removed = 0
        var kept: [Item] = []
        for item in items {
            if item.modified < cutoff, (try? fm.removeItem(at: item.url)) != nil { removed += 1 } else { kept.append(item) }
        }
        var total = kept.reduce(UInt64(0)) { $0 + $1.bytes }
        for item in kept.sorted(by: { $0.modified < $1.modified }) where total > maxTotalBytes {
            if (try? fm.removeItem(at: item.url)) != nil { removed += 1; total -= item.bytes }
        }
        for folder in folders where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
        if removed > 0 {
            logger.info("[PATCH] Sweep removed \(removed) undo record(s) (older than 7 days, or over \(self.maxTotalBytes / 1_048_576) MB in total). CONSEQUENCE: those writes can no longer be undone.")
        }
    }
}
