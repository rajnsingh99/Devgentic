//
//  DownloadRecordSD.swift
//  Devgentic
//
//  Created 2026-04-21.
//
//  SwiftData @Model for persistent download history. Replaces the session-only
//  `DownloadEntry` struct that used to live on `DownloadManager`. Every model
//  pull across Ollama, MLX, and Whisper now writes a record here so users can
//  see their download history across launches, re-initiate past downloads,
//  and surface per-model status inline in each store view.
//
//  Status semantics:
//
//    queued       — record created, service hasn't reported progress yet
//    downloading  — actively in flight (progress 0..<1)
//    completed    — terminal success; model is on disk as of `updatedAt`
//    failed       — terminal failure; `errorMessage` populated
//    cancelled    — user cancelled; `cancelReason` optionally populated
//    interrupted  — app crashed/killed mid-download; detected on relaunch by
//                   DownloadHistoryStore.reconcileOrphans()
//

import Foundation
import SwiftData

/// Persistable subset of `DownloadStatus`. Kept separate from the session-only
/// `DownloadStatus` enum (which carries an associated String for `.failed`) so
/// the stored value is a flat raw-representable String. UI callers should
/// prefer this type over the legacy one for any query / display.
enum DownloadRecordStatus: String, CaseIterable, Codable, Hashable {
    case queued
    case downloading
    case completed
    case failed
    case cancelled
    case interrupted

    /// `true` for states that represent a completed (non-active) lifecycle.
    /// Used to partition the Downloads sidebar into "in-progress" vs history.
    var isTerminal: Bool {
        switch self {
        case .queued, .downloading:           return false
        case .completed, .failed, .cancelled, .interrupted: return true
        }
    }
}

@Model
final class DownloadRecord {

    @Attribute(.unique)
    var id: UUID

    /// Raw value of `ModelBackendType` ("Ollama" | "MLX" | "Whisper").
    /// Stored as String rather than the enum directly so SwiftData's schema
    /// migration story stays simple — if we add a fourth backend later,
    /// rows written by the old build still decode via the tolerant accessor.
    var backendRaw: String

    /// Canonical identifier the backend uses (e.g. "qwen2.5:7b",
    /// "mlx-community/Llama-3.2-3B-Instruct-4bit", "openai_whisper-base.en").
    /// This is what `startDownloadIfNeeded` uses for dedup lookups.
    var modelIdentifier: String

    /// User-facing name. Falls back to `modelIdentifier` if the backend
    /// doesn't surface a friendlier label.
    var displayName: String

    /// Raw value of `DownloadRecordStatus`. See enum doc.
    var statusRaw: String

    /// 0.0...1.0. Written via a 1%-delta throttle (see `ProgressThrottler`)
    /// so rapidly-streaming backends don't thrash SwiftData.
    var progress: Double

    /// Populated on successful completion when the backend reports it
    /// (Ollama supplies byte totals; MLX/Whisper may not).
    var fileSizeBytes: Int64?

    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?

    var errorMessage: String?
    var cancelReason: String?

    /// Optional source reference for re-download (HF repo URL, Ollama
    /// registry name). Not used by the backends at trigger time — they
    /// already know how to resolve `modelIdentifier` — but useful for
    /// future "export history" or "import shared library" flows.
    var sourceURL: String?

    /// Profile that initiated the download, if any. Lets us scope the
    /// sidebar to a specific profile later, and cleanly wire row-tap
    /// navigation back to the originating model store.
    var profileID: UUID?

    init(
        id: UUID = UUID(),
        backend: ModelBackendType,
        modelIdentifier: String,
        displayName: String? = nil,
        status: DownloadRecordStatus = .queued,
        progress: Double = 0,
        fileSizeBytes: Int64? = nil,
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        cancelReason: String? = nil,
        sourceURL: String? = nil,
        profileID: UUID? = nil
    ) {
        self.id = id
        self.backendRaw = backend.rawValue
        self.modelIdentifier = modelIdentifier
        self.displayName = displayName ?? modelIdentifier
        self.statusRaw = status.rawValue
        self.progress = progress
        self.fileSizeBytes = fileSizeBytes
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.cancelReason = cancelReason
        self.sourceURL = sourceURL
        self.profileID = profileID
    }
}

// MARK: - Tolerant accessors

extension DownloadRecord {
    /// Type-safe backend lookup. Nil only if a future build writes an
    /// unknown backend raw that this build doesn't recognize.
    var backend: ModelBackendType? {
        ModelBackendType(rawValue: backendRaw)
    }

    /// Type-safe status lookup. Nil only if the stored raw is corrupted
    /// or written by a future build with new cases.
    var status: DownloadRecordStatus? {
        DownloadRecordStatus(rawValue: statusRaw)
    }

    /// Convenience for UI — returns `true` while the download is still
    /// active (queued or downloading).
    var isActive: Bool {
        let s = status ?? .failed
        return !s.isTerminal
    }
}
