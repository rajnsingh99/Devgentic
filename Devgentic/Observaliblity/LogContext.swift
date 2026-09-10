// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  LogContext.swift
//  Devgentic
//
//  Task-local context propagation for `DGLogger`. When a call runs inside
//  `LogContext.with(traceID:spanID:phase:) { ... }`, every log call made inside
//  the closure automatically attaches that context to its `LogEntry` without
//  the caller having to thread parameters everywhere.
//
//  Swift's `@TaskLocal` values propagate through structured concurrency — async
//  calls, child tasks, task groups. They do NOT propagate into unstructured
//  Tasks (e.g., `Task { ... }`) unless you explicitly re-install via `with(...)`.
//  For our use case this is intentional: the agent pipeline is structured, and
//  detached `Task`s that shouldn't inherit context (e.g., persistence writes,
//  metrics batching) are correctly isolated.
//
//  Usage:
//
//      await LogContext.with(traceID: trace.traceID, spanID: span.spanID) {
//          myLogger.info("Executing step")       // auto-tagged with trace/span
//          try await executor.execute(...)       // inherits
//      }
//

import Foundation

/// Ambient logging context for the current task. Read by `DGLogger` to stamp
/// every `LogEntry` with the active trace/span/phase so the Report Inspector
/// can filter logs by incident.
enum LogContext {

    /// Current trace ID, if any.
    @TaskLocal static var traceID: String?

    /// Current span ID, if any. Usually updated on span entry.
    @TaskLocal static var spanID: String?

    /// Current execution phase, if known. Usually set at executor entry.
    @TaskLocal static var phase: ExecutionPhase?

    /// Runs `operation` with the given context installed on the current task tree.
    /// Passing `nil` for a field inherits the parent scope's value; passing a
    /// non-nil value overrides it. This mirrors common MDC/AsyncLocal semantics.
    ///
    /// Example:
    ///
    ///     await LogContext.with(traceID: "abc-123", phase: .tooling) {
    ///         // Any DGLogger calls inside here are tagged with traceID=abc-123, phase=.tooling
    ///     }
    static func with<T>(
        traceID: String? = nil,
        spanID: String? = nil,
        phase: ExecutionPhase? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        // Install each value in turn. Nil means "inherit" — explicitly pass the
        // current value so the Task-local override uses the parent scope's state.
        try await Self.$traceID.withValue(traceID ?? Self.traceID) {
            try await Self.$spanID.withValue(spanID ?? Self.spanID) {
                try await Self.$phase.withValue(phase ?? Self.phase) {
                    try await operation()
                }
            }
        }
    }
}
