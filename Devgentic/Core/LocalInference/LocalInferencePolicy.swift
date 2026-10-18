// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferencePolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The coordinator's decisions as pure functions over its state, with no side effects and no clock
/// reads (`now` is a parameter). The whole decision table is testable without a run, a model or a main
/// actor.
enum CoordinatorDecision: Equatable, Sendable {
    case admit(AdmitReason)
    /// `behind` is the run holding the lock (or, if none, the head of the queue). `position` is 1-based.
    case hold(behind: UUID, position: Int)
    /// The run raises a concern its user should see first. It is held, keeping its place in line, until
    /// they choose Proceed or Stop. With no answer it is auto-denied after
    /// `LocalInferenceCoordinator.confirmationTimeout`.
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

// Why: a stored-metadata estimate once refused a 3B model as needing ~20 GB; a concern must ask, never
// refuse.
/// Why a run is refused: the sub-agent fallback guard, or a concern the user was asked about and did
/// not answer in time. There is no direct memory-fit deny; a concern asks the user instead.
enum DenyReason: Equatable, Sendable, CustomStringConvertible {
    /// Decision D5 — sub-agents are withdrawn; a local delegating run is the fallback guard's case.
    case subAgentsUnsupportedLocally
    /// The user was asked about `concerns` and chose neither Proceed nor Stop within `after`.
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

    /// A run that has waited this long moves up one class, so a busy composer cannot starve a scheduled
    /// task.
    static let defaultAgingInterval: TimeInterval = 5 * 60

    // MARK: - Decide

    /// Applies the admission rules in order.
    /// `budgetBytes` is the machine's effective model budget (0 means unknown: no concern can be raised).
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
        // `holder` can be nil with a non-empty queue between a release and the next admission; the run is then
        // behind the queue's head.
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

    /// Whether a run with concerns is held to ask its user: only an attended run on a surface that can show
    /// the question. Scheduled, ChatOps and background runs just run, and so does an Orb run until the
    /// voice HUD can ask.
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
