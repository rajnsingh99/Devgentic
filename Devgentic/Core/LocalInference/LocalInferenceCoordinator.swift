// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LocalInferenceCoordinator.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "LocalInferenceCoordinator")

// MARK: - Run scope

/// The run the current task belongs to, so code deep in a provider can say which run touched a model. Bound around
/// the run's Task creation in `ActiveStreamManager.startMessageStream`; unstructured child tasks inherit it, but
/// `Task.detached` does not and reports "outside any run".
enum LocalInferenceScope {
    @TaskLocal static var runID: UUID?

    /// Called by the local providers once per generation request; reads the task-local in the caller's task, not in a
    /// detached or actor-hopped closure. - Parameter contextTokens: the context window the request asks for (Ollama's
    /// `num_ctx`), when known; a change reloads the model in Ollama and is logged.
    static func reportUse(engine: InferenceEngine, modelID: String, contextTokens: Int? = nil) {
        guard engine.isLocal else { return }
        let runID = Self.runID
        Task { @MainActor in
            LocalInferenceCoordinator.shared.noteLocalUse(runID: runID, engine: engine, modelID: modelID,
                                                          contextTokens: contextTokens)
        }
    }

    /// One local generation in flight. `end()` must be called exactly once (a `defer` beside the
    /// `begin`); it is a no-op outside a run.
    struct Generation: Sendable {
        let runID: UUID?
        func end() {
            guard let runID else { return }
            Task { @MainActor in LocalInferenceCoordinator.shared.endLocalGeneration(runID) }
        }
    }

    /// The gate every local generation passes: reports the use, ensures this run holds the local lock (waiting at the
    /// front of the line if it gave it up while parked on a human), and counts the generation in flight until `end()`. -
    /// Throws: `CancellationError` when the wait was cancelled.
    static func beginGeneration(engine: InferenceEngine, modelID: String,
                                contextTokens: Int? = nil) async throws -> Generation {
        reportUse(engine: engine, modelID: modelID, contextTokens: contextTokens)
        guard engine.isLocal, let runID = Self.runID else { return Generation(runID: nil) }
        let model = ModelRequirement(engine: engine, modelID: modelID, role: .primary)
        guard await LocalInferenceCoordinator.shared.beginLocalGeneration(runID, model: model) else { throw CancellationError() }
        return Generation(runID: runID)
    }

    /// Holds a `Generation` begun in one closure and ended in another — the Ollama stream begins in
    /// the transport's `beforeOpen` and ends in its `onClose`. Ends at most once; ending a slot that
    /// never held one (the wait was cancelled) does nothing.
    final class GenerationSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var ending: (@Sendable () -> Void)?
        private var ended = false

        init() {}

        func hold(_ generation: Generation) { hold(ending: { generation.end() }) }

        /// The same, for whatever must run once when the slot ends — `hold(_:)` passes the
        /// generation's `end`; tests pass a counter.
        func hold(ending: @escaping @Sendable () -> Void) {
            let endNow = lock.withLock { () -> Bool in
                if ended { return true }
                self.ending = ending
                return false
            }
            if endNow { ending() }   // the stream closed before the gate let it through
        }

        func end() {
            let held = lock.withLock { () -> (@Sendable () -> Void)? in
                guard !ended else { return nil }
                ended = true
                defer { ending = nil }
                return ending
            }
            held?()
        }
    }
}

// MARK: - Coordinator

/// Why a run did not start. Rendered as the message's error card: `title` over `details`.
struct LocalInferenceRefusal: LocalizedError, Equatable {
    let reason: DenyReason
    /// "Auto-denied" for an unanswered question (phase 7), "Not started" for the D5 guard.
    var title: String { reason.title }
    var details: String {
        switch reason {
        case .subAgentsUnsupportedLocally: return "This run was not started: \(reason.description)."
        case .notConfirmed: return "\(reason.description)."
        }
    }
    /// Title and details in one line — for the workflow run record and the log.
    var errorDescription: String? { "\(title): \(details)" }
}

/// What the coordinator tells a run's surface about its waits — the first one at the send path and any
/// later one after a HITL park (phase 4). Both closures run on the main actor.
struct LocalWaitObserver {
    /// The run starts waiting. `position` is 1-based; `behind` is the holder (or the queue head).
    var onHold: @MainActor (_ position: Int, _ behind: UUID) -> Void = { _, _ in }
    /// The wait ended, admitted or withdrawn.
    var onWaitEnded: @MainActor (_ waited: TimeInterval) -> Void = { _ in }
    /// The run is held until its user chooses Proceed or Stop; with no answer by `deadline` it is auto-denied.
    var onConfirmationNeeded: @MainActor (_ concerns: [RunConcern], _ deadline: Date) -> Void = { _, _ in }
    /// The user chose Proceed. The run now starts, or waits its turn (`onHold` follows).
    var onConfirmed: @MainActor () -> Void = {}
    /// The run's place in line changed while it waits — the line moved, or a run ahead left it.
    var onPositionChanged: @MainActor (_ position: Int, _ holder: UUID?) -> Void = { _, _ in }
}

@MainActor
final class LocalInferenceCoordinator {

    static let shared = LocalInferenceCoordinator()

    enum Mode: String {
        case shadow
        case enforce

        static let defaultsKey = "localInferenceCoordinatorMode"

        // Why: tests share the app's defaults domain, and a run left unfinished would hold the process-wide lock so later local
        // runs hang; enforcement is tested on instances built with `.enforce`.
        /// Enforce mode unless the hidden kill switch says "shadow"; always shadow in the test host.
        static var configured: Mode {
            if TestHost.isRunning { return .shadow }
            if let raw = UserDefaults.standard.string(forKey: defaultsKey), let mode = Mode(rawValue: raw) { return mode }
            return .enforce
        }
    }

    let mode: Mode

    // MARK: The global ceiling

    /// 90 min: above the largest preset (Code, 60 min) plus `ExecutionBudget`'s 60 s reserve, so
    /// nesting never silently shortens a preset — a profile's own limit fires first.
    nonisolated static let defaultGlobalCeiling: TimeInterval = 90 * 60

    /// The maximum COMPUTE time of any one run (Settings → General → Maximum run time). nil = off.
    /// Applied to every run, cloud ones included, by `ActiveStreamManager` at admission.
    nonisolated static var globalCeiling: TimeInterval? {
        ceiling(stored: UserDefaults.standard.object(forKey: AppSettings.maximumRunTimeKey) as? Double)
    }

    /// The ceiling a stored setting means. Pure, for tests (they share the app's defaults domain).
    nonisolated static func ceiling(stored: Double?) -> TimeInterval? {
        guard let stored else { return defaultGlobalCeiling }
        if stored == 0 { return nil }   // "Off" — a choice, not a broken value: no warning per run
        return TimeLimit.usable(stored, "Maximum run time")
    }

    /// How a run's attempt to take the lock ended.
    enum AcquireOutcome: Equatable {
        /// Proceed. `waited` is the time spent in line (0 when it never waited).
        case admitted(waited: TimeInterval)
        case denied(DenyReason)
        /// Withdrawn while waiting — Stop, a deadline, a deleted conversation.
        case cancelled
    }

