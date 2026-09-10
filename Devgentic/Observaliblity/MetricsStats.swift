// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MetricsStats.swift
//  Devgentic
//
//  Aggregated statistics structs returned by `MetricsAggregator`. Backed by live
//  SQL aggregations on `span_events` + `traces` + `trace_configs` — no separate
//  pre-aggregated tables. Current scale (single-user, ~30 days of data) doesn't
//  justify pre-aggregation; if dashboard latency becomes a problem in profiling,
//  we can add rolling counter tables without touching callers.
//
//  Query shape:
//    - All stats queries accept a time window (since/until Date)
//    - Results return both raw counts and derived metrics (rates, percentiles)
//    - Caller decides window; default in UI is last 7 days
//

import Foundation

// MARK: - Tool Reliability

/// Per-tool success/failure stats for the observed window. Failure breakdown
/// keyed by `AgentErrorCategory` lets the UI render a stacked-bar "why did this
/// tool fail" visualization instead of a single boolean "reliability score."
struct ToolReliabilityStats: Sendable, Identifiable {
    let toolName: String
    let totalCalls: Int
    let successCount: Int
    let failureCount: Int
    let avgDurationMs: Int?
    let p50DurationMs: Int?
    let p95DurationMs: Int?
    let failureBreakdown: [AgentErrorCategory: Int]

    var id: String { toolName }
    var successRate: Double {
        guard totalCalls > 0 else { return 0 }
        return Double(successCount) / Double(totalCalls)
    }
}

// MARK: - Error Category Frequency

/// Per-category error/warning counts for the observed window. Drives the
/// "where is the agent struggling" view — if `.parseJsonMalformed` spikes,
/// the model's generator is drifting from the expected dialect.
struct CategoryFrequencyStats: Sendable, Identifiable {
    let category: AgentErrorCategory
    let count: Int

    var id: String { category.rawValue }
    var phase: ExecutionPhase { category.phase }
    var severity: ErrorSeverity { category.severity }
    var displayName: String { category.displayName }
}

// MARK: - Model Reliability

/// Per-(provider, model) outcome rates. Drives the "which models are actually
/// working for me" view — users can compare local MLX vs Ollama vs cloud
/// providers at a glance.
struct ModelReliabilityStats: Sendable, Identifiable {
    let provider: String
    let modelName: String
    let totalRuns: Int
    let completedCount: Int
    /// Runs that produced a usable answer but hit trouble on the way (a failed tool
    /// call, circuit-breaker abort, iteration exhaustion). Before 2026-07-19 these were
    /// persisted as plain `completed` and were invisible here. They still count as
    /// successes (`successRate`), but the split shows a model that keeps limping over
    /// the line rather than clearing it.
    let completedWithWarningsCount: Int
    let failedCount: Int
    let cancelledCount: Int
    /// Runs that died with the app (quit/crash mid-run) — not the model's fault, so
    /// excluded from the success-rate denominator (audit #6).
    let interruptedCount: Int
    let avgDurationMs: Int?

    /// Composite key — enables listing multiple (provider, model) pairs.
    var id: String { "\(provider)::\(modelName)" }

    /// Degraded successes are counted here deliberately — they DID answer the user.
    /// This keeps the rate numerically identical to before `completedWithWarnings`
    /// became its own status, so historical dashboards don't step-change.
    var successRate: Double {
        let attributable = totalRuns - interruptedCount
        guard attributable > 0 else { return 0 }
        return Double(completedCount + completedWithWarningsCount) / Double(attributable)
    }

    /// Share of successful runs that were degraded. Surfaces the "always completes,
    /// always with a broken tool call" model that `successRate` alone hides.
    var degradedShare: Double {
        let successes = completedCount + completedWithWarningsCount
        guard successes > 0 else { return 0 }
        return Double(completedWithWarningsCount) / Double(successes)
    }
}

// MARK: - Circuit Breaker

/// Circuit-breaker trip summary. Breaks out the 5 CB categories (repetitive,
/// consecutive fail, tool retry limit, idle limit, ask-user limit) so we can
/// see which safeguard is firing most.
struct CircuitBreakerStats: Sendable {
    let totalTrips: Int
    let tripsByCategory: [AgentErrorCategory: Int]
    let topOffendingTools: [(tool: String, count: Int)]
    let windowStart: Date
    let windowEnd: Date
}

// MARK: - Workflow Node Stats

