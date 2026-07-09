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

    /// Callback to trigger when the view wants to close (for custom popovers)
    let onClose: (() -> Void)?

    init(messageID: UUID, conversationID: UUID, traceID: String?, onClose: (() -> Void)? = nil) {
        self.onClose = onClose
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
            minWidth: isDeveloperMode ? 850 : 500,
            idealWidth: isDeveloperMode ? 1000 : 550,
            maxWidth: .infinity,
            minHeight: isDeveloperMode ? 500 : 450,
            idealHeight: isDeveloperMode ? 700 : 550,
            maxHeight: .infinity
        )
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [theme.dividerColor, theme.dividerColor.opacity(0.3)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1.5
                )
        )
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
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(theme.primaryText)

                if let profileName = viewModel.activeTraceRecord?.profileName {
                    Text(profileName)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }

            Spacer()

            // Mode indicator pill
            HStack(spacing: 6) {
                Image(systemName: isDeveloperMode ? "hammer.fill" : "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(isDeveloperMode ? "Developer" : "User")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(isDeveloperMode ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isDeveloperMode ? theme.accentColor.opacity(0.15) : theme.surfaceOverlayStrong)
            )
            .overlay(
                Capsule()
                    .stroke(isDeveloperMode ? theme.accentColor.opacity(0.3) : theme.dividerColor, lineWidth: 1)
            )
            .padding(.trailing, 8)

            Button(action: { onClose?() ?? dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(theme.surfaceOverlayStrong)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(theme.dividerColor, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            ZStack {
                theme.secondaryBackground.opacity(0.6)
                if let nsVisualEffectView = NSClassFromString("NSVisualEffectView") {
                    // For macOS a glass effect can be nice, but since we can't easily bridge here without AppKit,
                    // we'll rely on our theme's translucent layer plus a linear gradient.
                    LinearGradient(
                        colors: [theme.primaryBackground.opacity(0.1), theme.secondaryBackground.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        )
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
