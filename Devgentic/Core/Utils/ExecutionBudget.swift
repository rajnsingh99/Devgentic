// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ExecutionBudget.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "ExecutionBudget")

/// The time limits the current task runs inside (a scheduled run, a turn, a workflow node), carried as a TaskLocal
/// stack so an inner limit shortens to fit what an outer one has left. An inner limit is `min(own, outer remaining −
/// reserve)`, so it fires first with its partial output. Inherited by `Task { }`, not `Task.detached`.
enum ExecutionBudget {

    /// Time kept back for the enclosing limit's owner to respond once an inner limit fires.
    static let reserve: TimeInterval = 60

    /// The reserve a given outer limit keeps: 60 s, or a tenth of the limit when that is shorter. A flat 60 s would leave
    /// short limits no usable budget.
    static func reserve(forLimit limit: TimeInterval) -> TimeInterval {
        min(reserve, limit / 10)
    }

    struct Frame: Sendable {
        /// What the limit belongs to, for the model and the log: "the turn", "the scheduled run".
        let owner: String
        let limit: TimeInterval
        /// The bound's `ParkScope` id — its parked time is credited back.
        let scope: UUID
        let start: SuspendingClock.Instant
        let parkedAtStart: TimeInterval
    }

    @TaskLocal static var frames: [Frame] = []

    /// Opens a frame for a bound that is about to start. `parkedAtStart` is read now so parks that
    /// happened before the bound are not credited to it.
    static func frame(owner: String, limit: TimeInterval, scope: UUID) async -> Frame {
        Frame(owner: owner, limit: limit, scope: scope, start: SuspendingClock().now,
              parkedAtStart: await ExecutionSuspensionService.shared.parkedTime(forScope: scope))
    }

    /// Runs `operation` inside `frame` (async work).
    static func withFrame<T>(_ frame: Frame, _ operation: () async throws -> T) async rethrows -> T {
        try await $frames.withValue(frames + [frame]) { try await operation() }
    }

    /// Binds `frame` around work that is CREATED here and runs elsewhere (a stream's producer task).
    /// A nil frame (a bound with no limit) binds nothing.
    static func bind<T>(_ frame: Frame?, _ operation: () throws -> T) rethrows -> T {
        guard let frame else { return try operation() }
        return try $frames.withValue(frames + [frame]) { try operation() }
    }

    /// Compute time left in `frame`.
    static func remaining(in frame: Frame) async -> TimeInterval {
        let wall = DeadlineRace.seconds(SuspendingClock().now - frame.start)
        let parked = await ExecutionSuspensionService.shared.parkedTime(forScope: frame.scope) - frame.parkedAtStart
        return frame.limit - (wall - parked)
    }

    /// The tightest enclosing limit: its owner, the compute time it has left, and the reserve it
    /// keeps. nil outside any.
    static func tightest() async -> (owner: String, remaining: TimeInterval, reserve: TimeInterval)? {
        var best: (owner: String, remaining: TimeInterval, reserve: TimeInterval)?
        for frame in frames {
            let left = await remaining(in: frame)
            if best == nil || left < best!.remaining { best = (frame.owner, left, reserve(forLimit: frame.limit)) }
        }
        return best
    }

    /// The time an inner bound may have, given what an outer one has left. If `remaining > 2 × reserve`: everything but
    /// the reserve; otherwise half of what is left. Pure, for tests.
    static func available(outerRemaining remaining: TimeInterval, reserve: TimeInterval = reserve) -> TimeInterval {
        remaining > 2 * reserve ? remaining - reserve : max(remaining / 2, 0)
    }

    struct Clamp: Equatable {
        let limit: TimeInterval
        /// Set when the outer limit shortened `own`: "the turn's 10 min limit".
        let shortenedBy: String?
        /// The time the outer limit keeps back after this one fires.
        var reserve: TimeInterval = 0
    }

    /// `own` fitted inside the tightest enclosing limit. `own == nil` means "no limit of its own".
    static func clamp(_ own: TimeInterval?, what: String) async -> Clamp {
        guard let outer = await tightest() else { return Clamp(limit: own ?? .infinity, shortenedBy: nil) }
        let fits = available(outerRemaining: outer.remaining, reserve: outer.reserve)
        guard fits < (own ?? .infinity) else { return Clamp(limit: own ?? .infinity, shortenedBy: nil) }
        logger.info("[NESTING] \(what): limit \(own.map { "\(Int($0))s" } ?? "none") shortened to \(Int(fits))s — \(outer.owner) has \(Int(outer.remaining))s left and keeps \(Int(outer.reserve))s to respond. CONSEQUENCE: this limit fires first, with its partial result, instead of \(outer.owner) cutting everything off.")
        return Clamp(limit: fits, shortenedBy: outer.owner, reserve: outer.reserve)
    }

    /// Whether another attempt can still fit: false once the tightest enclosing limit has no more
    /// than `reserve` left, so a retry that could only be cut off is not started — the reserve is
    /// for reporting the failure, not for a doomed attempt.
    static func retryFits(what: String) async -> Bool {
        guard let outer = await tightest(), outer.remaining <= outer.reserve else { return true }
        logger.notice("[NESTING] \(what): not retried — only \(Int(max(outer.remaining, 0)))s left in \(outer.owner). CONSEQUENCE: the last failure stands and the remaining time is left for reporting it.")
        return false
    }
}

/// One rule for a configured time limit: 0, a negative or a non-finite value means "not set" (the next setting in the
/// priority chain applies), never "time out instantly". The tool dispatcher follows the same rule
/// (`ToolExecutionMediator.effectiveTimeout`).
enum TimeLimit {
    static func usable(_ value: TimeInterval?, _ what: @autoclosure () -> String) -> TimeInterval? {
        guard let value else { return nil }
        guard value.isFinite, value > 0 else {
            logger.warning("[TIME_LIMIT] \(what()) is set to \(value)s, which is not a usable limit. CONSEQUENCE: treated as NOT SET — the next setting applies (or no limit), instead of timing out instantly.")
            return nil
        }
        return value
    }
}