/// Per-workflow-node execution stats aggregated over the window. Each row
/// represents one node *name* (i.e. the user's display label, not a node UUID),
/// rolled up across all runs that used a node with that name. Latency comes from
/// the `workflowNode`-kind span's `(endedAt - startedAt)`, status from
/// `spans.status`. Driven by P1-10 (per-node spans persisted to TraceStore).
struct WorkflowNodeStats: Sendable, Identifiable {
    let nodeName: String
    let totalRuns: Int
    let completedCount: Int
    let failedCount: Int
    /// Runs the user stopped mid-flight — not a verdict on the node, so excluded from the
    /// success-rate denominator (WF-OB6). Before 2026-08-27 a cancelled span was persisted as
    /// `.error`, so every Stop was counted as a node FAILURE: a user who stopped a 6-node
    /// workflow three times while iterating on a prompt saw those nodes sitting at ~50% in the
    /// Workflow Activity panel, which is precisely the signal that panel exists to surface.
    let cancelledCount: Int
    /// Runs skipped by routing or by the user — the node never ran, so it can be neither a
    /// success nor a failure. Excluded from the denominator for the same reason as cancels.
    let skippedCount: Int
    /// Spans still open when the panel was queried — i.e. the node is executing RIGHT NOW.
    /// Reachable simply by opening Workflow Activity during a run. Excluded from the denominator
    /// because an unfinished run has not reached a verdict; counted in `totalRuns` because it is
    /// genuinely a run in flight.
    let runningCount: Int
    let avgDurationMs: Int?
    let p50DurationMs: Int?
    let p95DurationMs: Int?

    var id: String { nodeName }

    /// Runs that actually reached a verdict: `completedCount + failedCount`. Everything else —
    /// stopped, skipped, still running — is deliberately not a judgement on the node.
    var attributableRuns: Int { totalRuns - cancelledCount - skippedCount - runningCount }

    /// Successes over attributable runs, or `nil` when the node has no verdict to report yet.
    ///
    /// ⚠️ NIL, NOT ZERO, and that distinction is the whole point: a node the user has only ever
    /// stopped has NO success rate, and returning `0` would render as a red "0%" — reproducing
    /// this row's own defect (a Stop reading as brokenness) at a different number. Callers show
    /// "—", exactly as they already do for an absent p50/p95.
    ///
    /// ⚠️ Re-tagging cancelled spans is NOT sufficient on its own: this denominator is what
    /// actually decides whether a Stop dents the rate. Removing cancels from `failedCount` while
    /// leaving them in the denominator would still push the rate down — the fix only works as a
    /// pair, which is why the counts above exist rather than the SQL simply filtering them out.
    ///
    /// ⚠️ This DIVERGES from `ModelReliabilityStats.successRate` above, which subtracts only
    /// `interruptedCount` and deliberately keeps cancels in its denominator (it is pinned to stay
    /// "numerically identical" to pre-2026-07-19 dashboards). The divergence is intentional here
    /// and NOT retrofitted there: changing that one is a behaviour change to a separate metric
    /// with its own history. Consequence to know: in the same Trends view, a user who pressed Stop
    /// three times now sees the workflow-node row corrected while the model row is still dented.
    var successRate: Double? {
        let attributable = attributableRuns
        guard attributable > 0 else { return nil }
        return Double(completedCount) / Double(attributable)
    }
}

// MARK: - Top-level Dashboard Snapshot

/// Aggregated result of `MetricsAggregator.snapshot(since:until:)`. One struct,
/// one computation pass, all four panels in the Trends view. Using a snapshot
/// keeps the UI simple: one `@State var snapshot: MetricsSnapshot?` + one
/// refresh button.
struct MetricsSnapshot: Sendable {
    let generatedAt: Date
    let windowStart: Date
    let windowEnd: Date

    let toolStats: [ToolReliabilityStats]
    let categoryStats: [CategoryFrequencyStats]
    let modelStats: [ModelReliabilityStats]
    let circuitBreakerStats: CircuitBreakerStats
    /// Per-workflow-node stats — populated when the snapshot's profileType
    /// filter is nil (all) or `.workflow`. Empty for other filters so the
    /// dashboard can hide the "Workflow Activity" panel when irrelevant.
    let workflowNodeStats: [WorkflowNodeStats]

    /// Number of traces observed in the window. Shown in the header as a
    /// "sanity check" — if this is 0, all the stats below are empty too.
    let totalTracesInWindow: Int
}
