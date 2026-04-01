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
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
            } else if let error = viewModel.error {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(theme.errorColor)
                    Text(error)
                        .font(.system(size: 13))
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
                .pickerStyle(.menu)
                .frame(width: 160)

                Toggle("Debug", isOn: $viewModel.showDebugEvents)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Button(action: onExport) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Filter chips row
            HStack(spacing: 6) {
                ForEach(EventTypeFilter.allCases) { filter in
                    filterChip(filter)
                }
                Spacer()

                // Event count
                Text("\(viewModel.visibleEvents.count) events")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private func filterChip(_ filter: EventTypeFilter) -> some View {
        let isActive = viewModel.activeEventFilter == filter
        let chipColor: Color = {
            if !isActive { return theme.secondaryText }
            switch filter {
            case .all: return theme.accentColor
            case .thoughts: return .blue
            case .tools: return .orange
            case .llm: return .purple
            case .errors: return theme.errorColor
            }
        }()

        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                viewModel.activeEventFilter = filter
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: filter.icon)
                    .font(.system(size: 9))
                Text(filter.rawValue)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(chipColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? chipColor.opacity(0.12) : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isActive ? chipColor.opacity(0.3) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 12))
                    .foregroundStyle(theme.errorColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(errors.count) error\(errors.count == 1 ? "" : "s") detected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.errorColor)

                    if let first = errors.first, let content = first.content {
                        Text(content)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text("Show")
                    .font(.system(size: 10, weight: .medium))
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
                    icon: "questionmark.diamond",
                    value: "\(viewModel.summary.hallucinatedTools)",
                    label: "Hallucinated",
                    color: .orange
                )
            }
        }
        .padding(.vertical, 8)
        .background(theme.secondaryBackground.opacity(0.5))
    }

    private func summaryCell(icon: String, value: String, label: String, color: Color? = nil) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(color ?? theme.primaryText)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(width: 1, height: 24)
    }
}
