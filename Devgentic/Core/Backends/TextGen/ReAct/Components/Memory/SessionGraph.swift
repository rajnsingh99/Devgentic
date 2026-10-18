// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Status Vocabularies

/// Lifecycle of a `MemoryEpisode`: mirrors `ExecutionOutcome` for terminal states and adds `.active` for open episodes.
/// Bridge from executor outcomes via `EpisodeLifecycle(_:)`; there is no inverse because `.active` has no terminal
/// equivalent.
enum EpisodeLifecycle: String, Codable, Sendable {
    case active
    case completed
    case failed
    case cancelled

    /// Maps an executor terminal outcome into the corresponding terminal lifecycle.
    /// Use at every callsite where the executor's `ExecutionOutcome` needs to be
    /// committed back into a SessionGraph episode.
    init(_ outcome: ExecutionOutcome) {
        switch outcome {
        case .completed: self = .completed
        // Degraded success: the best-effort answer did not achieve its goal cleanly, so episodic memory keeps the failure
        // signal.
        case .completedWithWarnings: self = .failed
        case .failed:    self = .failed
        case .cancelled: self = .cancelled
        case .timedOut:  self = .failed   // the goal was not reached; episodic memory keeps the failure signal
        }
    }
}

/// Status of a `MemoryAction` within an episode: `ToolFailureCategory`'s failure shapes plus `.success` and `.active`.
/// Renders lowercase via `xmlValue` for `<action status>` in the episodic memory prompt.
enum ActionStatus: String, Codable, Sendable {
    case active
    case success
    case denied
    case permissionDenied
    case failed
    case timeout
    case invalidArgs
    case notFound
    case cancelled

    /// Lowercase value used in `<action status="...">` XML attributes.
    /// Multi-word cases use snake_case so the LLM can tell them from the simpler forms.
    var xmlValue: String {
        switch self {
        case .active:           return "active"
        case .success:          return "success"
        case .denied:           return "denied"
        case .permissionDenied: return "permission_denied"
        case .failed:           return "failed"
        case .timeout:          return "timeout"
        case .invalidArgs:      return "invalid_args"
        case .notFound:         return "not_found"
        case .cancelled:        return "cancelled"
        }
    }

    /// True when this status indicates a non-success terminal state. Used by
    /// the turn-status derivation in pointer/hybrid emitters: any failure
    /// category (not just `failed`/`denied`) marks the parent turn as failed.
    var isFailure: Bool {
        switch self {
        case .active, .success: return false
        default:                return true
        }
    }
}

// MARK: - Hierarchical Memory Models

// Why: Never stat at capture: capture runs on the main actor for every file write.
/// A file's observable state at a moment in time (size and mtime), built from content already in memory.
/// Comparison happens at render: `stat` first, reading the file only when the size still matches.
struct EffectFingerprint: Sendable, Codable, Equatable {
    let byteCount: Int
    /// A cheap, stable digest of the bytes written. Not cryptographic: this answers "is this the
    /// same content", not "did someone forge it".
    let contentHash: UInt64

    /// Fingerprints content the caller already holds. No I/O.
    static func of(_ content: String) -> EffectFingerprint {
        let bytes = Array(content.utf8)
        // FNV-1a: one pass, no allocation, no dependency. Collisions would mean a missed
        // staleness, which is the same direction as the pre-existing "no fingerprint" case.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return EffectFingerprint(byteCount: bytes.count, contentHash: hash)
    }

    /// True when the file at `path` differs from this fingerprint; an unreadable or deleted file reads as changed.
    /// Size is checked first and short-circuits, so the common case is one `stat` and no read.
    func differsFromDisk(at path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int else { return true }
        guard size == byteCount else { return true }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return true }
        return Self.of(content).contentHash != contentHash
    }
}

struct ActionEffect: Sendable, Codable, Equatable {
    /// Absolute path the action changed.
    let path: String
    let linesAdded: Int
    let linesRemoved: Int
    /// The changed lines with a little context — never the file. Nil when the change could
    /// not be reconstructed (no pre-write snapshot).
    let diff: String?
    /// True when `diff` hit the size cap. Surfaced in the XML so the model is never told a
    /// partial change is the whole one.
    let isTruncated: Bool

    // Why: Size and mtime, not a content hash: episodic memory is rebuilt every request and `stat` reads nothing.
    /// What the file looked like on disk right after this write, so the episodic record does not promise a stale diff.
    /// Optional: nil means staleness unknown, so effects stored before this field decode unchanged.
    let fingerprint: EffectFingerprint?

    init(path: String, linesAdded: Int, linesRemoved: Int, diff: String?, isTruncated: Bool,
         fingerprint: EffectFingerprint? = nil) {
        self.path = path
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.diff = diff
        self.isTruncated = isTruncated
        self.fingerprint = fingerprint
    }

    /// Longest diff carried into memory. Episodic memory rides in EVERY subsequent prompt,
    /// so this is a per-action budget, not a display limit. An eighth of the timeline's
    /// 32KB output cap: enough for a real edit, small enough that several per turn are safe.
    static let diffCharacterLimit = 4_096

    /// Aggregate ceiling for all effect diffs in one rendered episodic blob; `diffCharacterLimit` only bounds one action.
    /// Derived from the history char budget shared with `NativeHistoryConverter` (effects take a quarter), floored so one
    /// write renders whole.
    static func diffBudget(forHistoryCharBudget charBudget: Int) -> Int {
        max(diffCharacterLimit + 512, charBudget / 4)
    }

