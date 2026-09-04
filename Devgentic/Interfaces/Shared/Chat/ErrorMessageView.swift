// Views/Messages/ErrorMessageView.swift (Example location)
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI

struct ErrorMessageView: View {
    let title: String?
    let details: String
    /// Structured error category — drives the icon. `nil` for legacy/un-categorized
    /// errors (renders the generic octagon), so existing callers are unaffected.
    var category: AgentErrorCategory? = nil
    /// Optional actionable remediation ("try re-attaching the file"). Rendered as a
    /// distinct lightbulb line below the details when present.
    var suggestion: String? = nil
    /// ⚠️ [CF-40] Identity for the repeat-suppression window, when the caller has one.
    ///
    /// Suppression defaults to keying on the SENTENCE, which stops a rebuilt card re-speaking a
    /// days-old failure — but it also silences a genuinely NEW failure that happens to read the
    /// same, and "the retry failed the same way" is the case a VoiceOver user most needs to hear.
    /// A caller that can distinguish occurrences (an artifact id plus an attempt counter) passes
    /// one here; `nil` keeps the sentence-keyed behaviour for callers that cannot.
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
                    // `theme.fontBody` is a fixed ~13pt, so at 20pt chat the error text
                    // stayed small while the prose around it grew — exactly the message a
                    // reader who sized up needs to be able to read.
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
        // An error card appears wherever the agent happens to be writing, which is rarely
        // where the VoiceOver cursor is — so the run just went quiet and stayed quiet.
        // `.polite` rather than `.immediate`: the error has already happened and the card
        // isn't going anywhere; nothing is lost by waiting for the current utterance.
        //
        // ⚠️ `announceOnce`, not `announce` (CF-40). `.task(id:)` fires on APPEARANCE as well as
        // on id change, and the transcript is a LazyVStack: scrolling an old error card back
        // into view, or switching away and back, rebuilt this view and re-spoke a failure that
        // may be days old as if it were happening now. The key is the sentence itself, so the
        // same card cannot be re-announced by a rebuild.
        //
        // ⚠️ This does NOT make the announcement live-only — a historical card scrolled into
        // view for the FIRST time still speaks. That needs a liveness signal from the caller
        // (the message's timestamp), which this view is not given.
        //
        // ⚠️ The key is `announcementKey` when the caller supplied one, so a NEW occurrence that
        // reads identically (a retry failing the same way) still speaks. Sentence-keying alone
        // silenced it for the whole suppression window — see `announcementKey`.
        .task(id: announcementKey ?? spokenDescription) {
            AccessibilityAnnouncer.announceOnce(spokenDescription,
                                                key: announcementKey ?? spokenDescription,
                                                urgency: .polite)
        }
        // One-click copy of the WHOLE error for a bug report. `.textSelection` on the
        // details covers partial selection, but drag-selecting across title + details +
        // suggestion is fiddly and loses the structure. Lives here so every consumer
        // (agent errors, image failures, media failures) inherits it identically.
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
