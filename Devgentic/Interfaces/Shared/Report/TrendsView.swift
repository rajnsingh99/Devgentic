// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TrendsView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import Charts

/// The observability dashboard with four panels: tool reliability, error categories, model reliability, circuit breaker.
/// Gated behind developer mode: with it off the tab explains there is no data yet rather than showing empty charts.
/// The window defaults to the last 7 days; the picker offers 1 / 7 / 30 (30 matches the retention policy).
struct TrendsView: View {

    @Environment(\.appTheme) private var theme
    @AppStorage(AppSettings.developerModeKey) private var isDeveloperMode: Bool = false

    @State private var window: Window = .sevenDays
    @State private var profileFilter: ProfileFilter = .all
    @State private var snapshot: MetricsSnapshot?
    @State private var isLoading: Bool = false

    enum Window: String, CaseIterable, Identifiable {
        case oneDay = "24h"
        case sevenDays = "7d"
        case thirtyDays = "30d"
        var id: String { rawValue }
        var days: Int {
            switch self {
            case .oneDay: return 1
            case .sevenDays: return 7
            case .thirtyDays: return 30
            }
        }

        // Why: `Text(x.rawValue)` binds to the non-localizing `StringProtocol` overload and is invisible to the String Catalog.
        /// User-facing name, separate from `rawValue`, which is for `id` and logging only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .oneDay:     return "24h"
            case .sevenDays:  return "7d"
            case .thirtyDays: return "30d"
            }
        }
    }

    /// Profile-type filter for the dashboard. Raw values match the `ProfileType`
    /// rawValues stored in `traces.profileType` so SQL filter passes through as
    /// a string. `.all` means "no filter — aggregate every profile type".
    enum ProfileFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case bot = "Bot"
        case agent = "Agent"
        case workflow = "Workflow"
        case code = "Code"
        case imageGen = "ImageGen"
        var id: String { rawValue }

        // Why: a persistence/wire value matching `traces.profileType` rows written by `ProfileType.rawValue`; never rename a case.
        /// The string passed to MetricsAggregator; nil for `.all`.
        var sqlValue: String? { self == .all ? nil : rawValue }

        // Why: `Text(x.rawValue)` binds to the non-localizing `StringProtocol` overload and is invisible to the String Catalog.
        /// User-facing name, separate from `rawValue`, which is for the SQL filter, `id` and logging only.
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .all:       return "All"
            case .bot:       return "Bot"
            case .agent:     return "Agent"
            case .workflow:  return "Workflow"
            case .code:      return "Code"
            case .imageGen:  return "ImageGen"
            }
        }
    }

    var body: some View {
        Group {
            if !isDeveloperMode {
                devModeOffState
            } else {
                dashboardContent
            }
        }
        .task { await load() }
        .onChange(of: window) { _, _ in
            Task { await load() }
        }
        .onChange(of: profileFilter) { _, _ in
            Task { await load() }
        }
    }

    // MARK: - Dev-mode-off placeholder

    private var devModeOffState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 36))
                .foregroundColor(theme.tertiaryText)
            Text("Trends dashboard is a developer-mode feature")
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.secondaryText)
            Text("Enable Developer Mode in Settings → General to start capturing the data this view needs.")
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Dashboard

    @ViewBuilder
    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let snap = snapshot, snap.totalTracesInWindow == 0 {
                    emptyDataState
                } else {
                    toolReliabilitySection
                    categoryFrequencySection
                    modelReliabilitySection
                    circuitBreakerSection
                    // Workflow Activity is hidden when the user scoped to a non-workflow profile type (the panel would be empty);
                    // otherwise it is shown whenever there are workflow nodes to report.
                    if showWorkflowActivity {
                        workflowActivitySection
                    }
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Trends")
                .font(.title2).bold()
                .foregroundColor(theme.primaryText)

            if let snap = snapshot {
                Text("\(snap.totalTracesInWindow) trace\(snap.totalTracesInWindow == 1 ? "" : "s") in window")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Profile-type filter driving `MetricsAggregator.snapshot(profileType:)`: `.all` (default) is unfiltered; anything
            // else scopes every panel to traces of the selected profile type.
            Picker("", selection: $profileFilter) {
                ForEach(ProfileFilter.allCases) { p in
                    Text(p.localizedTitle).tag(p)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 110)

            Picker("", selection: $window) {
                ForEach(Window.allCases) { w in
                    Text(w.localizedTitle).tag(w)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    private var emptyDataState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundColor(theme.tertiaryText)
            Text("No traces in window")
                .font(theme.fontSubheadline.weight(.medium))
                .foregroundColor(theme.secondaryText)
            Text("Send a message in any mode to populate the dashboard.")
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tool Reliability

    @ViewBuilder
    private var toolReliabilitySection: some View {
        sectionCard(title: "Tool Reliability", subtitle: "Per-tool success rate and latency") {
            if let stats = snapshot?.toolStats, !stats.isEmpty {
                let displayed = Array(stats.prefix(10))

                Chart(displayed) { stat in
                    BarMark(
                        x: .value("Tool", stat.toolName),
                        y: .value("Calls", stat.totalCalls)
                    )
                    .foregroundStyle(by: .value("Outcome", stat.successRate >= 0.8 ? "High" : (stat.successRate >= 0.5 ? "Mid" : "Low")))
                }
                .chartForegroundStyleScale([
                    "High": Color.green.opacity(0.7),
                    "Mid": Color.orange.opacity(0.7),
                    "Low": Color.red.opacity(0.7)
                ])
                .chartXAxis { AxisMarks(preset: .automatic) { value in
                    AxisValueLabel(horizontalSpacing: 4) {
                        if let name = value.as(String.self) {
                            Text(name).font(.caption2).rotationEffect(.degrees(-35))
                        }
                    }
                }}
                .frame(height: 180)

                ToolStatsTable(stats: displayed)
            } else {
                Text("No tool calls recorded.")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Category Frequency

    @ViewBuilder
    private var categoryFrequencySection: some View {
        sectionCard(title: "Error & Warning Frequency", subtitle: "Incidents by canonical category") {
            if let stats = snapshot?.categoryStats, !stats.isEmpty {
                Chart(stats) { stat in
                    BarMark(
                        x: .value("Count", stat.count),
                        y: .value("Category", stat.displayName)
                    )
                    .foregroundStyle(color(for: stat.severity))
                }
                .frame(height: CGFloat(min(stats.count * 22 + 40, 400)))

                PhaseSummaryRow(stats: stats)
            } else {
                Text("No classified errors in window — nothing hit the taxonomy.")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Model Reliability

    @ViewBuilder
    private var modelReliabilitySection: some View {
        sectionCard(title: "Model Reliability", subtitle: "Per-(provider, model) run outcomes") {
            if let stats = snapshot?.modelStats, !stats.isEmpty {
                ModelStatsTable(stats: stats)
            } else {
                Text("No runs in window.")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Workflow Activity

    /// Whether the Workflow Activity panel is relevant for the current filter. A non-workflow profile type yields empty
    /// `workflowNodeStats` (`MetricsAggregator` skips the query), so the section is hidden; `.all` and `.workflow` keep it.
    private var showWorkflowActivity: Bool {
        switch profileFilter {
        case .all, .workflow: return true
        default: return false
        }
    }

    @ViewBuilder
    private var workflowActivitySection: some View {
        sectionCard(
            title: "Workflow Activity",
            subtitle: "Per-node success rate and latency across workflow runs"
        ) {
            if let stats = snapshot?.workflowNodeStats, !stats.isEmpty {
                WorkflowNodeStatsTable(stats: Array(stats.prefix(20)))
            } else {
                Text("No workflow nodes executed in window.")
                    .font(.caption)
                    .foregroundColor(theme.tertiaryText)
            }
        }
    }

    // MARK: - Circuit Breaker

    @ViewBuilder
    private var circuitBreakerSection: some View {
        sectionCard(title: "Circuit Breaker", subtitle: "Safety trips — \(snapshot?.circuitBreakerStats.totalTrips ?? 0) total") {
            if let cb = snapshot?.circuitBreakerStats, cb.totalTrips > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(cb.tripsByCategory.keys.sorted { $0.rawValue < $1.rawValue }), id: \.self) { cat in
                        HStack {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(cat.displayName)
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                            Text("\(cb.tripsByCategory[cat] ?? 0)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(theme.primaryText)
                        }
                    }
                    if !cb.topOffendingTools.isEmpty {
                        Divider().padding(.vertical, 4)
                        Text("Top offending tools")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(theme.secondaryText)
                        ForEach(cb.topOffendingTools, id: \.tool) { entry in
                            HStack {
                                Text(entry.tool)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(theme.tertiaryText)
                            }
                        }
                    }
                }
            } else {
                Text("No circuit-breaker trips in window — healthy.")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }

    // MARK: - Section card shell

    @ViewBuilder
    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(theme.fontSubheadline.weight(.semibold))
                .foregroundColor(theme.primaryText)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(theme.tertiaryText)
            content()
                .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceOverlay.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.tertiaryText.opacity(0.15), lineWidth: 0.5)
        )
    }

    // MARK: - Load

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let days = window.days
        let profileTypeSQL = profileFilter.sqlValue
        // MetricsAggregator is Sendable + reads only — safe to call from background.
        let snap = await Task.detached(priority: .userInitiated) {
            MetricsAggregator.shared.snapshot(lastDays: days, profileType: profileTypeSQL)
        }.value
        snapshot = snap
    }

    // MARK: - Color helpers

    private func color(for severity: ErrorSeverity) -> Color {
        switch severity {
        case .informational: return .yellow.opacity(0.7)
        case .recoverable:   return .orange.opacity(0.75)
        case .fatal:         return .red.opacity(0.75)
        }
    }
}

// MARK: - Tool stats table row

private struct ToolStatsTable: View {
    let stats: [ToolReliabilityStats]
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tool").bold().frame(maxWidth: .infinity, alignment: .leading)
                Text("Calls").bold().frame(width: 60, alignment: .trailing)
                Text("Success").bold().frame(width: 70, alignment: .trailing)
                Text("p50").bold().frame(width: 60, alignment: .trailing)
                Text("p95").bold().frame(width: 60, alignment: .trailing)
            }
            .font(.caption)
            .foregroundColor(theme.secondaryText)
            Divider()

            ForEach(stats) { stat in
                HStack {
                    Text(stat.toolName)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text("\(stat.totalCalls)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.0f%%", stat.successRate * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(stat.successRate >= 0.8 ? .green : (stat.successRate >= 0.5 ? .orange : .red))
                    Text(stat.p50DurationMs.map { "\($0)ms" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 60, alignment: .trailing)
                    Text(stat.p95DurationMs.map { "\($0)ms" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Model stats table

private struct ModelStatsTable: View {
    let stats: [ModelReliabilityStats]
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Provider/Model").bold().frame(maxWidth: .infinity, alignment: .leading)
                Text("Runs").bold().frame(width: 60, alignment: .trailing)
                Text("Success").bold().frame(width: 70, alignment: .trailing)
                Text("Avg").bold().frame(width: 70, alignment: .trailing)
            }
            .font(.caption)
            .foregroundColor(theme.secondaryText)
            Divider()

            ForEach(stats) { stat in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.modelName)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Text(stat.provider)
                            .font(.caption2)
                            .foregroundColor(theme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(stat.totalRuns)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.0f%%", stat.successRate * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(stat.successRate >= 0.8 ? .green : (stat.successRate >= 0.5 ? .orange : .red))
                    Text(stat.avgDurationMs.map { "\($0 / 1000)s" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Workflow node stats table

/// Per-workflow-node aggregate table: one row per node name across every workflow run with a `workflowNode` span.
/// Mirrors `ToolStatsTable`'s style so the reliability surfaces read as one family.
private struct WorkflowNodeStatsTable: View {
    let stats: [WorkflowNodeStats]
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Node").bold().frame(maxWidth: .infinity, alignment: .leading)
                Text("Runs").bold().frame(width: 60, alignment: .trailing)
                Text("Success").bold().frame(width: 70, alignment: .trailing)
                Text("p50").bold().frame(width: 70, alignment: .trailing)
                Text("p95").bold().frame(width: 70, alignment: .trailing)
            }
            .font(.caption)
            .foregroundColor(theme.secondaryText)
            Divider()

            ForEach(stats) { stat in
                HStack {
                    Text(stat.nodeName)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(1)
                    Text("\(stat.totalRuns)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                    // Shows "—" when the node has no verdict yet (every run stopped, skipped or in flight): 0% would say the node is
                    // broken. Matches how p50/p95 below render an absent value.
                    Text(stat.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(.caption.monospacedDigit())
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(stat.successRate.map { $0 >= 0.8 ? .green : ($0 >= 0.5 ? .orange : .red) } ?? theme.tertiaryText)
                    Text(stat.p50DurationMs.map(formatMs) ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 70, alignment: .trailing)
                    Text(stat.p95DurationMs.map(formatMs) ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    /// Mixed-unit formatting: sub-second values render as ms, multi-second as
    /// rounded seconds. Node durations span a wide range (a Code-node template
    /// transform is ~5 ms; an Agent-node multi-iteration loop is ~60 s).
    private func formatMs(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms)ms" }
        return "\(Int((Double(ms) / 1000).rounded()))s"
    }
}

// MARK: - Phase summary row

/// Compact strip below the category bar chart showing total counts per phase
/// (parsing / tooling / llm / etc.). Helps answer "where is the agent struggling
/// most" at a glance without scanning all 46 categories.
private struct PhaseSummaryRow: View {
    let stats: [CategoryFrequencyStats]
    @Environment(\.appTheme) private var theme

    private var byPhase: [ExecutionPhase: Int] {
        var dict: [ExecutionPhase: Int] = [:]
        for stat in stats {
            dict[stat.phase, default: 0] += stat.count
        }
        return dict
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ExecutionPhase.allCases, id: \.self) { phase in
                if let count = byPhase[phase], count > 0 {
                    HStack(spacing: 4) {
                        Circle().frame(width: 6, height: 6).foregroundColor(color(for: phase))
                        // Composition, not substitution: `Text("\(phase.localizedTitle)")` would collapse the key into a plain String and lose
                        // localization. `verbatim` because ": %lld" is a punctuation fragment, not a translatable phrase.
                        (Text(phase.localizedTitle) + Text(verbatim: ": \(count)"))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(theme.secondaryText)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func color(for phase: ExecutionPhase) -> Color {
        switch phase {
        case .parsing:    return .purple
        case .llm:        return .blue
        case .tooling:    return .green
        case .capability: return .teal
        case .memory:     return .yellow
        case .workflow:   return .pink
        case .session:    return .gray
        }
    }
}

// MARK: - ExecutionPhase display name

// Why: `rawValue` is a storage key that can never be renamed, and `Text(x.rawValue)` is invisible to the
// String Catalog.
/// Localized, capitalised phrases for the phase chips, instead of echoing the lowercase storage token (`parsing`, `llm`).
/// Declared here, not on the enum: `ExecutionPhase` lives in `Observaliblity/` (Foundation + GRDB), not SwiftUI.
private extension ExecutionPhase {
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .parsing:    return "Parsing"
        case .llm:        return "LLM"
        case .tooling:    return "Tooling"
        case .capability: return "Capability"
        case .memory:     return "Memory"
        case .workflow:   return "Workflow"
        case .session:    return "Session"
        }
    }
}
