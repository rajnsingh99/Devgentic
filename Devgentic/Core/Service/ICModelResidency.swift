// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ICModelResidency.swift
//  Devgentic
//
//  Which Intelligence Core model is resident, and the ONE load that may be in flight.
//
//  ⚠️⚠️ READINESS CR-32 (2026-10-11). `IntelligenceCoreService.load` asked only "is SOME model
//  loaded?" and then suspended twice (resolving the path, then the multi-second MLX load). Actor
//  reentrancy let a second caller in during either suspension; it also saw nothing loaded and started
//  its own load — two copies in memory, two load times paid. The in-turn callers (query rewriting,
//  response synthesis) take no local lock, so they overlap a background compaction or Morning Brief.
//  And it never compared WHICH model was loaded, so after a selection change the old model kept
//  answering: "Set as IC" in the Model Store wrote the setting without unloading, an unload that
//  arrived during a load found nothing to free and the load then installed the old model, and every
//  new request cancelled the idle free — in an active session, indefinitely.
//
//  Now: the selection is re-read on every pass, a request for the model being loaded JOINS that load,
//  a resident model whose name no longer matches the selection is freed (once no generation is using
//  it) and the selected one loaded, and an immediate teardown that arrives mid-load is honoured once
//  the work that load serves has finished. Comparing against the setting itself covers every writer
//  of it — no screen has to remember to unload.
//
//  Generic over the model so the concurrency is testable without MLX; the residency DECISION table
//  (leases, idle debounce) stays in `ICReleasePolicy`.
//

import Foundation

