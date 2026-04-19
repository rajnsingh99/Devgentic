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
    let failedCount: Int
    let cancelledCount: Int
    let avgDurationMs: Int?

    /// Composite key — enables listing multiple (provider, model) pairs.
    var id: String { "\(provider)::\(modelName)" }
    var successRate: Double {
        guard totalRuns > 0 else { return 0 }
        return Double(completedCount) / Double(totalRuns)
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

    /// Number of traces observed in the window. Shown in the header as a
    /// "sanity check" — if this is 0, all the stats below are empty too.
    let totalTracesInWindow: Int
}
