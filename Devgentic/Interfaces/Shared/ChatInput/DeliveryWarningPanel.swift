// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DeliveryWarningPanel.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Inline, non-blocking warning above the attachment chips: which attachments the model receives only part of or
/// none of, and why. Shared by the main composer and QuickAccess; it stays until the user acts.
struct DeliveryWarningPanel: View {
    let warnings: [DeliveryWarning]

    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.warningColor)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(warnings) { warning in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.fileName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                            Text(warning.problem)
                                .font(.system(size: 11))
                                .foregroundColor(theme.primaryText)
                            Text(warning.reason)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                            Label(warning.suggestion, systemImage: "lightbulb")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warningColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warningColor.opacity(0.3), lineWidth: 0.5))
    }

    private var title: String {
        warnings.count == 1
            ? String(localized: "1 file won't reach the model in full")
            : String(localized: "\(warnings.count) files won't reach the model in full")
    }
}
