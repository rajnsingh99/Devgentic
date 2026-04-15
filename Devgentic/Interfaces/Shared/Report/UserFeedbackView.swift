//
//  UserFeedbackView.swift
//  Devgentic
//
//  Created by Raj Singh on 28/03/26.
//  Simplified feedback view for non-developer users.
//

import SwiftUI

struct UserFeedbackView: View {
    @Bindable var viewModel: ReportViewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var didExport = false
    @FocusState private var isFeedbackFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {

                    // MARK: - Execution Summary Card
                    executionSummaryCard

                    // MARK: - Rating
                    ratingSection

                    // MARK: - Feedback Text
                    feedbackSection

                    // MARK: - Export
                    exportSection
                }
                .padding(24)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
        }
        .background(theme.primaryBackground)
    }

    // MARK: - Execution Summary

    private var executionSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text("EXECUTION SUMMARY")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.5)
            }

            VStack(spacing: 0) {
                // Profile + Status
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.activeTraceRecord?.profileName ?? "Unknown Profile")
                            .font(theme.fontBody.weight(.medium))
                            .foregroundStyle(theme.primaryText)

                        if let model = viewModel.activeTraceRecord?.modelName {
                            Text(model)
                                .font(.system(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }

                    Spacer()

                    statusBadge
                }
                .padding(16)

                Divider().background(theme.dividerColor)

                // Metrics Row
                HStack(spacing: 0) {
                    metricCell(
                        value: "\(viewModel.summary.totalDurationMs)ms",
                        label: "Duration",
                        icon: "clock"
                    )

                    verticalDivider

                    metricCell(
                        value: "\(viewModel.summary.totalToolCalls)",
                        label: "Tools Used",
                        icon: "hammer"
                    )

                    verticalDivider

                    metricCell(
                        value: "\(viewModel.summary.totalIterations)",
                        label: "Steps",
                        icon: "bolt"
                    )

                    if viewModel.summary.parseErrors > 0 {
                        verticalDivider

                        metricCell(
                            value: "\(viewModel.summary.parseErrors)",
                            label: "Errors",
                            icon: "exclamationmark.triangle",
                            color: theme.errorColor
                        )
                    }
                }
                .padding(.vertical, 12)
            }
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var statusBadge: some View {
        let isError = viewModel.activeTraceRecord?.status == .error
        let text = isError ? "Error" : "Completed"
        let color: Color = isError ? theme.errorColor : .green

        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(.caption, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private func metricCell(value: String, label: String, icon: String, color: Color? = nil) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(.caption2))
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced)) // Fixed size: monospaced design
            }
            .foregroundStyle(color ?? theme.primaryText)

            Text(label)
                .font(.system(.caption2))
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(width: 1, height: 28)
    }

    // MARK: - Rating

    private var ratingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text("HOW DID IT GO?")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.5)
            }

            HStack(spacing: 12) {
                ratingButton(
                    rating: .positive,
                    icon: "hand.thumbsup.fill",
                    label: "Good",
                    activeColor: .green
                )

                ratingButton(
                    rating: .negative,
                    icon: "hand.thumbsdown.fill",
                    label: "Needs Work",
                    activeColor: theme.errorColor
                )
            }
        }
    }

    private func ratingButton(rating: FeedbackRating, icon: String, label: String, activeColor: Color) -> some View {
        let isSelected = viewModel.userFeedback.rating == rating

        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                viewModel.userFeedback.rating = isSelected ? nil : rating
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(theme.fontBody)
                Text(label)
                    .font(theme.fontSubheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? activeColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? activeColor.opacity(0.1) : theme.surfaceOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? activeColor.opacity(0.4) : theme.surfaceOverlayStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feedback Text

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text("DETAILS")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .tracking(0.5)
            }

            TextEditor(text: $viewModel.userFeedback.messageText)
                .font(theme.fontSubheadline)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 80, maxHeight: 140)
                .background(theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isFeedbackFocused ? theme.streamingIndicator.opacity(0.45) : theme.dividerColor,
                            lineWidth: 1
                        )
                )
                .focused($isFeedbackFocused)

            Text("Describe what went wrong or what could be improved. This is bundled with the execution trace for debugging.")
                .font(.system(.caption))
                .foregroundStyle(theme.tertiaryText)
                .lineSpacing(2)
        }
    }

    // MARK: - Export

    private var exportSection: some View {
        VStack(spacing: 12) {
            Button {
                exportFeedback()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: didExport ? "checkmark.circle.fill" : "square.and.arrow.up")
                        .font(theme.fontBody)
                    Text(didExport ? "Exported" : "Export Feedback Report")
                        .font(theme.fontSubheadline.weight(.medium))
                }
                .foregroundStyle(didExport ? .green : theme.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(didExport ? theme.successColor.opacity(0.1) : theme.accentColor.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(didExport ? theme.successColor.opacity(0.3) : theme.accentColor.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.activeTraceRecord == nil)

            Text("Exports a JSON file containing the execution trace and your feedback. No personal data is included.")
                .font(.system(.caption))
                .foregroundStyle(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
        }
    }

    // MARK: - Actions

    private func exportFeedback() {
        guard let trace = viewModel.activeTraceRecord else { return }

        if let url = ReportExporter.export(
            trace: trace,
            summary: viewModel.summary,
            isDeveloperMode: false,
            feedback: viewModel.userFeedback
        ) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            withAnimation(.easeInOut(duration: 0.2)) { didExport = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeInOut(duration: 0.2)) { didExport = false }
            }
        }
    }
}
