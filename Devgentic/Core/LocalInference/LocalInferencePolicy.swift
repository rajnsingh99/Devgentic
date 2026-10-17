// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferencePolicy.swift
//  Devgentic
//
//  The coordinator's decisions, as pure functions over its state.
//
//  ⚠️ No side effects and no clock reads: `now` is a parameter. Everything the coordinator decides is
//  decided here, so the whole decision table is testable without a run, a model or a main actor —
//  the shape `RunAdmissionPolicy` and `ICReleasePolicy` already use.
//

import Foundation

enum CoordinatorDecision: Equatable, Sendable {
    case admit(AdmitReason)
    /// `behind` is the run holding the lock (or, if none, the head of the queue). `position` is 1-based.
    case hold(behind: UUID, position: Int)
    /// Phase 7: the run raises a concern its user should see first. It is held — keeping its place in
    /// line, never blocking it — until they choose Proceed (it then waits its turn like any run) or
    /// Stop; with no answer it is auto-denied after `LocalInferenceCoordinator.confirmationTimeout`.
    case confirm([RunConcern])
    case deny(DenyReason)
}

/// Something about a run its user is asked about before it starts (phase 7). Raised only from
/// MEASUREMENTS (`InferenceRunManifest.footprint`), never from a label.
enum RunConcern: Equatable, Sendable, CustomStringConvertible {
    /// A model's measured footprint exceeds this Mac's whole model budget: it may run very slowly
    /// (swapping) or fail.
    case memory(modelID: String, estimatedBytes: UInt64, budgetBytes: UInt64)

    var description: String {
        switch self {
        case .memory(let model, let estimated, let budget):
            return "'\(model)' is estimated at ~\(ByteCountFormatter.string(fromByteCount: Int64(estimated), countStyle: .memory)), "
                + "above this Mac's \(ByteCountFormatter.string(fromByteCount: Int64(budget), countStyle: .memory)) model budget"
        }
    }
}

enum AdmitReason: Equatable, Sendable {
    /// Cloud-only: never takes the lock (decision D3).
    case noLocalModel
    case lockFree
}

/// Why a run is refused. ⚠️ TWO cases, both owner decisions — and neither refuses a run on a
/// concern WITHOUT ASKING:
/// - D5, the sub-agent fallback guard (never expected: sub-agents are hidden);
/// - phase 7, a concern the user was asked about and did not answer in time.
///
/// ⚠️⚠️ There is NO direct memory-fit deny, and there must not be one. It existed until 2026-10-08 and
/// refused a 3B model (1.75 GB on disk) as "needs ~20 GB": the profile's stored metadata had no
/// parameter count, so the estimate fell back to its TIER's flat guess. A concern now ASKS
/// (`CoordinatorDecision.confirm`); the run is refused only when nobody answers.
enum DenyReason: Equatable, Sendable, CustomStringConvertible {
    /// Decision D5 — sub-agents are withdrawn; a local delegating run is the fallback guard's case.
    case subAgentsUnsupportedLocally
    /// Phase 7: the user was asked about `concerns` and chose neither Proceed nor Stop within `after`.
    case notConfirmed(concerns: [RunConcern], after: TimeInterval)

    /// The title of the run's error card.
    var title: String {
        switch self {
        case .subAgentsUnsupportedLocally: return "Not started"
        case .notConfirmed: return "Auto-denied"
        }
    }

    var description: String {
        switch self {
        case .subAgentsUnsupportedLocally:
            return "sub-agents are not supported on a local model"
        case .notConfirmed(let concerns, let after):
            let why = concerns.map(\.description).joined(separator: "; ")
            let wait = after >= 60 ? "\(Int((after / 60).rounded())) min" : "\(Int(after.rounded())) s"
            return "\(why). Nobody chose Proceed within \(wait), so the run was not started"
        }
    }
}

/// A run waiting for the local lock.
struct QueuedRun: Equatable, Sendable {
    let runID: UUID
    let priority: PriorityClass
    let enqueuedAt: Date
}

/// Who holds the local lock, and who waits for it.
struct LocalLockState: Equatable, Sendable {
    var holder: UUID?
    /// Arrival order. Never sorted in place — ordering is computed at read time, because aging makes
    /// it depend on `now`.
    var queue: [QueuedRun] = []

    var isIdle: Bool { holder == nil && queue.isEmpty }
}

enum LocalInferencePolicy {