    private(set) var lock = LocalLockState()

    /// Every registered run, cloud ones included — a cloud run's workflow can still touch a local
    /// classifier, and an undeclared use is only detectable against what was declared.
    private var manifests: [UUID: InferenceRunManifest] = [:]
    private var decisions: [UUID: CoordinatorDecision] = [:]
    private var lockedAt: [UUID: Date] = [:]
    /// De-duplicates the per-generation use reports: each finding is logged once per run and model.
    private var reportedFindings: Set<String> = []
    private var observers: [UUID: LocalWaitObserver] = [:]

    // A run that waits on a human gives the lock up and takes it back at its next generation.
    /// Open HITL parks per run, by operation id.
    private var openParks: [UUID: Set<UUID>] = [:]
    /// Parks whose END was seen before their BEGIN (both arrive as separate main-actor hops).
    private(set) var parksEndedEarly: Set<UUID> = []
    /// Local generations in flight per run. A run is released only when this is zero.
    private var inFlight: [UUID: Int] = [:]
    /// Runs that gave the lock up while parked and have not taken it back.
    private(set) var released: Set<UUID> = []

    // Residency ledger of models loaded.
    /// Ollama models THIS APP has generated with, per server, with the context window last asked for.
    /// The only Ollama models the coordinator ever unloads: another app's models are not ours to evict.
    private(set) var ollamaModelsUsed: [String: [String: Int?]] = [:]
    private let residency: LocalResidencyActions

    /// A run's place in line, one per waiting run; several branches of one run share it, and each branch's continuation
    /// is resumed on its own, so cancelling one never fails another. The outcome is kept once settled so a late branch
    /// reads it instead of waiting forever.
    private final class Waiter {
        enum Outcome { case admitted, withdrawn, autoDenied }
        /// The send-path acquire, as opposed to a phase-4 re-acquire of a run already running.
        let isInitial: Bool
        var continuations: [UUID: CheckedContinuation<Outcome, Never>] = [:]
        var outcome: Outcome?

        init(isInitial: Bool) { self.isInitial = isInitial }

        func settle(_ result: Outcome) {
            guard outcome == nil else { return }
            outcome = result
            let waiting = continuations.values
            continuations = [:]
            waiting.forEach { $0.resume(returning: result) }
        }
    }
    private var waiters: [UUID: Waiter] = [:]

    /// How long a run waits for Proceed before it is auto-denied; a run with a concern waits for its user's answer before
    /// it joins the line.
    nonisolated static let defaultConfirmationTimeout: TimeInterval = 120
    private struct PendingConfirmation {
        /// Its place in line, kept from the moment it arrived: Proceed puts it back at that place.
        let entry: QueuedRun
        let concerns: [RunConcern]
        let deadline: Date
    }
    private var awaitingConfirmation: [UUID: PendingConfirmation] = [:]
    private var confirmationTimers: [UUID: Task<Void, Never>] = [:]
    private let confirmationTimeout: TimeInterval
    /// The last position each waiting run was told, so `onPositionChanged` fires only on a change.
    private var lastPositions: [UUID: Int] = [:]

    /// Runs waiting for their user's answer (phase 7), for tests and the log.
    var runsAwaitingConfirmation: Set<UUID> { Set(awaitingConfirmation.keys) }

    private let now: () -> Date
    private let budgetBytes: () -> UInt64
    private let agingInterval: TimeInterval
    private let beginQueueWait: @Sendable (UUID) async -> Void
    private let endQueueWait: @Sendable (UUID) async -> Void

    init(mode: Mode = .configured,
         now: @escaping () -> Date = Date.init,
         budgetBytes: @escaping () -> UInt64 = { SystemHardwareProfiler.shared.profile.effectiveBudget },
         agingInterval: TimeInterval = LocalInferencePolicy.defaultAgingInterval,
         beginQueueWait: @escaping @Sendable (UUID) async -> Void = { await ExecutionSuspensionService.shared.beginQueueWait($0) },
         endQueueWait: @escaping @Sendable (UUID) async -> Void = { await ExecutionSuspensionService.shared.endQueueWait($0) },
         residency: LocalResidencyActions? = nil,
         confirmationTimeout: TimeInterval = LocalInferenceCoordinator.defaultConfirmationTimeout) {
        self.residency = residency ?? LiveLocalResidency()
        self.confirmationTimeout = confirmationTimeout
        self.mode = mode
        self.now = now
        self.budgetBytes = budgetBytes
        self.agingInterval = agingInterval
        self.beginQueueWait = beginQueueWait
        self.endQueueWait = endQueueWait
    }

    func manifest(for runID: UUID) -> InferenceRunManifest? { manifests[runID] }
    func decision(for runID: UUID) -> CoordinatorDecision? { decisions[runID] }

    /// The run holding the lock, for a waiting run's on-screen and remote notices.
    var holderManifest: InferenceRunManifest? { lock.holder.flatMap { manifests[$0] } }

    private var label: String { mode == .enforce ? "" : "SHADOW " }

    // MARK: Acquire

    /// Takes the local lock for a run that has passed conversation admission, waiting while another local run holds it
    /// (enforce mode); returns at once in shadow mode. Cancelling the calling task withdraws the run and returns
    /// `.cancelled`. `observer` is told when the run waits and when the wait ends.
    func acquire(_ manifest: InferenceRunManifest, observer: LocalWaitObserver = LocalWaitObserver()) async -> AcquireOutcome {
        let decision = register(manifest)
        guard mode == .enforce else { return .admitted(waited: 0) }
        observers[manifest.runID] = observer

        switch decision {
        case .admit:
            return .admitted(waited: 0)
        case .deny(let reason):
            return .denied(reason)
        case .hold(let behind, let position):
            let waiter = Waiter(isInitial: true)
            waiters[manifest.runID] = waiter
            lastPositions[manifest.runID] = position
            observer.onHold(position, behind)
            return await finishWaiting(manifest.runID, on: waiter, concerns: [])
        case .confirm(let concerns):
            let waiter = Waiter(isInitial: true)
            waiters[manifest.runID] = waiter
            let deadline = awaitingConfirmation[manifest.runID]?.deadline ?? now().addingTimeInterval(confirmationTimeout)
            observer.onConfirmationNeeded(concerns, deadline)
            let runID = manifest.runID
            let timeout = confirmationTimeout
            confirmationTimers[runID] = Task { @MainActor [weak self] in
                guard (try? await Task.sleep(for: .seconds(timeout))) != nil else { return }
                self?.expireConfirmation(runID)
            }
            return await finishWaiting(manifest.runID, on: waiter, concerns: concerns)
        }
    }

