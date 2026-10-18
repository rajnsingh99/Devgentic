// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SaveAdvisoryBanner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// The banner that surfaces `ProfileValidationError.Severity.advisory` results after a save.
/// Shown after a save, not continuously: advisories describe likely-degraded behaviour, not a fault; it is dismissible
/// and clears on the next save. Warning colour, never error colour: the save succeeded.
struct SaveAdvisoryBanner: View {
    let advisories: [ProfileValidationError]
    let onDismiss: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        if !advisories.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(theme.fontCaption)
                        .foregroundColor(theme.warningColor)
                        .accessibilityHidden(true)

                    Text(advisories.count == 1
                         ? "Saved — one thing worth knowing"
                         : "Saved — \(advisories.count) things worth knowing")
                        .font(theme.fontSubheadline.weight(.medium))
                        .foregroundColor(theme.primaryText)

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(theme.fontCaption2)
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }

                ForEach(advisories) { advisory in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .accessibilityHidden(true)
                        Text(advisory.message)
                            .font(theme.fontCaption)
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.warningColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.warningColor.opacity(0.25), lineWidth: 0.5)
            )
            .frame(maxWidth: ViewLayout.maxContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saved with \(advisories.count) advisory note(s)")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