    /// Plan §3.4: a run that has waited this long moves up one class, so a busy composer cannot
    /// starve a scheduled task indefinitely.
    static let defaultAgingInterval: TimeInterval = 5 * 60

    // MARK: - Decide

    /// Rules in order (plan §3.3, phase 7). `budgetBytes` is the machine's effective model budget
    /// (0 = unknown: no concern can be raised).
    static func decide(_ manifest: InferenceRunManifest,
                       lock: LocalLockState,
                       budgetBytes: UInt64 = 0,
                       now: Date,
                       agingInterval: TimeInterval = defaultAgingInterval) -> CoordinatorDecision {
        // 1. Cloud-only runs never touch the local lock.
        guard manifest.needsLocalLock else { return .admit(.noLocalModel) }

        // 2. D5 fallback guard.
        if manifest.shape == .delegating { return .deny(.subAgentsUnsupportedLocally) }

        // 3. A concern its user can answer: ask first (phase 7). A run nobody is watching runs.
        let raised = concerns(manifest, budgetBytes: budgetBytes)
        if !raised.isEmpty, asksBeforeRunning(manifest) { return .confirm(raised) }

        // 4. Free.
        if lock.isIdle { return .admit(.lockFree) }

        // 5. Wait, placed by priority.
        let arriving = QueuedRun(runID: manifest.runID, priority: manifest.priority, enqueuedAt: now)
        let ordered = order(lock.queue + [arriving], now: now, agingInterval: agingInterval)
        let position = (ordered.firstIndex { $0.runID == manifest.runID } ?? ordered.count - 1) + 1
        // ⚠️ `holder` can be nil with a non-empty queue for the instant between a release and the next
        // admission; the run is then behind the queue's head, never behind nothing.
        let behind = lock.holder ?? ordered.first { $0.runID != manifest.runID }?.runID ?? manifest.runID
        return .hold(behind: behind, position: position)
    }

    // MARK: - Concerns (phase 7)

    /// What the run's user should be asked about before it starts: each local model whose MEASURED
    /// footprint exceeds the machine's whole model budget. Unknown footprints raise nothing.
    static func concerns(_ manifest: InferenceRunManifest, budgetBytes: UInt64) -> [RunConcern] {
        guard budgetBytes > 0 else { return [] }
        return manifest.localModels.compactMap { model in
            guard let bytes = manifest.footprints[model.residencyKey], bytes > budgetBytes else { return nil }
            return .memory(modelID: model.modelID, estimatedBytes: bytes, budgetBytes: budgetBytes)
        }
    }

    /// Whether a run with concerns is held to ASK its user. Only a run someone is watching, on a
    /// surface that can show the question (owner, 2026-10-08): a scheduled, ChatOps or background run
    /// just runs, and so does an Orb run until the voice HUD can ask (deferred).
    static func asksBeforeRunning(_ manifest: InferenceRunManifest) -> Bool {
        manifest.attended && manifest.origin != .orb
    }

    // MARK: - Queue order

    /// The class a waiting run competes in now: one class higher per full `agingInterval` waited,
    /// never above `.attended` — `.resumedAfterHITL` is reserved for runs that already started.
    static func effectivePriority(_ run: QueuedRun, now: Date, agingInterval: TimeInterval) -> PriorityClass {
        guard agingInterval > 0, run.priority > .attended else { return run.priority }
        let steps = Int(max(0, now.timeIntervalSince(run.enqueuedAt)) / agingInterval)
        let promoted = max(PriorityClass.attended.rawValue, run.priority.rawValue - steps)
        return PriorityClass(rawValue: promoted) ?? run.priority
    }

    /// Highest effective class first; within a class, first come first served.
    static func order(_ queue: [QueuedRun], now: Date, agingInterval: TimeInterval) -> [QueuedRun] {
        queue.enumerated().sorted { lhs, rhs in
            let l = effectivePriority(lhs.element, now: now, agingInterval: agingInterval)
            let r = effectivePriority(rhs.element, now: now, agingInterval: agingInterval)
            if l != r { return l < r }
            if lhs.element.enqueuedAt != rhs.element.enqueuedAt { return lhs.element.enqueuedAt < rhs.element.enqueuedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The run to admit when the lock frees, if any.
    static func next(in queue: [QueuedRun], now: Date, agingInterval: TimeInterval) -> QueuedRun? {
        order(queue, now: now, agingInterval: agingInterval).first
    }
}
