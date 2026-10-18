// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ErrorMessageView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Error card for agent, image and media failures; announces itself to VoiceOver and offers a copy-whole-error action.
struct ErrorMessageView: View {
    let title: String?
    let details: String
    /// Structured error category — drives the icon. `nil` for legacy/un-categorized
    /// errors (renders the generic octagon), so existing callers are unaffected.
    var category: AgentErrorCategory? = nil
    /// Optional actionable remediation ("try re-attaching the file"). Rendered as a
    /// distinct lightbulb line below the details when present.
    var suggestion: String? = nil
    /// Identity for the VoiceOver repeat-suppression window, when the caller has one.
    /// Without one, suppression keys on the sentence, which silences a new failure that reads the same.
    /// Callers that can tell occurrences apart (artifact id plus attempt counter) pass one.
    var announcementKey: String? = nil
    @Environment(\.appTheme) private var theme
    @Environment(ThemeManager.self) private var themeManager

    /// SF Symbol chosen by category so a file/doc/image failure reads at a glance,
    /// falling back to the generic error octagon for everything else.
    private var iconName: String {
        switch category {
        case .fileNotFound:                                  return "doc.questionmark"
        case .fileAccessDenied, .documentPasswordProtected:  return "lock.doc"
        case .fileTooLarge:                                  return "doc.badge.ellipsis"
        case .fileReadFailed, .documentExtractionFailed, .documentCorrupted:
            return "doc.badge.exclamationmark"
        case .imageResolutionFailed:                         return "photo.badge.exclamationmark"
        default:                                             return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundColor(theme.errorColor)
                .padding(.top, 2) // Align icon nicely with text

            VStack(alignment: .leading, spacing: 4) {
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: themeManager.chatFontSize + 1, weight: .semibold))
                        .bold()
                        .foregroundColor(theme.errorColor.opacity(0.95))
                }
                Text(details)
                    // `theme.fontBody` is a fixed size, so the chat font keeps error text readable when chat text is scaled up.
                    .font(themeManager.chatFont)
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .textSelection(.enabled) 

                if let suggestion = suggestion, !suggestion.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lightbulb.fill")
                            .font(.callout)
                            .foregroundColor(theme.accentColor.opacity(0.9))
                        Text(suggestion)
                            .font(.system(size: max(10, themeManager.chatFontSize - 2)))
                            .foregroundColor(theme.secondaryText.opacity(0.9))
                            .textSelection(.enabled)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.errorColor.opacity(0.12), theme.errorColor.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.errorColor.opacity(0.25), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription)
        .accessibilityAddTraits(.isStaticText)
        // Why: `.task(id:)` fires on appearance and the transcript is a LazyVStack, so rebuilds would re-announce old errors.
        // Announce politely, once per error: the card may sit far from the VoiceOver cursor.
        // Keyed on `announcementKey` or the sentence, so a view rebuild never re-speaks an old failure.
        .task(id: announcementKey ?? spokenDescription) {
            AccessibilityAnnouncer.announceOnce(spokenDescription,
                                                key: announcementKey ?? spokenDescription,
                                                urgency: .polite)
        }
        // One-click copy of the whole error for a bug report; lives here so every consumer (agent, image, media errors)
        // inherits it.
        .contextMenu {
            Button(action: copyError) {
                Label("Copy Error", systemImage: "doc.on.doc")
            }
        }
        .accessibilityAction(named: "Copy error") { copyError() }
    }

    /// One string for both the label and the announcement — they must never drift.
    private var spokenDescription: String {
        let base = String(localized: "Error: \(title ?? String(localized: "Unknown")). \(details)")
        let hint = suggestion.map { String(localized: ". Suggestion: \($0)") } ?? ""
        return base + hint
    }

    /// Clipboard form: structured lines, not the spoken sentence.
    private func copyError() {
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        lines.append(details)
        if let suggestion, !suggestion.isEmpty { lines.append("Suggestion: \(suggestion)") }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Preview Provider
struct ErrorMessageView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 15) {
            ErrorMessageView(
                title: "Connection Error",
                details: "Could not connect to the server (ollama). Check if it's running and the URL/Port is correct."
            )

            ErrorMessageView(
                title: nil, // Test without title
                details: "An unknown error occurred during processing."
            )

             ErrorMessageView(
                 title: "API Error",
                 details: "Bad server response (404)."
             )
        }
        .padding()
        // Simulate bubble appearance for preview
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 400)
    }
}
