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

import Foundation
import OSLog

private let logger = DGLogger(category: "MediaStore")

/// Manages binary media lifecycle: write-to-disk, resolve, evict.
public actor MediaStore {
    public static let shared = MediaStore()

    private let baseDirectory: URL
    private let maxCacheSizeMB: Int = 500

    private struct MediaEntry: Codable {
        let id: UUID
        let conversationID: UUID
        let fileURL: URL
        let mimeType: String
        let sizeBytes: Int
        let createdAt: Date
    }

    private var manifest: [UUID: MediaEntry] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.baseDirectory = appSupport.appendingPathComponent("Devgentic/MediaCache", isDirectory: true)

        // Ensure base directory exists
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Store

    /// Persist ephemeral data to disk, return stable disk reference.
    public func store(
        data: Data,
        mimeType: String,
        conversationID: UUID
    ) throws -> MediaReference {
        let conversationDir = baseDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: conversationDir, withIntermediateDirectories: true)

        let fileID = UUID()
        let ext = Self.mimeExtension(for: mimeType)
        let fileURL = conversationDir.appendingPathComponent("\(fileID.uuidString)\(ext)")

        try data.write(to: fileURL)

        let entry = MediaEntry(
            id: fileID,
            conversationID: conversationID,
            fileURL: fileURL,
            mimeType: mimeType,
            sizeBytes: data.count,
            createdAt: Date()
        )
        manifest[fileID] = entry

        logger.debug("Stored media \(fileID.uuidString) (\(data.count) bytes) for conversation \(conversationID.uuidString)")

        return .diskPath(fileURL)
    }

    // MARK: - Evict

    /// Evict all media for a completed/deleted conversation.
    public func evict(conversationID: UUID) {
        let conversationDir = baseDirectory.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        let entriesToRemove = manifest.filter { $0.value.conversationID == conversationID }

        for (id, _) in entriesToRemove {
            manifest.removeValue(forKey: id)
        }

        try? FileManager.default.removeItem(at: conversationDir)
        logger.info("Evicted \(entriesToRemove.count) media entries for conversation \(conversationID.uuidString)")
    }

    // MARK: - Prune

    /// LRU eviction when cache exceeds maxCacheSizeMB.
    public func pruneIfNeeded() {
        let totalBytes = manifest.values.reduce(0) { $0 + $1.sizeBytes }
        let maxBytes = maxCacheSizeMB * 1_048_576

        guard totalBytes > maxBytes else { return }

        // Sort by creation date (oldest first)
        let sorted = manifest.values.sorted { $0.createdAt < $1.createdAt }
        var freed = 0
        var removedCount = 0

        for entry in sorted {
            guard totalBytes - freed > maxBytes else { break }

            try? FileManager.default.removeItem(at: entry.fileURL)
            manifest.removeValue(forKey: entry.id)
            freed += entry.sizeBytes
            removedCount += 1
        }

        // Clean up empty conversation directories
        if let contents = try? FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) {
            for dir in contents where dir.hasDirectoryPath {
                if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path), items.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }

        logger.info("Pruned \(removedCount) media entries, freed \(freed / 1_048_576)MB")
    }

    // MARK: - Helpers

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
