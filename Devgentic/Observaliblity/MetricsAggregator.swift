//
//  MetricsAggregator.swift
//  Devgentic
//
//  Facade over `TraceStore`'s aggregation queries. Thin wrapper with sensible
//  defaults (last 7 days, empty-store-returns-empty-stats). Callers get a single
//  `snapshot(since:until:)` entry point that pulls every dashboard panel in one go.
//
//  Why a separate facade (not direct TraceStore calls):
//    1. Central place to wrap try/catch — UI code stays `try?`-free.
//    2. Future-proofing: when pre-aggregation tables are added (if dashboard
//       latency becomes an issue), the call sites don't change — just swap
//       implementations inside MetricsAggregator.
//    3. A convenient place to add cross-query derived metrics (e.g., "worst
//       failing tool across all providers") without cluttering the store.
//

import Foundation

struct MetricsAggregator: Sendable {

    static let shared = MetricsAggregator()

    private let store: TraceStore?

    init(store: TraceStore? = TraceStore.shared) {
        self.store = store
    }

    // MARK: - Default snapshot

    /// Pulls all four dashboard panels for the given window in one call. If the
    /// store is unavailable or queries throw, returns an empty snapshot — the
    /// dashboard renders as "no data yet" rather than crashing.
    ///
    /// `profileType` constrains every query to traces of the matching type
    /// (raw value of `ProfileType` — `"Bot"`, `"Agent"`, `"Workflow"`, etc.).
    /// Nil = no filter (all profile types folded together; original behavior).
    /// Drives P1-15 — workflow data can now be isolated in the dashboard.
    func snapshot(since: Date, until: Date = Date(), profileType: String? = nil) -> MetricsSnapshot {
        guard let store else { return Self.empty(since: since, until: until) }

        let toolStats     = (try? store.toolReliabilityStats(since: since, until: until, profileType: profileType)) ?? []
        let categoryStats = (try? store.categoryFrequencyStats(since: since, until: until, profileType: profileType)) ?? []
        let modelStats    = (try? store.modelReliabilityStats(since: since, until: until, profileType: profileType)) ?? []
        let cbStats       = (try? store.circuitBreakerStatsAggregate(since: since, until: until, profileType: profileType))
            ?? CircuitBreakerStats(totalTrips: 0, tripsByCategory: [:], topOffendingTools: [],
                                   windowStart: since, windowEnd: until)
        let totalTraces   = (try? store.traceCount(since: since, until: until, profileType: profileType)) ?? 0

        // Workflow node stats are only meaningful when the user is looking at
        // workflows (or unfiltered). Skip the query otherwise — saves a roundtrip
        // and an empty result the UI would hide anyway.
        let workflowStats: [WorkflowNodeStats]
        if profileType == nil || profileType == "Workflow" {
            workflowStats = (try? store.workflowNodeStats(since: since, until: until, profileType: profileType)) ?? []
        } else {
            workflowStats = []
        }

        return MetricsSnapshot(
            generatedAt: Date(),
            windowStart: since,
            windowEnd: until,
            toolStats: toolStats,
            categoryStats: categoryStats,
            modelStats: modelStats,
            circuitBreakerStats: cbStats,
            workflowNodeStats: workflowStats,
            totalTracesInWindow: totalTraces
        )
    }

    /// Convenience: last N days ending now.
    func snapshot(lastDays: Int = 7, profileType: String? = nil) -> MetricsSnapshot {
        let until = Date()
        let since = until.addingTimeInterval(-Double(lastDays) * 86_400)
        return snapshot(since: since, until: until, profileType: profileType)
    }

    // MARK: - Individual accessors (for views that need one panel)

    func toolReliability(since: Date, until: Date = Date()) -> [ToolReliabilityStats] {
        (try? store?.toolReliabilityStats(since: since, until: until)) ?? []
    }

    func categoryFrequency(since: Date, until: Date = Date()) -> [CategoryFrequencyStats] {
        (try? store?.categoryFrequencyStats(since: since, until: until)) ?? []
    }

    func modelReliability(since: Date, until: Date = Date()) -> [ModelReliabilityStats] {
        (try? store?.modelReliabilityStats(since: since, until: until)) ?? []
    }

    func circuitBreaker(since: Date, until: Date = Date()) -> CircuitBreakerStats {
        (try? store?.circuitBreakerStatsAggregate(since: since, until: until))
            ?? CircuitBreakerStats(totalTrips: 0, tripsByCategory: [:], topOffendingTools: [],
                                   windowStart: since, windowEnd: until)
    }

    // MARK: - Empty fallback

    private static func empty(since: Date, until: Date) -> MetricsSnapshot {
        MetricsSnapshot(
            generatedAt: Date(),
            windowStart: since,
            windowEnd: until,
            toolStats: [],
            categoryStats: [],
            modelStats: [],
            circuitBreakerStats: CircuitBreakerStats(totalTrips: 0, tripsByCategory: [:],
                                                     topOffendingTools: [],
                                                     windowStart: since, windowEnd: until),
            workflowNodeStats: [],
            totalTracesInWindow: 0
        )
    }
}