actor ICModelResidency<Model: Sendable> {

    /// Loads the named model. Throws when nothing is selected or the model can't be found or loaded.
    typealias Loader = @Sendable (_ name: String, _ caller: ICCallerFeature, _ loadID: String) async throws -> Model
    /// Called once a model has been dropped — frees the process-wide buffer cache and logs memory.
    typealias FreeHook = @Sendable (_ name: String, _ reason: String, _ caller: ICCallerFeature) -> Void

    private struct Resident {
        let name: String
        let model: Model
        let loadedBy: ICCallerFeature
        let loadedAt: Date
    }

    private struct InFlightLoad {
        let name: String
        let id: String
        let task: Task<Model, Error>
    }

    private let logger = DGLogger(category: "IntelligenceCoreService")
    private let selection: @Sendable () -> String
    private let loader: Loader
    private let onFree: FreeHook
    private let idleReleaseSeconds: Double

    private var resident: Resident?
    private var inFlight: InFlightLoad?
    private var policy = ICReleasePolicy()
    private var idleReleaseTask: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    /// Requests that joined a load already in flight instead of starting their own. Diagnostic.
    private(set) var joinedLoads = 0
    /// Requests waiting for in-flight generations to finish before the old model can be swapped out.
    var waitingForGenerationsToDrain: Int { drainWaiters.count }
    var residentName: String? { resident?.name }
    var activeLeases: Int { policy.activeLeases }

    /// - Parameter selection: the model the user has selected NOW. Read on every pass, never cached.
    init(selection: @escaping @Sendable () -> String,
         idleReleaseSeconds: Double,
         loader: @escaping Loader,
         onFree: @escaping FreeHook) {
        self.selection = selection
        self.idleReleaseSeconds = idleReleaseSeconds
        self.loader = loader
        self.onFree = onFree
    }

    // MARK: - Demand

    /// Makes the selected model resident, without holding it.
    func prepare(caller: ICCallerFeature) async throws -> Model {
        try await acquire(caller: caller, leasing: false)
    }

    /// Makes the selected model resident AND takes a lease on it, in one step: no other request can
    /// free it between the two. Pair every successful call with `endGeneration`.
    func beginGeneration(caller: ICCallerFeature) async throws -> Model {
        try await acquire(caller: caller, leasing: true)
    }

    func endGeneration(caller: ICCallerFeature) {
        apply(policy.endLease(), caller: caller, reason: "last generation finished")
        if policy.activeLeases == 0 { resumeDrainWaiters() }
    }

    // MARK: - Release

    /// The caller is done with the model. Freed after the idle grace period unless demand returns.
    func requestRelease(caller: ICCallerFeature) {
        apply(policy.requestRelease(), caller: caller, reason: "released by \(caller.rawValue)")
    }

    /// Deliberate teardown — free as soon as nothing is using the model.
    func requestImmediateRelease(caller: ICCallerFeature) {
        apply(policy.requestImmediateRelease(), caller: caller, reason: "immediate teardown")
    }

    // MARK: - Acquire

    private func acquire(caller: ICCallerFeature, leasing: Bool) async throws -> Model {
        // Any new demand cancels a pending idle free — this is what lets a turn's sequential IC
        // features (RAG rewrite → compaction → synthesis) share one load.
        cancelIdleRelease()
        policy.didLoad()

        while true {
            // Re-read every pass: the selection can change during any of the awaits below.
            let wanted = selection().trimmingCharacters(in: .whitespacesAndNewlines)

            if let current = resident {
                if current.name == wanted {
                    if leasing { policy.beginLease() }
                    if current.loadedBy != caller {
                        logger.info("[IC Load] '\(wanted)' already in memory — reusing for \(caller.rawValue) (loaded by \(current.loadedBy.rawValue)).")
                    }
                    return current.model
                }
                // The selection moved away from the resident model.
                if policy.activeLeases > 0 {
                    logger.notice("[IC Load] \(caller.rawValue) wants '\(wanted.isEmpty ? "<none>" : wanted)' but '\(current.name)' is resident with \(self.policy.activeLeases) generation(s) in flight. CONSEQUENCE: the swap waits for them to finish — the old model is never freed under a running generation, and never answers this request.")
                    await waitForGenerationsToDrain()
                    continue
                }
                free(reason: "the Intelligence Core selection changed from '\(current.name)' to '\(wanted.isEmpty ? "<none>" : wanted)'", caller: caller)
                continue
            }

            if let load = inFlight {
                if load.name == wanted {
                    joinedLoads += 1
                    logger.info("[IC Load] load \(load.id): \(caller.rawValue) joins the load of '\(wanted)' already in flight instead of starting a second one.")
                    _ = try await load.task.value      // its failure is this request's failure
                } else {
                    logger.notice("[IC Load] load \(load.id): \(caller.rawValue) wants '\(wanted.isEmpty ? "<none>" : wanted)' while '\(load.name)' is still loading. CONSEQUENCE: waits for that load to finish, then swaps it out — an MLX load can't be interrupted.")
                    _ = try? await load.task.value
                }
                continue
            }

            let loadID = String(UUID().uuidString.prefix(8))
            let task = Task { try await self.runLoad(name: wanted, caller: caller, loadID: loadID) }
            inFlight = InFlightLoad(name: wanted, id: loadID, task: task)
            _ = try await task.value                   // installed by `runLoad`; the next pass returns it
        }
    }

    /// The one place a model is installed. Runs on the actor, so it installs before the load's task
    /// completes — every joiner sees the result on its next pass.
    private func runLoad(name: String, caller: ICCallerFeature, loadID: String) async throws -> Model {
        defer { if inFlight?.id == loadID { inFlight = nil } }
        let model = try await loader(name, caller, loadID)
        resident = Resident(name: name, model: model, loadedBy: caller, loadedAt: Date())
        if policy.immediateRequested && policy.activeLeases == 0 {
            logger.notice("[IC Load] load \(loadID): '\(name)' finished loading after a teardown was requested. CONSEQUENCE: it serves the request that started it, then is freed when that finishes.")
        }
        return model
    }

    // MARK: - Freeing

    private func apply(_ action: ICReleasePolicy.Action, caller: ICCallerFeature, reason: String) {
        switch action {
        case .none:
            if policy.activeLeases > 0 {
                logger.info("[IC Release] Release requested by \(caller.rawValue), but \(self.policy.activeLeases) generation(s) still in flight — deferred until they finish.")
            }
        case .scheduleIdleRelease:
            scheduleIdleRelease(caller: caller)
        case .freeNow:
            cancelIdleRelease()
            if resident == nil, let load = inFlight {
                // ⚠️ Freeing "nothing" here used to clear the request, and the load then installed the
                // model it was asked to drop. Keep the request; `endGeneration` honours it.
                logger.notice("[IC Release] \(reason) requested by \(caller.rawValue) while load \(load.id) of '\(load.name)' is in flight. CONSEQUENCE: freed as soon as the request that load serves finishes.")
                return
            }
            free(reason: reason, caller: caller)
        }
    }

    private func scheduleIdleRelease(caller: ICCallerFeature) {
        cancelIdleRelease()
        guard resident != nil else { return }
        let seconds = idleReleaseSeconds
        logger.info("[IC Release] Idle release scheduled in \(Int(seconds))s — requested by: \(caller.rawValue). Any request before then reuses the loaded model.")
        idleReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performIdleRelease(caller: caller)
        }
    }

    private func performIdleRelease(caller: ICCallerFeature) {
        // Re-checked under actor isolation: demand may have arrived while we slept.
        guard !Task.isCancelled, policy.shouldHonorElapsedIdleRelease else {
            logger.info("[IC Release] Idle release skipped — model is back in use (leases: \(self.policy.activeLeases)).")
            return
        }
        free(reason: "idle for \(Int(idleReleaseSeconds))s", caller: caller)
    }

    private func cancelIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
    }

    private func free(reason: String, caller: ICCallerFeature) {
        cancelIdleRelease()
        policy.didFree()
        guard let dropped = resident else {
            logger.debug("[IC Unload] No-op — model not loaded. Caller: \(caller.rawValue)")
            return
        }
        resident = nil
        let session = String(format: "%.1fs", Date().timeIntervalSince(dropped.loadedAt))
        logger.notice("[IC Unload] '\(dropped.name)' released — Session: \(session), Reason: \(reason), Loaded by: \(dropped.loadedBy.rawValue), Unloaded by: \(caller.rawValue)")
        onFree(dropped.name, reason, caller)
    }

    // MARK: - Drain

    private func waitForGenerationsToDrain() async {
        guard policy.activeLeases > 0 else { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }
}
