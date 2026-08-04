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
import SwiftUI
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
    /// User pressed Pause. The partial bytes are deliberately KEPT on disk — HubApi resumes
    /// from them via a `Range` header — so this is the one non-active state that is not a
    /// failure and must never be cleaned up automatically.
    case paused

    /// `true` for states that represent a completed (non-active) lifecycle.
    /// Used to partition the Downloads sidebar into "in-progress" vs history.
    ///
    /// `.paused` counts as terminal here because nothing is transferring: it must not appear
    /// in the "In Progress" section, must not hold the sleep assertion, and must not be
    /// swept by `reconcileOrphans` (which only touches `.queued`/`.downloading`). Resumability
    /// is a separate question — see `isResumable`.
    var isTerminal: Bool {
        switch self {
        case .queued, .downloading:
            return false
        case .completed, .failed, .cancelled, .interrupted, .paused:
            return true
        }
    }

    /// `true` when the download can continue from the bytes already on disk.
    ///
    /// swift-transformers resumes for free — `Downloader` reads `incompleteFileSize(at:)` and
    /// sends `Range: bytes=N-` — so the only requirement is that the `.incomplete` files were
    /// not deleted. `.cancelled` is excluded deliberately: cancelling discards the partial.
    var isResumable: Bool {
        switch self {
        case .paused, .interrupted, .failed: return true
        case .queued, .downloading, .completed, .cancelled: return false
        }
    }

    /// User-facing name. ⚠️ `rawValue` is persisted — never change it for display.
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .queued:      return "Queued"
        case .downloading: return "Downloading"
        case .completed:   return "Completed"
        case .failed:      return "Failed"
        case .cancelled:   return "Cancelled"
        case .interrupted: return "Interrupted"
        case .paused:      return "Paused"
        }
    }
}

@Model
final class DownloadRecord {

    /// Indexes on the three predicated columns.
    ///
    /// `fetchMostRecent` filters on `(backendRaw, modelIdentifier)` and `fetchActive` on
    /// `statusRaw`; both are called from the download bridges on every reconcile tick, and
    /// without indexes each was a full-table predicate scan.
    ///
    /// ⚠️ This is a schema change. Adding an index is lightweight-migration compatible (it
    /// alters no attribute), unlike adding a non-optional property without a default — but the
    /// app has no `VersionedSchema`/`SchemaMigrationPlan`, so any schema touch is worth
    /// verifying against a real existing store before shipping. See the migration work tracked
    /// separately from G15.
    #Index<DownloadRecord>([\.backendRaw], [\.modelIdentifier], [\.statusRaw], [\.updatedAt])


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

    /// Git commit the model was downloaded at, for MLX.
    ///
    /// ⚠️ OPTIONAL on purpose. An optional property (or one with a default) is
    /// lightweight-migration safe; a non-optional with no default is the change that makes the
    /// shared container fail to open and bricks the app after a Sparkle update. See
    /// `SWIFTDATA_MIGRATION_PLAN.md`.
    var revisionCommitHash: String?

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
