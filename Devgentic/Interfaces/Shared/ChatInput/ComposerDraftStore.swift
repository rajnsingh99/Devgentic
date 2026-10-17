// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerDraftStore.swift
//  Devgentic
//
//  Per-conversation composer drafts (typed text + attachments), held for the app session.
//
//  WHY: the composer's view model is APP-SCOPED — one `ChatInputViewModel` for every
//  conversation (`DevgenticApp`), and `attachedFiles` likewise lives on the single
//  `MainApplicationViewModel`. Nothing reset either when the selected conversation
//  changed, so a half-typed message and its attachments followed you from conversation A
//  into B, where they could be sent by accident. (Asymmetric, too: `startNewConversation`
//  cleared attachments but never the text.)
//
//  This store makes the composer's contents belong to a conversation: they're saved under
//  the one you're leaving and restored for the one you're entering.
//
//  PERSISTED across launches (user decision 2026-10-05): saved as JSON in Application
//  Support/Devgentic/ComposerDrafts.json. The two questions that kept it session-only were
//  answered, not ignored:
//   • Staleness — a draft untouched for `maxAge` is dropped at load, and an attachment whose
//     file is gone is dropped at restore.
//   • Privacy — unsent text now lives on disk until it is sent or cleared; it is the user's
//     own text in the user's own Application Support, which the user chose.
//  Under XCTest the shared store is memory-only; tests that need the disk build their own.
//

import Foundation

@MainActor
final class ComposerDraftStore {

    /// Shared instance used by the composer and the conversation coordinator. The type is
    /// still freely instantiable so tests get an isolated store instead of shared state.
    static let shared = ComposerDraftStore(
        fileURL: TestHost.isRunning ? nil : ComposerDraftStore.defaultFileURL()
    )

    /// Drafts not touched for this long are dropped at load.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let fileURL: URL?
    private let logger = DGLogger(category: "ComposerDraftStore")
    private var pendingWrite: Task<Void, Never>?

    /// - Parameter fileURL: where drafts persist; nil keeps them in memory (tests).
    init(fileURL: URL? = nil, now: Date = Date()) {
        self.fileURL = fileURL
        load(now: now)
    }

    static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Devgentic", isDirectory: true)
            .appendingPathComponent("ComposerDrafts.json")
    }

    /// What the composer holds for one conversation.
    struct Draft: Equatable {
        var text: String = ""
        var attachments: [FileSystemItem] = []

        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    /// Where a draft belongs: an interface MODE and a conversation in it.
    ///
    /// ⚠️ The mode is part of the key because every mode's Home is the SAME conversation id —
    /// `nil`. Keyed by conversation alone, text and attachments typed on Code's Home appeared on
    /// Chat's Home after a mode switch (and a Home → Home switch changed no conversation id at
    /// all, so nothing even swapped). `nil` is still a real key — the not-yet-created
    /// conversation of THAT mode — so a draft typed before the first send survives a detour.
    struct Key: Hashable {
        let mode: MainApplicationViewModel.InterfaceMode
        let conversationID: UUID?

        init(_ mode: MainApplicationViewModel.InterfaceMode, _ conversationID: UUID?) {
            self.mode = mode
            self.conversationID = conversationID
        }
    }

    private var drafts: [Key: Draft] = [:]
    private var updatedAt: [Key: Date] = [:]

    /// Number of stored drafts — for tests and for reasoning about growth.
    var storedDraftCount: Int { drafts.count }

    /// Saves the draft for a conversation. An EMPTY draft removes the entry rather than
    /// storing it, so merely visiting a conversation doesn't leave a slot behind and a
    /// sent (cleared) composer doesn't resurrect as an empty draft later.
    func save(_ draft: Draft, for key: Key) {
        guard drafts[key] != draft else { return }
        if draft.isEmpty {
            drafts.removeValue(forKey: key)
            updatedAt.removeValue(forKey: key)
        } else {
            drafts[key] = draft
            updatedAt[key] = Date()
        }
        scheduleWrite()
    }

    /// The stored draft, or an empty one — restoring an empty draft is what CLEARS the
    /// composer when entering a conversation that has none.
    func draft(for key: Key) -> Draft {
        drafts[key] ?? Draft()
    }

    /// Drops a conversation's draft, in whichever mode holds it. Called when the conversation
    /// is deleted so unsent text doesn't outlive the thing it belonged to.
    func discard(for conversationID: UUID?) {
        let keys = drafts.keys.filter { $0.conversationID == conversationID }
        guard !keys.isEmpty else { return }
        for key in keys {
            drafts.removeValue(forKey: key)
            updatedAt.removeValue(forKey: key)
        }
        scheduleWrite()
    }

    // MARK: - Persistence

    private struct StoredDraft: Codable {
        let mode: String
        let conversationID: UUID?
        let text: String
        let attachmentPaths: [String]
        let attachmentIsDirectory: [Bool]
        let updatedAt: Date
    }

    /// Coalesces bursts (every keystroke saves) into one write shortly after typing pauses.
    private func scheduleWrite() {
        guard fileURL != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    /// Writes immediately — also called at quit so the last keystrokes are not lost.
    func writeNow() {
        pendingWrite?.cancel()
        guard let fileURL else { return }
        let stored = drafts.map { key, draft in
            StoredDraft(mode: key.mode.rawValue, conversationID: key.conversationID, text: draft.text,
                        attachmentPaths: draft.attachments.map(\.url.path),
                        attachmentIsDirectory: draft.attachments.map(\.isDirectory),
                        updatedAt: updatedAt[key] ?? Date())
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("[DRAFTS] Could not save \(stored.count) composer draft(s) to \(fileURL.path): \(error.localizedDescription). CONSEQUENCE: they are kept for this session but will not be restored after a relaunch.")
        }
    }

    private func load(now: Date) {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let stored = try JSONDecoder().decode([StoredDraft].self, from: Data(contentsOf: fileURL))
            var expired = 0
            for entry in stored {
                guard let mode = MainApplicationViewModel.InterfaceMode(rawValue: entry.mode) else { continue }
                guard now.timeIntervalSince(entry.updatedAt) <= Self.maxAge else { expired += 1; continue }
                // A file moved or deleted while the app was closed is dropped here, at restore —
                // within a session the send path reports a missing file with its own cause.
                let attachments = zip(entry.attachmentPaths, entry.attachmentIsDirectory)
                    .filter { path, _ in FileManager.default.fileExists(atPath: path) }
                    .map { path, isDirectory in
                        let url = URL(fileURLWithPath: path)
                        return FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: isDirectory)
                    }
                let key = Key(mode, entry.conversationID)
                drafts[key] = Draft(text: entry.text, attachments: attachments)
                updatedAt[key] = entry.updatedAt
            }
            logger.info("[DRAFTS] Restored \(self.drafts.count) composer draft(s) from the last launch\(expired > 0 ? "; dropped \(expired) untouched for over 30 days" : "").")
        } catch {
            logger.error("[DRAFTS] Could not read saved drafts at \(fileURL.path): \(error.localizedDescription). CONSEQUENCE: this launch starts with no saved drafts; the file is overwritten at the next save.")
        }
    }
}