    var fileName: String { (path as NSString).lastPathComponent }

    /// One-line form for compact renderers: `X.java +14 −5`.
    var summary: String { "\(fileName) +\(linesAdded) −\(linesRemoved)" }
}

/// One action the agent took in an episode; maps to the LLM's `goalSummary`, decoupled from database identity
/// constraints.
struct MemoryAction: Sendable, Codable, Identifiable {
    let id: UUID
    let toolName: String
    let intent: String
    var status: ActionStatus
    var params: [String: String]
    var errorReason: String?
    var logs: [String]
    var artifacts: [MediaArtifact]
    /// What this action changed on disk, for mutating tools. Nil for reads, failures, and
    /// anything that didn't touch a file.
    var effect: ActionEffect?
    /// The COMMAND's exit status for shell-family tools. Carried separately from `status`
    /// because the TOOL succeeded — it ran the command — while the command itself may not
    /// have. Collapsing the two would abort runs on `grep` misses.
    var exitCode: Int32?

    init(id: UUID = UUID(), toolName: String = "", intent: String, status: ActionStatus = .active, params: [String: String] = [:], errorReason: String? = nil, logs: [String] = [], artifacts: [MediaArtifact] = [], effect: ActionEffect? = nil, exitCode: Int32? = nil) {
        self.id = id
        self.toolName = toolName
        self.intent = intent
        self.status = status
        self.params = params
        self.errorReason = errorReason
        self.logs = logs
        self.artifacts = artifacts
        self.effect = effect
        self.exitCode = exitCode
    }
}

/// Represents a single overarching interaction turn (User Query -> Agent Response).
/// Ephemeralized: Decoupled from persistent Core Data stores.
struct MemoryEpisode: Sendable, Codable, Identifiable {
    let id: UUID

    /// Holds the User's query for this turn.
    let primaryGoal: String

    var status: EpisodeLifecycle

    /// Holds the Agent's final synthesized response.
    var finalOutcome: String?

    /// NEW: A brief description or intent of the turn for pointer-based memory.
    var summary: String?

    var actions: [MemoryAction]

    /// Captures user correction/denial signal for this turn.
    var userCorrection: String?

    init(id: UUID = UUID(), primaryGoal: String, status: EpisodeLifecycle = .active, finalOutcome: String? = nil, summary: String? = nil, actions: [MemoryAction] = [], userCorrection: String? = nil) {
        self.id = id
        self.primaryGoal = primaryGoal
        self.status = status
        self.finalOutcome = finalOutcome
        self.summary = summary
        self.actions = actions
        self.userCorrection = userCorrection
    }

    /// Returns the currently active action, if any.
    var activeAction: MemoryAction? {
        return actions.first { $0.status == .active }
    }
}

/// The root object for the agent's active cognitive state: computed on demand from `ChatMessage` history, not persisted.
struct SessionGraph: Sendable, Codable {
    let sessionID: String
    var episodes: [MemoryEpisode]
    var negativeConstraints: [String]
    
    /// A simple key-value store that starts fresh on every new user request.
    var workingMemory: [String: String]
    
    init(
        sessionID: String,
        episodes: [MemoryEpisode] = [],
        negativeConstraints: [String] = [],
        workingMemory: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.episodes = episodes
        self.negativeConstraints = negativeConstraints
        self.workingMemory = workingMemory
    }
    
    // MARK: - Episode Lifecycle Operations

    /// Closes the active episode using the executor's typed `ExecutionOutcome`.
    /// The episode's lifecycle and the last action's status derive from the same outcome, with no string literals.
    mutating func closeActiveEpisode(outcome: ExecutionOutcome, message: String? = nil) {
        let lifecycle = EpisodeLifecycle(outcome)
        if let idx = episodes.lastIndex(where: { $0.status == .active }) {
            episodes[idx].status = lifecycle
            if let message {
                episodes[idx].finalOutcome = message
            }
            // Mirror the new lifecycle onto the last action so `activeAction`
            // doesn't keep returning what is now a terminal-state action.
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = Self.actionStatus(for: lifecycle)
            }
        }
    }

    mutating func cancelActiveEpisode() {
        if let idx = episodes.lastIndex(where: { $0.status == .active }) {
            episodes[idx].status = .cancelled
            if let actIdx = episodes[idx].actions.indices.last {
                episodes[idx].actions[actIdx].status = .cancelled
            }
        }
    }

    /// Maps an episode's lifecycle stamp into the action-status vocabulary so the
    /// last action mirrors its parent episode's terminal state. Episode
    /// `.completed` collapses to action `.success`; the other terminals map 1:1.
    private static func actionStatus(for lifecycle: EpisodeLifecycle) -> ActionStatus {
        switch lifecycle {
        case .active:    return .active
        case .completed: return .success
        case .failed:    return .failed
        case .cancelled: return .cancelled
        }
    }
}

// MARK: - Session Graph Store

/// In-memory cache of active `SessionGraph` instances, keyed by conversation ID.
actor SessionGraphStore {
    static let shared = SessionGraphStore()
    private var graphs: [UUID: SessionGraph] = [:]

    func getActiveState(for conversationID: UUID) -> SessionGraph {
        return graphs[conversationID] ?? SessionGraph(sessionID: conversationID.uuidString)
    }

    func updateActiveState(conversationID: UUID, state: SessionGraph) {
        graphs[conversationID] = state
    }
}
