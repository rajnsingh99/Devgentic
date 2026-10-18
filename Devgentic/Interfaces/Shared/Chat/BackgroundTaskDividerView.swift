// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTaskDividerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// How a turn nobody typed appears in the transcript: a centered divider saying a background task ended, showing the
/// stub text verbatim. The stub is the authoritative record (built from the registry snapshot at wake time); it is
/// not re-derived from the model's report.
struct BackgroundTaskDividerView: View {

    let message: ChatMessage

    @Environment(\.appTheme) private var theme

    /// The stub text, or a neutral fallback if the row's content is unreadable; a divider with no words still keeps the
    /// turn structure legible.
    private var label: String {
        guard let text = message.content.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return String(localized: "A background task finished.")
        }
        return text
    }

    private var timestamp: String {
        message.timestamp.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(spacing: theme.spacingSmall) {
            rule
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .semibold))   // Fixed size: inline marker
                Text(label)
                Text("·")
                Text(timestamp)
            }
            .font(theme.fontCaption)
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            rule
        }
        .padding(.horizontal, theme.spacingMedium)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // One element to VoiceOver, not five fragments — `label` already reads as a sentence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) At \(timestamp).")
    }

    private var rule: some View {
        Rectangle()
            .fill(theme.dividerColor)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}
