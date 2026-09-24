// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SessionGraph.swift
//  Devgentic
//
//  Created by Devgentic Architect
//  Updated: Memory Architecture Migration - Phase 3 (XML Episodic Memory)
//

import Foundation

// MARK: - Status Vocabularies

/// Lifecycle of a `MemoryEpisode`. Mirrors `ExecutionOutcome` for terminal states
/// and adds `.active` for in-progress episodes that haven't been closed yet.
///
/// Decoupled from `ExecutionOutcome` so the `.active` lifecycle case lives outside
/// the executor's terminal vocabulary. Bridge from executor outcomes via
/// `EpisodeLifecycle(_:)` — there is no inverse because `.active` has no terminal
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
        // Degraded success: the run shipped a best-effort answer but did NOT achieve its
        // goal cleanly — episodic memory keeps the failure signal (the executor also
        // passes `.failed` for episodes explicitly; this mapping is the safety net).
        case .completedWithWarnings: self = .failed
        case .failed:    self = .failed
        case .cancelled: self = .cancelled
        }
    }
}

/// Status of a `MemoryAction` within an episode. Mirrors `ToolFailureCategory`'s
/// failure shapes plus `.success` for clean completion and `.active` for
/// in-progress actions. Renders to lowercase via `xmlValue` for `<action status>`
/// emission in the prompt-injected episodic memory.
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
    /// Multi-word cases use snake_case so the LLM can distinguish them from the
    /// simpler forms; this also matches existing pre-training conventions for
    /// failure-category names in API documentation and chat templates.
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

/// Represents a specific action or sub-task the agent took.
/// What a mutating action actually DID — the change itself, never the whole file.
///
/// Without this the agent has no memory of its own edits: `MemoryAction` recorded the tool
/// name, 200-char-truncated params and a status, and output only ever landed in
/// `errorReason` on the FAILURE path. Asked to undo a write, the model answered "I do not
/// have access to a version control system… restoring the file perfectly is impossible" —
/// while the app was holding the pre-write snapshot the whole time (field-observed
/// 2026-07-25). Reverting is not a tooling problem; it was a memory problem.
///
/// Persisted (unlike the raw snapshots it derives from) so a resumed or reopened
/// conversation can still describe and undo what it changed — see
/// `Docs/codeviewer-rescope-design.md` §12 D1.
/// A file's observable state at a moment in time.
///
/// ⚠️⚠️ BUILT FROM CONTENT ALREADY IN MEMORY — never by stat'ing at capture. The first version of
/// this took `FileManager.attributesOfItem` inside `ActionEffectBuilder.from`, which runs ON THE
/// MAIN ACTOR for every file write (`ActiveStreamManager.completeToolTimelineEvent`,
/// `CapabilityCardRouter.completeTool`). That file's own comment already warns what main-thread
/// work there costs — "the transcript stopped scrolling and Stop did not respond" — and the
/// syscall made the CodeViewer live-write suite ~40% slower, which was enough to tip a
/// race-sensitive test over its budget. Measured 2026-09-20.
///
/// So the expensive half is the COMPARISON, which happens at render, and it is ordered to stay
/// cheap: `stat` first (one syscall, no read) and only read the file when the size still matches.
/// A change that alters length — nearly all of them — costs no read at all.
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

    /// True when the file at `path` no longer matches this fingerprint.
    ///
    /// ⚠️ A file that cannot be read reads as CHANGED. Deleted or unreadable is precisely where a
    /// stored diff misleads most, and "I could not check" must never render as "unchanged".
    ///
    /// ⚠️ Size is checked FIRST and short-circuits. That is the whole performance story: a real
    /// edit almost always changes the length, so the common case is one `stat` and no read.
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

    /// What the file looked like on disk immediately after this write.
    ///
    /// ⚠️⚠️ Exists so the episodic record stops PROMISING a retrieval it cannot honour. The
    /// `<effect>` element advertises `diff="on_demand"`, meaning "call get_conversation_history(N)
    /// and you will get the change for this file". Once the file changes underneath — a git
    /// checkout, the user's editor, another agent — that stored diff no longer describes it, and
    /// the promise is false. Same class as the `get_conversation_history` promise made to
    /// tool-less profiles, fixed 2026-09-20.
    ///
    /// ⚠️ OPTIONAL, and that is mandatory rather than stylistic. Every effect already in the
    /// store predates this field, and a non-optional property on a `Codable` type throws
    /// `keyNotFound` on each of those blobs. Nil therefore means "staleness UNKNOWN" — a third
    /// state, rendered as neither fresh nor stale, so old conversations are byte-identical.
    ///
    /// ⚠️ Size + mtime, NOT a content hash. Comparing requires reading the file, and episodic
    /// memory is rebuilt on every request — a hash would put the whole file on the hot path.
    /// `stat` reads nothing. Its weakness is a false STALE on a touch that changed no bytes,
    /// which costs one re-read; the opposite error would let the model trust a file that moved.
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

    /// Aggregate ceiling for ALL effect diffs in one rendered episodic blob.
    ///
    /// `diffCharacterLimit` bounds ONE action and nothing bounded the sum, so "small
    /// enough that several per turn are safe" was an assumption the code never enforced:
    /// a turn with ten writes carried up to 40 KB, multiplied again across
    /// `buildRecentHistoryString`'s ten turns, and across the whole conversation under
    /// `fullHistory`. Episodic memory rides in EVERY prompt, so that is unbounded growth
    /// on the hot path — on a small local model it crowds out the request itself.
    ///
    /// Derived from the history char budget rather than invented. `AgentConnect` already
    /// allocates that to the sibling `NativeHistoryConverter`, and both channels ride the
    /// SAME prompt: a second independent allocation would double-spend the window. Effects
    /// take a quarter of it, floored so one ordinary write always renders whole even on a
    /// tiny context.
    static func diffBudget(forHistoryCharBudget charBudget: Int) -> Int {
        max(diffCharacterLimit + 512, charBudget / 4)
    }

    var fileName: String { (path as NSString).lastPathComponent }

    /// One-line form for compact renderers: `X.java +14 −5`.
    var summary: String { "\(fileName) +\(linesAdded) −\(linesRemoved)" }
}

/// Maps to the LLM's `goalSummary`. Replaces the old `SubTask` model.
/// Decoupled from database identity constraints.
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

/// The root object for the agent's active cognitive state.
/// Ephemeralized: This is no longer persisted to a database. It represents a computed
/// state dynamically generated from the Single Source of Truth (`ChatMessage` history).
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
    /// The lifecycle stamp on the episode and the matching status on the last
    /// action are derived from the same source of truth — no scattered string
    /// literals, no risk of mismatched casing or typos.
    ///
    /// Parameter rename (`status:` → `outcome:`, `outcome:` → `message:`) is
    /// intentional: the new signature is incompatible with the old one so the
    /// compiler flags every callsite during migration.
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

/// In-memory cache for active SessionGraph instances, keyed by conversation ID.
/// Replaces the legacy ContextMemoryManager.
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
