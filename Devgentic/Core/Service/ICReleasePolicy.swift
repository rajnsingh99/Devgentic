// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ICReleasePolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Pure decision table for Intelligence Core model residency; the owning actor performs the `Action` it returns.
/// Never frees while a generation is in flight, and release is idle-debounced so one load serves a whole chat turn.
/// `requestImmediateRelease` opts out for deliberate teardown (feature switched off, model changed).
struct ICReleasePolicy: Equatable {

    /// What the actor should do as a result of a state change.
    enum Action: Equatable {
        /// Nothing to do — the model stays resident.
        case none
        /// Free after the idle grace period, unless new demand arrives first.
        case scheduleIdleRelease
        /// Free now.
        case freeNow
    }

    /// Generations currently in flight.
    private(set) var activeLeases: Int = 0
    /// Some feature has finished and wants the model released eventually.
    private(set) var releaseRequested: Bool = false
    /// A teardown asked to skip the idle grace period.
    private(set) var immediateRequested: Bool = false

    // MARK: - Transitions

    /// A generation is starting.
    mutating func beginLease() {
        activeLeases += 1
    }

    /// A generation finished (successfully or not). Frees only when it was the last one
    /// AND someone had asked for release.
    mutating func endLease() -> Action {
        activeLeases = max(0, activeLeases - 1)
        guard activeLeases == 0 else { return .none }
        if immediateRequested { return .freeNow }
        return releaseRequested ? .scheduleIdleRelease : .none
    }

    /// New demand for the model — cancels any pending release, since the model is wanted.
    mutating func didLoad() {
        releaseRequested = false
        immediateRequested = false
    }

    /// A feature is done with the model (the normal path).
    mutating func requestRelease() -> Action {
        releaseRequested = true
        return activeLeases == 0 ? .scheduleIdleRelease : .none
    }

    /// Deliberate teardown — skip the idle wait, but still never free under an in-flight
    /// generation; `endLease` will free it moments later instead.
    mutating func requestImmediateRelease() -> Action {
        releaseRequested = true
        immediateRequested = true
        return activeLeases == 0 ? .freeNow : .none
    }

    /// The model was actually freed.
    mutating func didFree() {
        releaseRequested = false
        immediateRequested = false
    }

    /// Whether an idle release that has now elapsed should still go ahead. A request that
    /// arrived while the timer slept must cancel it.
    var shouldHonorElapsedIdleRelease: Bool {
        releaseRequested && activeLeases == 0
    }
}
