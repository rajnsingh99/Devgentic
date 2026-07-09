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
    @Environment(\.appTheme) private var theme

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
                        .font(.headline)
                        .bold()
                        .foregroundColor(theme.errorColor.opacity(0.95))
                }
                Text(details)
                    .font(theme.fontBody) 
                    .foregroundColor(theme.primaryText.opacity(0.85))
                    .textSelection(.enabled) 

                if let suggestion = suggestion, !suggestion.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "lightbulb.fill")
                            .font(.callout)
                            .foregroundColor(theme.accentColor.opacity(0.9))
                        Text(suggestion)
                            .font(.callout)
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
        .accessibilityLabel("Error: \(title ?? "Unknown"). \(details)" + (suggestion.map { ". Suggestion: \($0)" } ?? ""))
        .accessibilityAddTraits(.isStaticText)
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
