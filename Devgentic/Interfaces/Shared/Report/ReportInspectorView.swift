//
//  ReportInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Redesigned: dual-view dispatch based on Developer Mode toggle.
//

import SwiftUI

struct ReportInspectorView: View {
    @State private var viewModel: ReportViewModel
    @AppStorage(AppSettings.developerModeKey) private var isDeveloperMode: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    /// Phase F: controls presentation of the diagnostic bundle export sheet.
    /// Triggered from the export button in DeveloperReportView (full-includes preset)
    /// and UserFeedbackView (`.userReport` preset + the entered feedback).
    @State private var showBundleExport: Bool = false

    /// Feedback to attach to the next bundle export. Set by the user-feedback path;
    /// nil for the developer path (which uses the full-includes preset).
    @State private var pendingExportFeedback: UserFeedback?

    init(messageID: UUID, conversationID: UUID, traceID: String?) {
        _viewModel = State(initialValue: ReportViewModel(
            messageID: messageID,
            conversationID: conversationID,
            traceID: traceID
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Shared header
            header

            Divider().background(theme.dividerColor)

            // Mode-dispatched content
            if isDeveloperMode {
                DeveloperReportView(viewModel: viewModel, onExport: exportDeveloperReport)
            } else {
                UserFeedbackView(viewModel: viewModel, onExport: exportUserFeedback)
            }
        }
        .frame(
            minWidth: isDeveloperMode ? 700 : 420,
            minHeight: isDeveloperMode ? 400 : 340
        )
        .background(theme.primaryBackground)
        .task {
            await viewModel.loadData()
        }
        .sheet(isPresented: $showBundleExport) {
            if let traceID = viewModel.activeTraceRecord?.traceID {
                BundleExportSheet(
                    defaultScope: .trace(traceID: traceID),
                    feedback: pendingExportFeedback
                )
            }
        }
    }

    // MARK: - Shared Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(isDeveloperMode ? "Execution Trace" : "Feedback")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(theme.primaryText)

                if let profileName = viewModel.activeTraceRecord?.profileName {
                    Text(profileName)
                        .font(.system(.caption))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer()

            // Mode indicator pill
            HStack(spacing: 4) {
                Image(systemName: isDeveloperMode ? "hammer.fill" : "person.fill")
                    .font(.system(size: 9)) // Fixed size: badge chip ≤9pt
                Text(isDeveloperMode ? "Developer" : "User")
                    .font(.system(.caption2, weight: .medium))
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(theme.surfaceOverlay)
            .clipShape(Capsule())

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 22, height: 22)
                    .background(theme.secondaryBackground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Export

    /// Phase F handoff — the export button now opens the configurable bundle
    /// sheet instead of producing a single trace.json. Keeping the function
    /// name so the call site in DeveloperReportView doesn't change, but the
    /// behavior is upgraded.
    private func exportDeveloperReport() {
        guard viewModel.activeTraceRecord != nil else { return }
        pendingExportFeedback = nil          // developer path → full-includes preset
        showBundleExport = true
    }

    /// User-feedback path → the same sanitized bundle engine, preset to `.userReport`
    /// and carrying the rating + message the user just entered. Replaces the deleted
    /// `ReportExporter`, which wrote UNsanitized JSON despite the UI's "no personal data"
    /// claim (Gaps #2, #3).
    private func exportUserFeedback() {
        guard viewModel.activeTraceRecord != nil else { return }
        pendingExportFeedback = viewModel.userFeedback
        showBundleExport = true
    }
}
