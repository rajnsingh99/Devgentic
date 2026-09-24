// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
        RunReportView(
            messageID: messageID,
            conversationID: conversationID,
            traceID: traceID,
            answerPreview: answerPreview,
            onClose: { onClose?() ?? dismiss() }
        ) { feedback in
            pendingExportFeedback = feedback
            showBundleExport = true
        }
        .frame(minWidth: 850, idealWidth: 1000, maxWidth: .infinity,
               minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.dividerColor.opacity(0.4), theme.dividerColor.opacity(0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
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
}
