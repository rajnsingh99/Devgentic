// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MetricsStats.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    /// Runs that produced a usable answer but hit trouble on the way (a failed tool call, circuit-breaker abort,
    /// iteration exhaustion). They still count as successes (`successRate`); the split shows a model that
    /// keeps limping over the line.
    let completedWithWarningsCount: Int
    let failedCount: Int
    let cancelledCount: Int
    /// Runs that died with the app (quit/crash mid-run) — not the model's fault, so
    /// excluded from the success-rate denominator (audit #6).
    let interruptedCount: Int
    let avgDurationMs: Int?

    /// Composite key — enables listing multiple (provider, model) pairs.
    var id: String { "\(provider)::\(modelName)" }

    /// Degraded successes are counted here: they did answer the user.
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

/// Per-workflow-node execution stats over the window. A row is one node name (the display label, not a UUID), rolled
/// up across all runs that used a node with that name. Latency is the `workflowNode` span's `endedAt - startedAt`;
/// status is `spans.status`.
struct WorkflowNodeStats: Sendable, Identifiable {
    let nodeName: String
    let totalRuns: Int
    let completedCount: Int
    let failedCount: Int
    /// Runs the user stopped mid-flight: not a verdict on the node, so excluded from the success-rate denominator.
    let cancelledCount: Int
    /// Runs skipped by routing or by the user — the node never ran, so it can be neither a
    /// success nor a failure. Excluded from the denominator for the same reason as cancels.
    let skippedCount: Int
    /// Spans still open when the panel was queried, i.e. the node is executing now. Excluded from the denominator
    /// because an unfinished run has no verdict; counted in `totalRuns` because it is a run in flight.
    let runningCount: Int
    let avgDurationMs: Int?
    let p50DurationMs: Int?
    let p95DurationMs: Int?

    var id: String { nodeName }

    /// Runs that reached a verdict: `completedCount + failedCount`. Stopped, skipped and still-running runs are not a
    /// judgement on the node.
    var attributableRuns: Int { totalRuns - cancelledCount - skippedCount - runningCount }

    // Why: nil, not 0: a node the user has only stopped has no success rate, and 0 would render as a red "0%". Unlike
    // `ModelReliabilityStats.successRate`, cancels are excluded from this denominator.
    /// Successes over attributable runs, or nil when the node has no verdict to report yet.
    /// Callers show "—", as they do for an absent p50/p95.
    var successRate: Double? {
        let attributable = attributableRuns
        guard attributable > 0 else { return nil }
        return Double(completedCount) / Double(attributable)
    }
}

// MARK: - Top-level Dashboard Snapshot

/// Aggregated result of `MetricsAggregator.snapshot(since:until:)`: one struct from one computation pass,
/// feeding all four panels in the Trends view.
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
