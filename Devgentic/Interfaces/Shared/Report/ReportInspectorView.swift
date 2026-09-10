// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ReportInspectorView.swift
//  Devgentic
//
//  Created by Raj Singh on 19/03/26.
//  Redesigned 2026-08-22: hosts the unified RunReportView — ONE report for every
//  user and every profile type. The old Developer/User fork (DeveloperReportView /
//  UserFeedbackView) is superseded; density is a toggle inside the report, feedback
//  and export live inside it too.
//

import SwiftUI

struct ReportInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme

    let messageID: UUID
    let conversationID: UUID
    let traceID: String?
    /// The assistant message's prose, passed by the opening bubble so the ANSWER row
    /// shows full text without a cross-store fetch.
    let answerPreview: String?
    /// Callback to trigger when the view wants to close (for custom popovers)
    let onClose: (() -> Void)?

    /// Controls presentation of the sanitized diagnostic-bundle export sheet.
    @State private var showBundleExport: Bool = false
    /// Feedback captured inside the report at the moment Export was pressed.
    @State private var pendingExportFeedback: UserFeedback?

    init(messageID: UUID, conversationID: UUID, traceID: String?,
         answerPreview: String? = nil, onClose: (() -> Void)? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.traceID = traceID
        self.answerPreview = answerPreview
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.dividerColor)
            RunReportView(
                messageID: messageID,
                conversationID: conversationID,
                traceID: traceID,
                answerPreview: answerPreview
            ) { feedback in
                pendingExportFeedback = feedback
                showBundleExport = true
            }
        }
        .frame(minWidth: 850, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 520, idealHeight: 700, maxHeight: .infinity)
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
        .sheet(isPresented: $showBundleExport) {
            if let traceID {
                BundleExportSheet(
                    defaultScope: .trace(traceID: traceID),
                    feedback: pendingExportFeedback
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Run Report")
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(theme.primaryText)

            Spacer()

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
        .padding(.vertical, 14)
        .background(theme.secondaryBackground.opacity(0.6))
    }
}
