// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MediaStore.swift
//  Devgentic
//
//  Multimodal Pipeline Migration — Phase 2
//  Disk-backed binary media storage to prevent RAM leaks in long sessions.
//  All binary data flows through this actor — MessageBlock and MediaArtifact
//  hold MediaReference.diskPath, never raw Data in long-lived structures.
//
//  Created by Raj Singh on 15/03/26.
//
//  ⚠️ READINESS CR-65 (2026-10-12). `evict` and `pruneIfNeeded` had ZERO callers and the manifest
//  they read lived in memory only, so every generated image stayed on disk forever, including after
//  its conversation was deleted. The fix is NOT to wire the prune: these files are the images IN
//  saved conversations (messages reference them by path), so an oldest-first size cap would delete
//  pictures out of chats the user kept, with no warning. The prune and the in-memory manifest are
//  DELETED. A folder now lives exactly as long as its conversation: `evict` runs after a delete has
//  committed (`ChatPersistenceStore.deleteConversation`), and the launch sweep
//  (`removeOrphanedConversations`) collects the folders of conversations deleted before this fix,
//  or whose eviction a crash interrupted.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MediaStore")

/// Manages binary media lifecycle: write-to-disk, resolve, evict.
public actor MediaStore {
    /// ⚠️ Redirected to a temporary folder under XCTest. The test host IS the real app, and the
    /// chat store is already redirected to a test database there, so a launch sweep against the
    /// REAL folder would treat every real conversation's images as orphans and delete them.
    public static let shared = MediaStore(baseDirectory: MediaStore.defaultBaseDirectory())

    let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        // Ensure base directory exists
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    private static func defaultBaseDirectory() -> URL {
        if TestHost.isRunning {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DevgenticTestMediaCache-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Devgentic/MediaCache", isDirectory: true)
    }

    private func directory(for conversationID: UUID) -> URL {
        baseDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    // MARK: - Store

    /// Persist ephemeral data to disk, return stable disk reference.
    public func store(
        data: Data,
        mimeType: String,
        conversationID: UUID
    ) throws -> MediaReference {
        let conversationDir = directory(for: conversationID)
        try FileManager.default.createDirectory(at: conversationDir, withIntermediateDirectories: true)

        let fileID = UUID()
        let ext = Self.mimeExtension(for: mimeType)
        let fileURL = conversationDir.appendingPathComponent("\(fileID.uuidString)\(ext)")

        try data.write(to: fileURL)

        logger.debug("Stored media \(fileID.uuidString) (\(data.count) bytes) for conversation \(conversationID.uuidString)")

        return .diskPath(fileURL)
    }

    // MARK: - Evict

    /// Deletes all media of a conversation whose delete has COMMITTED. Returns the files removed.
    ///
    /// ⚠️ Call only after the conversation's delete is on disk: a delete that failed to save brings
    /// the conversation back on the next launch, and its images must still be there.
    @discardableResult
    public func evict(conversationID: UUID) -> Int {
        let conversationDir = directory(for: conversationID)
        guard FileManager.default.fileExists(atPath: conversationDir.path) else { return 0 }
        let (files, bytes) = Self.contents(of: conversationDir)
        do {
            try FileManager.default.removeItem(at: conversationDir)
            logger.info("[MEDIA] Evicted \(files) media file(s) (\(bytes / 1024) KB) of deleted conversation \(conversationID.uuidString.prefix(8)).")
            return files
        } catch {
            logger.error("[MEDIA] FAILED to evict the media of deleted conversation \(conversationID.uuidString.prefix(8)) (\(files) file(s), \(bytes / 1024) KB): \(error.localizedDescription). CONSEQUENCE: the files stay on disk for now; the next launch's orphan sweep retries.")
            return 0
        }
    }

    // MARK: - Orphan sweep

    /// Removes the media folder of every conversation that no longer exists. Returns the folders removed.
    ///
    /// ⚠️ Only folders named by a conversation UUID are considered; anything else is left alone.
    /// An EMPTY live set is refused, like the memory sweep's: a listing that came back empty by
    /// mistake would otherwise read as "delete every conversation's images".
    @discardableResult
    public func removeOrphanedConversations(liveConversationIDs: Set<UUID>) -> Int {
        guard !liveConversationIDs.isEmpty else {
            logger.warning("[MEDIA] Orphan sweep SKIPPED — the conversation list is empty. CONSEQUENCE: none now; media of conversations deleted without cleanup (if any) stays on disk until a launch that sees at least one conversation.")
            return 0
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var removed = 0, files = 0, bytes = 0
        for entry in entries where entry.hasDirectoryPath {
            guard let id = UUID(uuidString: entry.lastPathComponent), !liveConversationIDs.contains(id) else { continue }
            let (count, size) = Self.contents(of: entry)
            do {
                try FileManager.default.removeItem(at: entry)
                removed += 1; files += count; bytes += size
            } catch {
                logger.error("[MEDIA] Orphan sweep could not remove the media of deleted conversation \(id.uuidString.prefix(8)): \(error.localizedDescription). CONSEQUENCE: those \(count) file(s) stay on disk; the next launch retries.")
            }
        }
        if removed > 0 {
            logger.notice("[MEDIA] Orphan sweep removed the media of \(removed) deleted conversation(s): \(files) file(s), \(bytes / 1_048_576) MB.")
        }
        return removed
    }

    /// Runs `removeOrphanedConversations` on `shared` off the caller, at utility priority.
    nonisolated static func sweepOrphansInBackground(liveConversationIDs: Set<UUID>) {
        Task.detached(priority: .utility) {
            await shared.removeOrphanedConversations(liveConversationIDs: liveConversationIDs)
        }
    }

    // MARK: - Helpers

    private static func contents(of directory: URL) -> (files: Int, bytes: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        var files = 0, bytes = 0
        for case let url as URL in enumerator {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { continue }
            files += 1; bytes += size
        }
        return (files, bytes)
    }

    private static func mimeExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return ".png"
        case "image/jpeg", "image/jpg": return ".jpg"
        case "image/webp": return ".webp"
        case "image/gif": return ".gif"
        case "audio/mpeg", "audio/mp3": return ".mp3"
        case "audio/wav": return ".wav"
        case "video/mp4": return ".mp4"
        case "video/quicktime": return ".mov"
        case "application/pdf": return ".pdf"
        default: return ".bin"
        }
    }
}
