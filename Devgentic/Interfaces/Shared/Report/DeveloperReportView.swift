//
//  DeveloperReportView.swift
//  Devgentic
//
//  Created by Raj Singh on 28/03/26.
//  Redesigned: error-first banner, event type filter chips, improved density.
//

import SwiftUI

struct DeveloperReportView: View {
    @Bindable var viewModel: ReportViewModel
    @Environment(\.appTheme) private var theme
    let onExport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: scope + filters
            toolbar

            Divider().background(theme.dividerColor)

            // Error banner (only when errors exist)
            if !viewModel.isLoading, !viewModel.errorEvents.isEmpty {
                errorBanner
            }

            // Main content
            if viewModel.isLoading {
                Spacer()
                ProgressView("Loading trace data...")
                    .font(theme.fontSubheadline)
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            } else if let error = viewModel.error {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(theme.errorColor)
                    Text(error)
                        .font(theme.fontSubheadline)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
            } else {
                HSplitView {
                    SpanTreeView(
                        spans: viewModel.visibleSpans,
                        selectedSpanID: $viewModel.selectedSpanID
                    )
                    .frame(minWidth: 220, idealWidth: 280)

                    if viewModel.isEventsLoading {
                        VStack {
                            Spacer()
                            ProgressView("Fetching events...")
                                .controlSize(.small)
                            Spacer()
                        }
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EventTimelineView(events: viewModel.visibleEvents)
                            .frame(minWidth: 350, idealWidth: 520)
                    }
                }
            }

            // Footer summary
            if !viewModel.isLoading, viewModel.activeTraceRecord != nil {
                Divider().background(theme.dividerColor)
                footerSummary
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 8) {
            // Top row: scope + export
            HStack(spacing: 12) {
                Picker("Scope", selection: $viewModel.scope) {
                    ForEach(ReportScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 380)

                Toggle("Debug", isOn: $viewModel.showDebugEvents)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Button(action: onExport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(.caption, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accentColor)
                .controlSize(.small)
            }

            // Filter chips row
            HStack(spacing: 6) {
                ForEach(EventTypeFilter.allCases) { filter in
                    FilterChipView(filter: filter, viewModel: viewModel, theme: theme)
                }
                Spacer()

                // Event count
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9))
                    Text("\(viewModel.visibleEvents.count) events")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.surfaceOverlay)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                theme.secondaryBackground.opacity(0.7)
                if let nsVisualEffectView = NSClassFromString("NSVisualEffectView") {
                    LinearGradient(
                        colors: [theme.primaryBackground.opacity(0.05), theme.secondaryBackground.opacity(0.2)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        )
        .overlay(
            Rectangle()
                .fill(theme.dividerColor.opacity(0.5))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Error Banner

    private var errorBanner: some View {
        let errors = viewModel.errorEvents

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.activeEventFilter = .errors
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.caption))
                    .foregroundStyle(theme.errorColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(errors.count) error\(errors.count == 1 ? "" : "s") detected")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(theme.errorColor)

                    if let first = errors.first, let content = first.content {
                        Text(content)
                            .font(.system(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text("Show")
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(theme.errorColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.errorColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.errorColor.opacity(0.04))
            .overlay(
                Rectangle()
                    .fill(theme.errorColor.opacity(0.3))
                    .frame(height: 0.5),
                alignment: .bottom
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer Summary

    private var footerSummary: some View {
        HStack(spacing: 0) {
            summaryCell(icon: "clock", value: DurationFormat.format(ms: viewModel.summary.totalDurationMs), label: "Duration")
            verticalDivider
            summaryCell(icon: "bolt", value: "\(viewModel.summary.totalIterations)", label: "Steps")
            verticalDivider
            summaryCell(icon: "brain", value: "\(viewModel.summary.totalLLMCalls)", label: "LLM")
            verticalDivider
            summaryCell(icon: "hammer", value: "\(viewModel.summary.totalToolCalls)", label: "Tools")
            verticalDivider
            summaryCell(
                icon: "exclamationmark.triangle",
                value: "\(viewModel.summary.parseErrors)",
                label: "Errors",
                color: viewModel.summary.parseErrors > 0 ? theme.errorColor : nil
            )

            if viewModel.summary.hallucinatedTools > 0 {
                verticalDivider
                summaryCell(
                    icon: "questionmark.diamond.fill",
                    value: "\(viewModel.summary.hallucinatedTools)",
                    label: "Hallucinated",
                    color: .orange
                )
            }
        }
        .padding(.vertical, 12)
        .background(
            ZStack {
                theme.secondaryBackground.opacity(0.7)
                LinearGradient(
                    colors: [theme.secondaryBackground.opacity(0.2), theme.primaryBackground.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .overlay(
            Rectangle()
                .fill(theme.dividerColor.opacity(0.5))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func summaryCell(icon: String, value: String, label: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9)) // Fixed size: badge chip ≤9pt
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)) // Fixed size: monospaced design
            }
            .foregroundStyle(color ?? theme.primaryText)

            Text(label)
                .font(.system(size: 9)) // Fixed size: badge chip ≤9pt
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(width: 1, height: 28)
    }
}

// MARK: - Premium Filter Chip View
private struct FilterChipView: View {
    let filter: EventTypeFilter
    @Bindable var viewModel: ReportViewModel
    let theme: any Theme
    
    @State private var isHovering = false
    
    private var isActive: Bool {
        viewModel.activeEventFilter == filter
    }
    
    private var chipColor: Color {
        if !isActive && !isHovering { return theme.secondaryText }
        switch filter {
        case .all: return theme.accentColor
        case .thoughts: return .blue
        case .tools: return .orange
        case .llm: return .purple
        case .errors: return theme.errorColor
        }
    }
    
    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                viewModel.activeEventFilter = filter
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.icon)
                    .font(.system(size: 10))
                Text(filter.rawValue)
                    .font(.system(.caption, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? .white : chipColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                ZStack {
                    if isActive {
                        chipColor
                    } else {
                        theme.surfaceOverlay
                        if isHovering {
                            chipColor.opacity(0.1)
                        }
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isActive ? chipColor.opacity(0.5) : (isHovering ? chipColor.opacity(0.3) : theme.dividerColor.opacity(0.5)), lineWidth: 1)
            )
            .scaleEffect(isHovering && !isActive ? 1.02 : 1.0)
            .shadow(color: isActive ? chipColor.opacity(0.3) : .clear, radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hover
            }
        }
    }
}
