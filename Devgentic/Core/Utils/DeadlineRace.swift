// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeadlineRace.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: a task-group timeout cannot return until every child does, so work ignoring cancellation delays it;
// this race settles one continuation from an unstructured task instead.
/// Runs work against a time limit and returns when it passes, whether or not the work has noticed.
/// At the limit the work is cancelled and given `stopGrace` to hand back what it had; if still running it is abandoned
/// (`afterStop == nil`), never awaited. `SuspendingClock` time; with a `parkScope`, parked time is not counted.
enum DeadlineRace {

    enum Outcome<T: Sendable>: Sendable {
        /// The work finished inside the limit (successfully or by throwing).
        case finished(Result<T, Error>)
        /// The limit passed first. The work was cancelled; `afterStop` is what it returned within
        /// the stop grace, or nil if it was still running when the grace ran out.
        case timedOut(elapsed: TimeInterval, afterStop: Result<T, Error>?)
    }

    /// - Throws: `CancellationError` if the CALLER is cancelled (Stop). The work is cancelled too,
    ///   and the call returns at once rather than waiting for it.
    static func run<T: Sendable>(
        limit: TimeInterval,
        stopGrace: TimeInterval,
        parkScope: UUID? = nil,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> Outcome<T> {
        let clock = SuspendingClock()
        let start = clock.now
        let suspension = ExecutionSuspensionService.shared

        let workTask: Task<T, Error>
        var parkedAtStart: TimeInterval = 0
        if let parkScope {
            await suspension.registerScope(parkScope, under: ParkScope.chain)
            parkedAtStart = await suspension.parkedTime(forScope: parkScope)
            // CREATED inside the scope, so the work and anything it spawns carry the chain.
            workTask = ParkScope.bind(parkScope) { Task { try await work() } }
        } else {
            workTask = Task { try await work() }
        }
        defer { if let parkScope { Task { await suspension.unregisterScope(parkScope) } } }

        let parkedBaseline = parkedAtStart
        let expiry: @Sendable () async -> Void = {
            guard let parkScope else {
                try? await Task.sleep(for: .seconds(sanitized(limit)), clock: .suspending)
                return
            }
            await waitForCompute(limit, scope: parkScope, parkedAtStart: parkedBaseline, start: start)
        }
        let first = await withTaskCancellationHandler {
            await result(of: workTask, until: expiry)
        } onCancel: {
            workTask.cancel()
        }
        if Task.isCancelled {
            workTask.cancel()
            throw CancellationError()
        }
        if let first { return .finished(first) }

        var elapsed = seconds(clock.now - start)
        if let parkScope {
            elapsed -= await suspension.parkedTime(forScope: parkScope) - parkedBaseline
        }
        workTask.cancel()
        let afterStop = await withTaskCancellationHandler {
            await result(of: workTask, within: stopGrace)
        } onCancel: {
            workTask.cancel()
        }
        if Task.isCancelled { throw CancellationError() }
        return .timedOut(elapsed: elapsed, afterStop: afterStop)
    }

    /// The task's result if it arrives within `seconds`, else nil. Returns promptly (nil) if the
    /// caller is cancelled. Never waits past its bound.
    static func result<T: Sendable>(of task: Task<T, Error>, within seconds: TimeInterval) async -> Result<T, Error>? {
        await result(of: task, until: {
            try? await Task.sleep(for: .seconds(sanitized(seconds)), clock: .suspending)
        })
    }

    /// The task's result if it arrives before `expiry` returns, else nil.
    static func result<T: Sendable>(of task: Task<T, Error>, until expiry: @escaping @Sendable () async -> Void) async -> Result<T, Error>? {
        let gate = SettleOnce<Result<T, Error>?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let timer = Task {
                    await expiry()
                    gate.settle(nil)
                }
                gate.onSettle { timer.cancel() }
                Task {
                    let outcome = await task.result
                    gate.settle(outcome)
                }
            }
        } onCancel: {
            gate.settle(nil)
        }
    }

    /// Returns once `limit` seconds of COMPUTE have passed — suspended-clock time minus time a park
    /// in `scope`'s chain was open. Returns early (harmlessly) if cancelled: the caller has settled.
    private static func waitForCompute(_ limit: TimeInterval, scope: UUID,
                                       parkedAtStart: TimeInterval, start: SuspendingClock.Instant) async {
        let clock = SuspendingClock()
        let suspension = ExecutionSuspensionService.shared
        var remaining = limit
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(sanitized(remaining)), clock: .suspending)
            if Task.isCancelled { return }
            let parked = await suspension.parkedTime(forScope: scope) - parkedAtStart
            let compute = seconds(clock.now - start) - parked
            if compute >= limit { return }
            remaining = limit - compute
            // A park still open charges nothing; re-check once a second rather than spinning.
            if await suspension.isParked(scope: scope) { remaining = max(remaining, 1) }
        }
    }

    /// Clamps `seconds` to a finite, non-negative value short of what `Duration` can hold, so a bad value cannot trap.
    private static func sanitized(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return 365 * 24 * 3600 }
        return min(max(seconds, 0), 365 * 24 * 3600)
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// A continuation that is resumed exactly once, by whichever settler arrives first — including one
/// that arrives before the continuation is installed.
private final class SettleOnce<V: Sendable>: @unchecked Sendable {
    private enum State {
        case waiting(CheckedContinuation<V, Never>?)
        case settled(V)
    }

    private let lock = NSLock()
    private var state: State = .waiting(nil)
    private var settleHandlers: [@Sendable () -> Void] = []
    private var isDone = false

    func install(_ continuation: CheckedContinuation<V, Never>) {
        lock.lock()
        switch state {
        case .settled(let value):
            lock.unlock()
            continuation.resume(returning: value)
        case .waiting:
            state = .waiting(continuation)
            lock.unlock()
        }
    }

    func onSettle(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if isDone {
            lock.unlock()
            handler()
            return
        }
        settleHandlers.append(handler)
        lock.unlock()
    }

    func settle(_ value: V) {
        lock.lock()
        guard !isDone else { lock.unlock(); return }
        isDone = true
        let handlers = settleHandlers
        settleHandlers = []
        var toResume: CheckedContinuation<V, Never>?
        if case .waiting(let continuation) = state { toResume = continuation }
        state = .settled(value)
        lock.unlock()

        toResume?.resume(returning: value)
        for handler in handlers { handler() }
    }
}
