// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeadlineRace.swift
//  Devgentic
//
//  The one race that RETURNS AT ITS LIMIT (HITL Waiting Contract §6.3).
//

import Foundation

/// Runs work against a time limit and returns when the limit passes — whether or not the work
/// has noticed.
///
/// ⚠️⚠️ WHY THIS EXISTS. Every timeout in the app used to be
/// `withThrowingTaskGroup { work; sleep; throw }`. A task group cannot return until EVERY child
/// has returned, so when the work ignores cancellation — a process wait, a blocking syscall, an
/// MCP request, an AppleScript — the "timeout" fires and then waits for the work anyway, and
/// reports a timeout for work that finished (proven 2026-09-26: a 1 s bound returned after
/// 4.01 s and discarded a build that exited 0 — Timeout inventory P1, P5, P10).
///
/// This race holds the work in an UNSTRUCTURED task and settles a single continuation with
/// whichever comes first: the work's result or the clock (the settle-once shape
/// `MCPClientService.withTimeout` already used).
///
/// At the limit the work is CANCELLED — which is what fires stop hooks such as the shell's
/// process kill — and given `stopGrace` to hand back what it had. Work that is still running
/// after that is abandoned and reported as such (`afterStop == nil`), never waited for.
///
/// Clock: `SuspendingClock` — time the Mac spends asleep does not count, because the work was not
/// running either (Contract §6.5).
///
/// With a `parkScope`, the limit is COMPUTE: the work runs inside that `ParkScope`, and time any
/// park in its chain stays open — a human answering an MCP question mid-call, say — is not counted
/// (Contract decision 1: a human is never timed).
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

    /// Finite and non-negative, and short of what `Duration` can hold. A limit is validated before
    /// it gets here (Contract §5 "No limit"); this only keeps a bad value from trapping.
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
