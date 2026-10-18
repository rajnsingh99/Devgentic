// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComputeTimeoutSentinel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "ComputeTimeoutSentinel")

// Why: a run parked on a confirmation banner has not misbehaved; every path bounding a run shares this
// park-aware implementation, not a bare sleep
/// Sleeps until compute time exceeds a limit, then throws `.executionTimeout`; returns `Never`, so it is a
/// sentinel to race work against. The clock excludes time parked awaiting a human, per owner chain
/// (`ParkScope`). Self-correcting: sleeps to the nominal deadline, then extends by the unparked shortfall.
enum ComputeTimeoutSentinel {

    /// - Parameters: limit: compute budget in seconds; scope: the bound's `ParkScope` id, which the bounded work
    /// must run inside or its parks will not pause the clock; logTag: bracket tag for logs; subject: what is
    /// bounded; consequence: what happens when the budget is exhausted.
    static func sleepUntilComputeExceeded(
        limit: TimeInterval,
        scope: UUID,
        logTag: String,
        subject: String,
        consequence: String
    ) async throws -> Never {
        let clock = SuspendingClock()
        let start = clock.now
        let suspension = ExecutionSuspensionService.shared
        let parkedAtStart = await suspension.parkedTime(forScope: scope)
        var remaining = limit

        while true {
            try await Task.sleep(for: .seconds(max(remaining, 0)), clock: .suspending)
            let parked = await suspension.parkedTime(forScope: scope) - parkedAtStart
            let wall = DeadlineRace.seconds(clock.now - start)
            let compute = wall - parked

            if compute >= limit {
                logger.error("[\(logTag)] \(subject) exceeded its \(Int(limit))s compute budget (\(Int(compute))s compute, \(Int(parked))s parked awaiting a human, \(Int(wall))s wall-clock). CONSEQUENCE: \(consequence)")
                throw AgentExecutionError(reason: .executionTimeout(elapsed: compute, limit: limit))
            }

            remaining = limit - compute
            // While a park is open the shortfall can be a sliver, and re-arming for it would spin this loop; nothing is charged
            // while it stays open, so wake at most once a second.
            if await suspension.isParked(scope: scope) { remaining = max(remaining, 1) }
            logger.debug("[\(logTag)] \(subject) timeout extended by \(Int(remaining))s — \(Int(parked))s of the elapsed \(Int(wall))s was spent awaiting a human, which does not count against the compute budget.")
        }
    }
}