    /// The common end of every initial wait — in line, or for its user's answer first.
    private func finishWaiting(_ runID: UUID, on waiter: Waiter, concerns: [RunConcern]) async -> AcquireOutcome {
        let (outcome, waited) = await wait(on: waiter, runID: runID)
        observers[runID]?.onWaitEnded(waited)
        switch outcome {
        case .admitted:
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) admitted after waiting \(Int(waited))s\(concerns.isEmpty ? " for the local lock" : " (its user chose Proceed)").")
            return .admitted(waited: waited)
        case .withdrawn:
            return .cancelled
        case .autoDenied:
            return .denied(.notConfirmed(concerns: concerns, after: confirmationTimeout))
        }
    }

    // MARK: The user's answer

    /// The user chose Proceed for a run waiting on a concern: it starts now if the lock is free, or takes the place it
    /// held since it arrived. - Returns: false when the run was not waiting for an answer (already started, stopped or
    /// auto-denied).
    @discardableResult
    func proceed(runID: UUID) -> Bool {
        guard mode == .enforce, let pending = awaitingConfirmation.removeValue(forKey: runID) else {
            logger.info("[LOCAL-COORD] Proceed for run \(runID.uuidString.prefix(8)) ignored — it is not waiting for an answer (it already started, was stopped, or was auto-denied). CONSEQUENCE: nothing changes.")
            return false
        }
        confirmationTimers.removeValue(forKey: runID)?.cancel()
        let asked = Int(now().timeIntervalSince(pending.entry.enqueuedAt))
        observers[runID]?.onConfirmed()
        if lock.isIdle {
            lock.holder = runID
            lockedAt[runID] = now()
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): its user chose PROCEED after \(asked)s — the local lock is free, so it starts now. CONSEQUENCE: \(pending.concerns.map(\.description).joined(separator: "; ")) — it may run slowly or fail.")
            didTakeLock(runID)
            waiters[runID]?.settle(.admitted)
            return true
        }
        lock.queue.append(pending.entry)
        let ordered = LocalInferencePolicy.order(lock.queue, now: now(), agingInterval: agingInterval)
        let position = (ordered.firstIndex { $0.runID == runID } ?? 0) + 1
        let behind = lock.holder ?? ordered.first?.runID ?? runID
        logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): its user chose PROCEED after \(asked)s — it takes its place in line at position \(position), behind \(self.describe(behind)). CONSEQUENCE: it starts by itself when the lock passes to it.")
        lastPositions[runID] = position
        observers[runID]?.onHold(position, behind)
        publishPositions()
        return true
    }

    /// Nobody answered in time: the run is auto-denied and never started.
    private func expireConfirmation(_ runID: UUID) {
        confirmationTimers.removeValue(forKey: runID)
        guard let pending = awaitingConfirmation.removeValue(forKey: runID) else { return }
        logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) AUTO-DENIED — no answer within \(Int(self.confirmationTimeout))s: \(pending.concerns.map(\.description).joined(separator: "; ")). CONSEQUENCE: the run is not started; its message says why.")
        waiters.removeValue(forKey: runID)?.settle(.autoDenied)
    }

    /// Tells every waiting run whose place in line changed. Called after anything that moves the line.
    private func publishPositions() {
        guard mode == .enforce else { return }
        let ordered = LocalInferencePolicy.order(lock.queue, now: now(), agingInterval: agingInterval)
        for (index, run) in ordered.enumerated() where lastPositions[run.runID] != index + 1 {
            lastPositions[run.runID] = index + 1
            logger.debug("[LOCAL-COORD] Run \(run.runID.uuidString.prefix(8)) is now number \(index + 1) in line (holder \(self.lock.holder.map { String($0.uuidString.prefix(8)) } ?? "none")).")
            observers[run.runID]?.onPositionChanged(index + 1, lock.holder)
        }
        let waiting = Set(ordered.map(\.runID))
        lastPositions = lastPositions.filter { waiting.contains($0.key) }
    }

    /// Suspends one branch on `waiter` until it settles or this branch is cancelled. Credits the wait
    /// to the branch's own time bounds.
    private func wait(on waiter: Waiter, runID: UUID) async -> (Waiter.Outcome, TimeInterval) {
        let started = now()
        let creditID = UUID()
        let token = UUID()
        await beginQueueWait(creditID)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Waiter.Outcome, Never>) in
                if let settled = waiter.outcome {
                    continuation.resume(returning: settled)
                } else if Task.isCancelled {
                    // Cancelled before suspending: the handler's hop may already have run and found
                    // nothing to withdraw. Withdraw here instead.
                    continuation.resume(returning: .withdrawn)
                    self.withdrawBranch(runID: runID, token: nil, waiter: waiter)
                } else {
                    waiter.continuations[token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdraw(runID: runID, token: token) }
        }
        await endQueueWait(creditID)
        if waiters[runID] === waiter, waiter.outcome != nil, waiter.continuations.isEmpty {
            waiters.removeValue(forKey: runID)
        }
        return (outcome, now().timeIntervalSince(started))
    }

    /// Removes a WAITING run from the line without admitting it — every branch of it. A no-op for a run
    /// that is not waiting, including one the lock already passed to (it proceeds and releases on its
    /// own end).
    func withdraw(runID: UUID) {
        guard let waiter = waiters[runID], lock.holder != runID else { return }
        removeFromLine(runID, waiter: waiter)
    }

    /// One cancelled branch leaves; the run stays in line while another branch still waits.
    private func withdraw(runID: UUID, token: UUID) {
        guard let waiter = waiters[runID], lock.holder != runID else {
            logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): a waiting branch was cancelled after the run \(self.lock.holder == runID ? "was given the lock" : "left the line"). CONSEQUENCE: nothing to withdraw; that branch stops at its own next cancellation check.")
            return
        }
        withdrawBranch(runID: runID, token: token, waiter: waiter)
    }

    private func withdrawBranch(runID: UUID, token: UUID?, waiter: Waiter) {
        if let token, let continuation = waiter.continuations.removeValue(forKey: token) {
            continuation.resume(returning: .withdrawn)
        }
        guard waiter.continuations.isEmpty, waiter.outcome == nil, waiters[runID] === waiter,
              lock.holder != runID else {
            if !waiter.continuations.isEmpty {
                logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): one waiting branch was cancelled; \(waiter.continuations.count) other branch(es) still wait. CONSEQUENCE: the run keeps its place in line.")
            }
            return
        }
        removeFromLine(runID, waiter: waiter)
    }

    private func removeFromLine(_ runID: UUID, waiter: Waiter) {
        let entry = lock.queue.first { $0.runID == runID } ?? awaitingConfirmation[runID]?.entry
        let waited = entry.map { now().timeIntervalSince($0.enqueuedAt) } ?? 0
        lock.queue.removeAll { $0.runID == runID }
        if awaitingConfirmation.removeValue(forKey: runID) != nil {
            confirmationTimers.removeValue(forKey: runID)?.cancel()
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) was STOPPED while its user was being asked to proceed (\(Int(waited))s). CONSEQUENCE: it never starts.")
        }
        waiters.removeValue(forKey: runID)
        if waiter.isInitial {
            // It never started: forget it entirely. A re-acquiring run is still running and still
            // registered; its own end unregisters it.
            manifests.removeValue(forKey: runID)
            decisions.removeValue(forKey: runID)
        }
        waiter.settle(.withdrawn)
        publishPositions()
        logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) withdrawn from the local queue after \(Int(waited))s (cancelled while waiting\(waiter.isInitial ? "" : " to take the lock back")). CONSEQUENCE: \(waiter.isInitial ? "it never started" : "its next local generation does not run"); \(self.lock.queue.count) run(s) still waiting.")
    }

    // MARK: Release while parked, take back at the next generation

    /// A HITL park opened in `runID` (from `ExecutionSuspensionService`).
    func parkBegan(runID: UUID, operationID: UUID) {
        guard mode == .enforce else { return }
        if parksEndedEarly.remove(operationID) != nil {
            logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): park \(operationID.uuidString.prefix(8)) began after its end was already seen. CONSEQUENCE: nothing to do — it is over.")
            return
        }
        guard manifests[runID] != nil else {
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) parked on a human (op \(operationID.uuidString.prefix(8))) but is not registered with the coordinator (it ended, or its task outlived it). CONSEQUENCE: no local lock to give up for this park.")
            return
        }
        openParks[runID, default: []].insert(operationID)
        logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) is waiting on a human (op \(operationID.uuidString.prefix(8)); \(self.openParks[runID]?.count ?? 0) open park(s)).")
        releaseIfParked(runID)
    }

    // Why: do not take the lock back here: the run takes it at its next local generation through `beginLocalGeneration`,
    // otherwise the answer itself would wait for another run to finish.
    /// A HITL park in `runID` closed (answered, cancelled or drained).
    func parkEnded(runID: UUID, operationID: UUID) {
        guard mode == .enforce else { return }
        guard openParks[runID]?.remove(operationID) != nil else {
            // Only for a run still registered: `parkBegan` ignores any other, so an entry kept for one would never be claimed.
            if manifests[runID] != nil {
                parksEndedEarly.insert(operationID)
                logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): park \(operationID.uuidString.prefix(8)) ended before its begin arrived. CONSEQUENCE: its begin will be ignored, so the lock is not given up for a wait that is already over.")
            } else {
                logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): park \(operationID.uuidString.prefix(8)) ended for a run no longer registered. CONSEQUENCE: nothing to do.")
            }
            return
        }
        if openParks[runID]?.isEmpty == true { openParks.removeValue(forKey: runID) }
        let stillOpen = openParks[runID]?.count ?? 0
        logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): human wait (op \(operationID.uuidString.prefix(8))) is over; \(stillOpen) still open. CONSEQUENCE: \(self.released.contains(runID) ? "the run gave the local lock up while it waited, and takes it back at its next local generation — waiting at the front of the line if another run holds it now" : "the run still holds the local lock; nothing changes").")
    }

    /// Before a local generation: ensures the run holds the lock, then counts the generation. - Returns: false when the
    /// wait for the lock was cancelled. - Parameter model: the model the generation uses, declared into the run's
    /// manifest when missing so a lock handover keeps it loaded.
    func beginLocalGeneration(_ runID: UUID, model: ModelRequirement? = nil) async -> Bool {
        guard await ensureHeld(runID, model: model) else { return false }
        if mode == .enforce, manifests[runID] != nil { inFlight[runID, default: 0] += 1 }
        return true
    }

    func endLocalGeneration(_ runID: UUID) {
        guard let count = inFlight[runID] else {
            if mode == .enforce, manifests[runID] != nil {
                logger.error("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)): a local generation ended that was never counted as started. CONSEQUENCE: ignored; a provider's begin/end pairing is broken, so a park could release the lock while a generation is still running.")
            }
            return
        }
        if count <= 1 { inFlight.removeValue(forKey: runID) } else { inFlight[runID] = count - 1 }
        releaseIfParked(runID)
    }

    /// Makes `runID` the holder, waiting at the front of the line when it gave the lock up while parked; also takes the
    /// lock for a run using a local model its manifest did not declare. - Returns: false when the wait was cancelled.
    func ensureHeld(_ runID: UUID, model: ModelRequirement? = nil) async -> Bool {
        guard mode == .enforce, var manifest = manifests[runID] else { return true }
        // Before the lock is taken: `didTakeLock` keeps only the manifest's models, so an undeclared model would be unloaded
        // at the handover that admits its run.
        if let model, model.engine.isLocal,
           !manifest.models.contains(where: { $0.residencyKey == model.residencyKey }) {
            manifest = manifest.declaring(model)
            manifests[runID] = manifest
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) uses \(model.residencyKey), which its manifest did not declare — declared now. CONSEQUENCE: lock handovers keep it loaded and deleting it is refused while the run lives; the manifest derivation should list it (see the UNDECLARED line).")
        }
        if lock.holder == runID { return true }

        let resuming = released.contains(runID)
        if !resuming {
            logger.warning("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) (\(manifest.origin)) is generating locally without holding the local lock — its manifest declared no local model. Taking the lock now. CONSEQUENCE: the run may wait here for another local run; fix the manifest derivation so it waits at the start instead.")
        }
        if lock.isIdle {
            take(runID, at: now(), why: resuming ? "after a human answered" : "for an undeclared local use")
            return true
        }

        let waiter: Waiter
        if let existing = waiters[runID] {
            waiter = existing   // another branch of this run is already in line: wait with it
        } else {
            waiter = Waiter(isInitial: false)
            waiters[runID] = waiter
            let priority: PriorityClass = resuming ? .resumedAfterHITL : manifest.priority
            lock.queue.append(QueuedRun(runID: runID, priority: priority, enqueuedAt: now()))
            let ordered = LocalInferencePolicy.order(lock.queue, now: now(), agingInterval: agingInterval)
            let position = (ordered.firstIndex { $0.runID == runID } ?? 0) + 1
            let behind = lock.holder ?? ordered.first?.runID ?? runID
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) needs the local model again\(resuming ? " after a human answered" : "") — waiting at position \(position) (\(priority)) behind \(self.describe(behind)). CONSEQUENCE: it continues by itself when the lock passes to it; the holder is never interrupted.")
            lastPositions[runID] = position
            observers[runID]?.onHold(position, behind)
            publishPositions()
        }
        let (outcome, waited) = await wait(on: waiter, runID: runID)
        observers[runID]?.onWaitEnded(waited)
        guard outcome == .admitted else {
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) stopped waiting to \(resuming ? "take the local lock back" : "take the local lock") after \(Int(waited))s — cancelled. CONSEQUENCE: its local generation is not started; the provider throws CancellationError and the run ends as cancelled.")
            return false
        }
        // Re-checks the holder after the last suspension: `.admitted` can be stale if another branch of the same run parked
        // in the gap and released the lock. If it moved on, wait again.
        guard lock.holder == runID else {
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) was admitted, but the local lock passed to \(self.lock.holder.map { String($0.uuidString.prefix(8)) } ?? "nobody") before this branch could start (another branch of the run parked on a human). CONSEQUENCE: this branch waits for the lock again instead of generating without it.")
            return await ensureHeld(runID, model: model)
        }
        logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) \(resuming ? "took the local lock back" : "took the local lock") after waiting \(Int(waited))s. CONSEQUENCE: its local generation starts now.")
        released.remove(runID)
        return true
    }

    private func take(_ runID: UUID, at: Date, why: String) {
        lock.holder = runID
        lockedAt[runID] = at
        released.remove(runID)
        logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) took the local lock \(why) — it was free, no wait.")
        didTakeLock(runID)
    }

    /// Gives the lock up for a run that is waiting on a human and generating nothing.
    private func releaseIfParked(_ runID: UUID) {
        guard mode == .enforce, lock.holder == runID, !(openParks[runID]?.isEmpty ?? true) else { return }
        if let generating = inFlight[runID], generating > 0 {
            logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) is waiting on a human, but \(generating) local generation(s) of it are still running. CONSEQUENCE: it keeps the local lock until they end.")
            return
        }
        released.insert(runID)
        let next = passLock(from: runID, why: "is waiting for a human")
        if next == nil {
            logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) is waiting for a human — local lock released; nothing waiting. CONSEQUENCE: it takes the lock back at its next local generation.")
        }
    }

    // MARK: Register

    /// Records a run that has passed conversation admission and decides what the lock does with it.
    /// `acquire` is the caller-facing entry point; this is the decision alone.
    @discardableResult
    func register(_ manifest: InferenceRunManifest) -> CoordinatorDecision {
        if let existing = decisions[manifest.runID] {
            logger.notice("[LOCAL-COORD] Run \(manifest.runID.uuidString.prefix(8)) registered twice — keeping its first decision. CONSEQUENCE: none; a second registration would otherwise queue the run behind itself.")
            return existing
        }
        let at = now()
        let budget = budgetBytes()
        var decision = LocalInferencePolicy.decide(manifest, lock: lock, budgetBytes: budget, now: at, agingInterval: agingInterval)
        if case .confirm(let concerns) = decision, mode != .enforce {
            logger.notice("[LOCAL-COORD] SHADOW would ASK before running — \(manifest.summary): \(concerns.map(\.description).joined(separator: "; ")). CONSEQUENCE: under enforcement its user would choose Proceed or Stop (auto-denied after \(Int(self.confirmationTimeout))s); in shadow mode it runs.")
            decision = LocalInferencePolicy.decide(manifest, lock: lock, now: at, agingInterval: agingInterval)
        } else if case .confirm = decision {
            // Asked about below.
        } else if manifest.needsLocalLock, manifest.shape != .delegating {
            // A concern nobody is asked about (an unattended or Orb run) — it runs, and the log says why.
            for concern in LocalInferencePolicy.concerns(manifest, budgetBytes: budget) {
                logger.warning("[LOCAL-COORD] Run \(manifest.runID.uuidString.prefix(8)) (\(manifest.origin), \(manifest.attended ? "attended" : "unattended")): \(concern.description). CONSEQUENCE: it runs WITHOUT asking — \(manifest.attended ? "this surface cannot show the question yet" : "nobody is watching to answer") — and may run slowly or fail.")
            }
        }
        manifests[manifest.runID] = manifest
        decisions[manifest.runID] = decision

        switch decision {
        case .confirm(let concerns):
            awaitingConfirmation[manifest.runID] = PendingConfirmation(
                entry: QueuedRun(runID: manifest.runID, priority: manifest.priority, enqueuedAt: at),
                concerns: concerns, deadline: at.addingTimeInterval(confirmationTimeout))
            logger.notice("[LOCAL-COORD] ASK — \(manifest.summary): \(concerns.map(\.description).joined(separator: "; ")). CONSEQUENCE: the run is HELD until its user chooses Proceed (it then waits its turn) or Stop; with no answer in \(Int(self.confirmationTimeout))s it is auto-denied. It blocks no other run meanwhile.")
        case .admit(.noLocalModel):
            logger.info("[LOCAL-COORD] \(self.label)admit (cloud-only) — \(manifest.summary). CONSEQUENCE: none; cloud runs never take the local lock.")
        case .admit(.lockFree):
            lock.holder = manifest.runID
            lockedAt[manifest.runID] = at
            logger.notice("[LOCAL-COORD] \(self.label)admit — \(manifest.summary) now HOLDS the local lock.")
            didTakeLock(manifest.runID)
        case .hold(let behind, let position):
            lock.queue.append(QueuedRun(runID: manifest.runID, priority: manifest.priority, enqueuedAt: at))
            if mode == .enforce {
                logger.notice("[LOCAL-COORD] HOLD — \(manifest.summary), position \(position), behind \(self.describe(behind)). CONSEQUENCE: this run WAITS and starts by itself when the local lock passes to it; Stop withdraws it.")
                // A higher-priority arrival moves the runs behind it back a place.
                lastPositions[manifest.runID] = position
                publishPositions()
            } else {
                logger.notice("[LOCAL-COORD] SHADOW would HOLD — \(manifest.summary), position \(position), behind \(self.describe(behind)). CONSEQUENCE: under enforcement this run would wait; in shadow mode it runs NOW, concurrently with the holder.")
            }
        case .deny(let reason):
            if mode == .enforce {
                logger.warning("[LOCAL-COORD] DENY — \(manifest.summary): \(reason.description). CONSEQUENCE: the run is not started; its message shows this reason.")
            } else {
                logger.warning("[LOCAL-COORD] SHADOW would DENY — \(manifest.summary): \(reason.description). CONSEQUENCE: under enforcement this run would be refused with that reason; in shadow mode it runs.")
            }
        }
        return decision
    }

    // MARK: Unregister

    /// The run has ended (finished, failed or cancelled). Idempotent.
    /// - Returns: the run the lock passes to, if any.
    @discardableResult
    func unregister(runID: UUID) -> UUID? {
        defer {
            manifests.removeValue(forKey: runID)
            decisions.removeValue(forKey: runID)
            lockedAt.removeValue(forKey: runID)
            observers.removeValue(forKey: runID)
            openParks.removeValue(forKey: runID)
            inFlight.removeValue(forKey: runID)
            released.remove(runID)
            lastPositions.removeValue(forKey: runID)
            reportedFindings = reportedFindings.filter { !$0.hasPrefix(runID.uuidString) }
        }
        let at = now()

        if awaitingConfirmation.removeValue(forKey: runID) != nil {
            confirmationTimers.removeValue(forKey: runID)?.cancel()
            logger.error("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) ended while its user was still being asked to proceed. CONSEQUENCE: the question is withdrawn; a run should end only after Proceed, Stop or the auto-deny.")
            waiters.removeValue(forKey: runID)?.settle(.withdrawn)
        }

        if lock.holder == runID {
            return passLock(from: runID, why: "ended")
        }

        if released.contains(runID) {
            logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) ended while it had given the local lock up (it was waiting on a human). CONSEQUENCE: nothing to release.")
        } else if manifests[runID].map({ !$0.needsLocalLock }) == true {
            logger.debug("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) ended (cloud-only — it never held the local lock).")
        }

        if let queued = lock.queue.first(where: { $0.runID == runID }) {
            lock.queue.removeAll { $0.runID == runID }
            if mode == .enforce {
                // A waiting run ends only by being withdrawn first, which already removed it.
                logger.error("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) ended while still queued (\(Int(at.timeIntervalSince(queued.enqueuedAt)))s in line). CONSEQUENCE: removed from the line now; a run must not end while its acquire is still waiting.")
                waiters.removeValue(forKey: runID)?.settle(.withdrawn)
                publishPositions()
            } else {
                logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) ended while it would still have been WAITING (\(Int(at.timeIntervalSince(queued.enqueuedAt)))s in line, holder \(self.lock.holder.map { String($0.uuidString.prefix(8)) } ?? "none")). CONSEQUENCE: under enforcement it would not have started yet — its whole run overlapped the holder's.")
            }
        }
        return nil
    }

    /// Hands the lock from its holder to the next run in line, waking it. Returns that run.
    private func passLock(from runID: UUID, why: String) -> UUID? {
        let at = now()
        let held = lockedAt[runID].map { at.timeIntervalSince($0) } ?? 0
        lock.holder = nil
        lockedAt.removeValue(forKey: runID)
        guard let next = LocalInferencePolicy.next(in: lock.queue, now: at, agingInterval: agingInterval) else {
            if why == "ended" {
                logger.info("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) released the local lock after \(Int(held))s; nothing waiting.")
            }
            return nil
        }
        lock.queue.removeAll { $0.runID == next.runID }
        lock.holder = next.runID
        lockedAt[next.runID] = at
        didTakeLock(next.runID)
        if mode == .enforce {
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) \(why) — released the local lock after \(Int(held))s → admits \(self.describe(next.runID)), which waited \(Int(at.timeIntervalSince(next.enqueuedAt)))s.")
            lastPositions.removeValue(forKey: next.runID)
            publishPositions()
            if let waiter = waiters[next.runID] {
                waiter.settle(.admitted)
            } else {
                logger.error("[LOCAL-COORD] Run \(next.runID.uuidString.prefix(8)) was given the local lock but has no waiter. CONSEQUENCE: it holds the lock without running until its run ends; every other local run waits behind it. A queued run must always wait through `acquire`.")
            }
        } else {
            logger.notice("[LOCAL-COORD] Run \(runID.uuidString.prefix(8)) released the local lock after \(Int(held))s → SHADOW admits \(self.describe(next.runID)), which waited \(Int(at.timeIntervalSince(next.enqueuedAt)))s. CONSEQUENCE: under enforcement that run would start only now.")
        }
        return next.runID
    }

    // MARK: Residency

    /// A local run has just taken the lock: unloads the local models it does not use. This is the only moment residency
    /// changes, besides the engines' idle timers and quit. Skipped when the manifest has unresolved nodes, since an
    /// unknown need never evicts.
    private func didTakeLock(_ runID: UUID) {
        guard mode == .enforce else { return }
        guard let manifest = manifests[runID] else {
            logger.error("[LOCAL-RESIDENCY] Run \(runID.uuidString.prefix(8)) took the local lock with no manifest. CONSEQUENCE: nothing is unloaded; a holder must always be registered.")
            return
        }
        guard manifest.unresolvedNodes == 0 else {
            logger.notice("[LOCAL-RESIDENCY] Run \(runID.uuidString.prefix(8)) took the local lock, but \(manifest.unresolvedNodes) of its node(s) could not be resolved. CONSEQUENCE: nothing is unloaded — the run may need any resident model.")
            return
        }
        let mlxKeep = manifest.localModels.filter { $0.engine == .mlx }.map(\.modelID)
        var ollamaEvict: [(model: String, baseURL: String)] = []
        for (baseURL, models) in ollamaModelsUsed {
            let keep = Set(manifest.localModels.filter { $0.engine == .ollama(baseURL: baseURL) }.map(\.modelID))
            for model in models.keys where !keep.contains(model) {
                ollamaEvict.append((model, baseURL))
                ollamaModelsUsed[baseURL]?.removeValue(forKey: model)
            }
            if ollamaModelsUsed[baseURL]?.isEmpty == true { ollamaModelsUsed.removeValue(forKey: baseURL) }
        }
        let reason = "run \(runID.uuidString.prefix(8)) took the local lock"
        logger.info("[LOCAL-RESIDENCY] Run \(runID.uuidString.prefix(8)) took the local lock — MLX keep [\(mlxKeep.joined(separator: ", "))] (anything else resident is unloaded); Ollama unload [\(ollamaEvict.map { "\($0.model)@\($0.baseURL)" }.joined(separator: ", "))].")
        let residency = self.residency
        Task { @MainActor in
            await residency.unloadMLX(unlessResidentIn: mlxKeep, reason: reason)
            for entry in ollamaEvict { await residency.unloadOllama(model: entry.model, baseURL: entry.baseURL, reason: reason) }
        }
    }

    /// Unloads every Ollama model this app used — and only those. For quit: the server may be serving
    /// other apps, whose models are not ours to evict (U10).
    func unloadOllamaModelsWeUsed() async {
        let used = ollamaModelsUsed
        ollamaModelsUsed = [:]
        let count = used.values.reduce(0) { $0 + $1.count }
        logger.notice("[LOCAL-RESIDENCY] Quit: unloading the \(count) Ollama model(s) this app used\(count == 0 ? "" : " — " + used.flatMap { url, models in models.keys.map { "\($0)@\(url)" } }.joined(separator: ", ")). CONSEQUENCE: models other apps loaded on the same server stay loaded.")
        for (baseURL, models) in used {
            for model in models.keys { await residency.unloadOllama(model: model, baseURL: baseURL, reason: "quit") }
        }
    }

    /// The model ids of `engine` that a run still registered — holding, waiting, or parked — expects to
    /// use. A model in this list must not be deleted from disk (U12).
    func modelsInUse(on engine: InferenceEngine) -> [String] {
        manifests.values.flatMap { $0.models.filter { $0.engine == engine }.map(\.modelID) }
    }

    // MARK: Background Core Intelligence (decision D7)

    /// Runs a background Core Intelligence feature (Briefing, User Personal) as a lowest-priority local run that
    /// waits for and holds the lock. Throws `CancellationError` when withdrawn while waiting, `LocalInferenceRefusal`
    /// when denied. `modelName` nil reads the user's setting.
    func runBackgroundIntelligence<T>(feature: String, modelName: String? = nil,
                                      operation: () async throws -> T) async throws -> T {
        let modelName = (modelName ?? UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = InferenceRunManifest(
            runID: UUID(), conversationID: nil, origin: .intelligence(feature), attended: false, shape: .single,
            models: modelName.isEmpty ? [] : [ModelRequirement(engine: .mlx, modelID: modelName, role: .intelligenceCore)],
            unresolvedNodes: 0, footprints: [:])
        let run = manifest.runID.uuidString.prefix(8)
        if modelName.isEmpty {
            logger.notice("[LOCAL-COORD] \(feature) (run \(run)): no Core Intelligence model is selected, so it declares no local model and takes no lock. CONSEQUENCE: Core Intelligence refuses to load without a model, so nothing runs outside the lock.")
        }
        switch await acquire(manifest) {
        case .admitted(let waited):
            logger.info("[LOCAL-COORD] \(feature) (run \(run), background) starts\(waited > 0 ? " after waiting \(Int(waited))s for the local lock" : ""), on '\(modelName)'.")
        case .cancelled:
            logger.notice("[LOCAL-COORD] \(feature) (run \(run)) was cancelled while waiting for the local lock. CONSEQUENCE: it does not run this time.")
            throw CancellationError()
        case .denied(let reason):
            logger.warning("[LOCAL-COORD] \(feature) (run \(run)) refused: \(reason.description). CONSEQUENCE: it does not run.")
            throw LocalInferenceRefusal(reason: reason)
        }
        let started = now()
        defer { unregister(runID: manifest.runID) }
        do {
            let result = try await operation()
            logger.info("[LOCAL-COORD] \(feature) (run \(run)) finished in \(Int(self.now().timeIntervalSince(started)))s. CONSEQUENCE: the local lock passes to the next run.")
            return result
        } catch {
            logger.warning("[LOCAL-COORD] \(feature) (run \(run)) failed after \(Int(self.now().timeIntervalSince(started)))s: \(error.localizedDescription). CONSEQUENCE: the local lock passes to the next run; the feature reports its own failure.")
            throw error
        }
    }

    // MARK: Core Intelligence INSIDE a turn (query rewrite, response synthesis)

    /// What an in-turn Core Intelligence call was given, so the release undoes exactly that.
    enum InTurnIntelligenceSlot: Equatable {
        /// The turn's own run holds the local lock; the call is part of it.
        case ownRun
        /// Nothing to coordinate: shadow mode, or no Core Intelligence model selected.
        case uncoordinated
        /// The lock was free; the call holds it as a run of its own until it ends.
        case claimed(UUID)
    }

    /// The local lock was busy, so an in-turn Core Intelligence step was SKIPPED (never queued).
    struct LocalSlotBusy: LocalizedError, Equatable {
        let feature: String
        let holder: String
        var errorDescription: String? { "\(feature) skipped: the local model is busy (\(holder))." }
    }

    /// Claims the local lock for an in-turn Core Intelligence call, or refuses at once. A busy slot skips the step
    /// instead of queueing, since the call sits in front of the user's answer; each caller has a fallback. - Parameter
    /// callerRunID: `LocalInferenceScope.runID` read in the caller's task.
    func claimForInTurnIntelligence(feature: String, callerRunID: UUID?) throws -> InTurnIntelligenceSlot {
        let modelName = (UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .enforce else {
            logger.debug("[LOCAL-COORD] SHADOW: in-turn \(feature) runs without claiming the local lock.")
            return .uncoordinated
        }
        guard !modelName.isEmpty else { return .uncoordinated }
        if let callerRunID, lock.holder == callerRunID {
            logger.info("[LOCAL-COORD] In-turn \(feature) runs inside run \(callerRunID.uuidString.prefix(8)), which holds the local lock. CONSEQUENCE: none; it is part of that run.")
            return .ownRun
        }
        if let holder = lock.holder {
            logger.notice("[LOCAL-COORD] In-turn \(feature) SKIPPED — the local lock is held by \(self.describe(holder)). CONSEQUENCE: the turn uses its fallback instead of waiting behind another run, or generating on '\(modelName)' alongside it.")
            inTurnIntelligenceSkips += 1
            throw LocalSlotBusy(feature: feature, holder: describe(holder))
        }
        if !lock.queue.isEmpty {
            logger.notice("[LOCAL-COORD] In-turn \(feature) SKIPPED — \(self.lock.queue.count) local run(s) are waiting for the lock. CONSEQUENCE: the turn uses its fallback; it does not jump the line.")
            inTurnIntelligenceSkips += 1
            throw LocalSlotBusy(feature: feature, holder: "\(lock.queue.count) waiting run(s)")
        }
        let manifest = InferenceRunManifest(
            runID: UUID(), conversationID: nil, origin: .intelligence(feature), attended: false, shape: .single,
            models: [ModelRequirement(engine: .mlx, modelID: modelName, role: .intelligenceCore)],
            unresolvedNodes: 0, footprints: [:])
        guard case .admit(.lockFree) = register(manifest) else {
            unregister(runID: manifest.runID)
            logger.notice("[LOCAL-COORD] In-turn \(feature) SKIPPED — the coordinator did not grant the free lock. CONSEQUENCE: the turn uses its fallback.")
            inTurnIntelligenceSkips += 1
            throw LocalSlotBusy(feature: feature, holder: "not granted")
        }
        inTurnIntelligenceClaims += 1
        return .claimed(manifest.runID)
    }

    /// How many in-turn Core Intelligence calls claimed the free lock, and how many were skipped
    /// because it was busy. Observability for tests and the log; nothing decides on them.
    private(set) var inTurnIntelligenceClaims = 0
    private(set) var inTurnIntelligenceSkips = 0

    /// Ends what `claimForInTurnIntelligence` began. Idempotent per slot.
    func releaseInTurnIntelligence(_ slot: InTurnIntelligenceSlot) {
        guard case .claimed(let runID) = slot else { return }
        unregister(runID: runID)
    }

    /// Runs one in-turn Core Intelligence generation under the local lock rules above. Throws
    /// `LocalSlotBusy` (WITHOUT running `operation`) when another run holds the lock.
    nonisolated static func inTurnIntelligence<T>(
        feature: String, on coordinator: LocalInferenceCoordinator,
        operation: () async throws -> T
    ) async throws -> T {
        let callerRunID = LocalInferenceScope.runID   // read here, in the caller's task
        let slot = try await coordinator.claimForInTurnIntelligence(feature: feature, callerRunID: callerRunID)
        do {
            let result = try await operation()
            await coordinator.releaseInTurnIntelligence(slot)
            return result
        } catch {
            await coordinator.releaseInTurnIntelligence(slot)
            throw error
        }
    }

    // MARK: Background work on a conversation's own model

    /// Runs background generation on `config`'s model (compaction, project-memory suggestions) as a lowest-priority run
    /// that waits for and holds the lock. The work runs with `LocalInferenceScope.runID` set to this run; a cloud model
    /// takes no lock but the stale id is still cleared.
    func runBackgroundLocal<T>(feature: String, conversationID: UUID?, config: ProviderConfig,
                               operation: () async throws -> T) async throws -> T {
        let engine = InferenceEngine.of(config)
        guard engine.isLocal else {
            return try await LocalInferenceScope.$runID.withValue(nil) { try await operation() }
        }
        let manifest = InferenceRunManifest(
            runID: UUID(), conversationID: conversationID, origin: .intelligence(feature), attended: false, shape: .single,
            models: [ModelRequirement(engine: engine, modelID: config.modelName, role: .primary)],
            unresolvedNodes: 0, footprints: [:])
        let run = manifest.runID.uuidString.prefix(8)
        switch await acquire(manifest) {
        case .admitted(let waited):
            logger.info("[LOCAL-COORD] \(feature) (run \(run), background) starts\(waited > 0 ? " after waiting \(Int(waited))s for the local lock" : ""), on '\(config.modelName)'.")
        case .cancelled:
            logger.notice("[LOCAL-COORD] \(feature) (run \(run)) was cancelled while waiting for the local lock. CONSEQUENCE: it does not run this time.")
            throw CancellationError()
        case .denied(let reason):
            logger.warning("[LOCAL-COORD] \(feature) (run \(run)) refused: \(reason.description). CONSEQUENCE: it does not run.")
            throw LocalInferenceRefusal(reason: reason)
        }
        defer { unregister(runID: manifest.runID) }
        return try await LocalInferenceScope.$runID.withValue(manifest.runID) { try await operation() }
    }

    // MARK: Use reports

    /// What a use report revealed. Returned (newly reported ones only) so tests can see the evidence
    /// without scraping logs.
    enum UseFinding: Equatable {
        case outsideAnyRun
        case unregisteredRun
        case undeclaredModel
        /// A run that would still be waiting is generating while the holder runs.
        case collision
        /// An Ollama model is asked for with a different `num_ctx` than last time: Ollama reloads it.
        case ollamaContextChanged
    }

    /// A local provider is about to generate. Logs what shadow mode exists to collect; each finding at
    /// most once per run and model.
    @discardableResult
    func noteLocalUse(runID: UUID?, engine: InferenceEngine, modelID: String,
                      contextTokens: Int? = nil) -> [UseFinding] {
        var found: [UseFinding] = []
        let model = ModelRequirement(engine: engine, modelID: modelID, role: .primary)
        if case .ollama(let baseURL) = engine {
            // The ledger of what we loaded. Ollama keeps a model per (model, num_ctx), so a request with a different context
            // window reloads it silently.
            if let previous = ollamaModelsUsed[baseURL]?[model.modelID] ?? nil,
               let contextTokens, contextTokens != previous {
                found.append(.ollamaContextChanged)
                logger.notice("[LOCAL-COORD] Ollama will RELOAD '\(model.modelID)' (\(baseURL)): num_ctx \(previous) → \(contextTokens). CONSEQUENCE: the model is read from disk again and its prompt cache is lost; two profiles (or a Code project override) asking for different context sizes on one model pay this on every switch between them.")
            }
            ollamaModelsUsed[baseURL, default: [:]][model.modelID] = .some(contextTokens ?? (ollamaModelsUsed[baseURL]?[model.modelID] ?? nil))
        }
        guard let runID else {
            reportOnce("outside/\(model.residencyKey)", .outsideAnyRun, into: &found) {
                logger.notice("[LOCAL-COORD] Local model \(model.residencyKey) used OUTSIDE any registered run. CONSEQUENCE: the coordinator cannot see this load; under enforcement it would bypass the lock.")
            }
            return found
        }
        let run = runID.uuidString.prefix(8)
        guard let manifest = manifests[runID] else {
            reportOnce("\(runID.uuidString)/unregistered/\(model.residencyKey)", .unregisteredRun, into: &found) {
                logger.notice("[LOCAL-COORD] Run \(run) used \(model.residencyKey) but is not registered (it ended, or its task outlived its run). CONSEQUENCE: this use is invisible to the lock.")
            }
            return found
        }
        if !manifest.models.contains(where: { $0.residencyKey == model.residencyKey }) {
            reportOnce("\(runID.uuidString)/undeclared/\(model.residencyKey)", .undeclaredModel, into: &found) {
                logger.warning("[LOCAL-COORD] UNDECLARED local use — run \(run) (\(manifest.origin)) used \(model.residencyKey), which its manifest does not list. CONSEQUENCE: the manifest derivation missed it; under enforcement a run it called cloud-only would use a local model without the lock.")
            }
        }
        if lock.queue.contains(where: { $0.runID == runID }) {
            reportOnce("\(runID.uuidString)/collision/\(model.residencyKey)", .collision, into: &found) {
                logger.notice("[LOCAL-COORD] \(self.label)COLLISION — run \(run) is generating on \(model.residencyKey) while it would still be waiting behind \(self.lock.holder.map { self.describe($0) } ?? "the queue head"). CONSEQUENCE: two local runs share the machine right now — expect model swaps ([MLX-LOAD]), a dropped prompt cache ([MLX-CACHE]) and slower tokens for both.")
            }
        }
        return found
    }

    // MARK: Helpers

    private func reportOnce(_ key: String, _ finding: UseFinding, into found: inout [UseFinding], _ log: () -> Void) {
        guard reportedFindings.insert(key).inserted else { return }
        found.append(finding)
        log()
    }

    private func describe(_ runID: UUID) -> String {
        guard let manifest = manifests[runID] else { return "run \(runID.uuidString.prefix(8))" }
        let held = lockedAt[runID].map { " running \(Int(now().timeIntervalSince($0)))s" } ?? ""
        return "run \(runID.uuidString.prefix(8)) (\(manifest.origin), \(manifest.localModels.map(\.modelID).joined(separator: ", "))\(held))"
    }
}

// MARK: - Building a manifest from the live stores

extension InferenceRunManifest {

    /// A local model's estimated runtime footprint from measurements only: size on disk, else parameter count; nil when
    /// neither is known. Never the tier fallback in `ModelFitAdvisor.estimateRuntimeRAM`, which is a flat guess; quiet
    /// (no per-call logging) because it runs on every send.
    nonisolated static func footprint(of config: ProviderConfig, onDiskBytes: Int64?) -> UInt64? {
        if let onDiskBytes, onDiskBytes > 0 {
            return ModelFitAdvisor.estimateRuntimeRAM(metadata: nil, diskSizeBytes: onDiskBytes)
        }
        guard ModelFitAdvisor.parseParameterCount(config.modelMetadata?.parameterCount) != nil else { return nil }
        let bytes = ModelFitAdvisor.estimateRuntimeRAM(metadata: config.modelMetadata)
        return bytes > 0 ? bytes : nil
    }

    /// The manifest for a run starting at `ActiveStreamManager.startMessageStream`, read from the SwiftData stores;
    /// layouts and node profiles are read as `WorkflowExecutor` reads them. An unreadable layout resolves to nil (an
    /// unresolved node) rather than `.empty`, which would describe a broken workflow as needing nothing.
    @MainActor
    static func build(runID: UUID,
                      conversationID: UUID,
                      profile: BackendProfileModel,
                      source: MessageSource,
                      attended: Bool,
                      isRegeneration: Bool,
                      isResume: Bool) -> InferenceRunManifest {
        let resolved = ManifestModelResolver.models(
            for: profile,
            layout: { id in
                WorkflowLayoutStore.shared.isLayoutUnreadable(for: id) ? nil : WorkflowLayoutStore.shared.load(for: id)
            },
            profiles: { ids in (try? BackendProfileStore.shared.fetchProfiles(ids: ids)) ?? [] },
            estimate: { config in
                let installed = config.apiProvider == .mlx
                    ? MLXModelService.shared.installedModel(named: config.modelName)
                        .flatMap { MLXModelService.shared.installedSizeBytes[$0.displayName] }
                    : nil
                return InferenceRunManifest.footprint(of: config, onDiskBytes: installed)
            }
        )
        return InferenceRunManifest(
            runID: runID,
            conversationID: conversationID,
            origin: RunOrigin.derive(source: source, profileType: profile.profileType,
                                     isRegeneration: isRegeneration, isResume: isResume),
            attended: attended,
            shape: profile.profileType == .workflow ? .workflow(nodeCount: resolved.nodeCount) : .single,
            models: resolved.models,
            unresolvedNodes: resolved.unresolvedNodes,
            footprints: resolved.footprints
        )
    }
}
