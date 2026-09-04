//
//  TokenUsageBadge.swift
//  Devgentic
//
//  Compact token usage indicator displayed below agent message bubbles.
//  Shows input/output token counts with a "~" prefix for estimates.
//

import SwiftUI

struct TokenUsageBadge: View {
    let usage: TokenUsage
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "number.circle")
                .font(.system(size: 10))

            Text(formattedUsage)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(theme.secondaryText.opacity(0.7))
        .padding(.top, 2)
        .accessibilityLabel(Self.spokenLabel(for: usage))
    }

    private var formattedUsage: String { Self.badgeText(for: usage) }

    // MARK: - Pure formatting
    //
    // The badge string and the spoken label are two renderings of ONE decision (below), so they
    // cannot drift: same estimate flag, same abbreviation thresholds. Only the unit's spelling
    // differs. `nonisolated static` so both are unit-testable without hosting a view.

    /// What the badge shows.
    nonisolated static func badgeText(for usage: TokenUsage) -> String {
        let prefix = usage.isEstimated ? "~" : ""
        return "\(prefix)\(abbreviated(usage.inputTokens)) in \u{00B7} \(prefix)\(abbreviated(usage.outputTokens)) out"
    }

    /// What VoiceOver is told. Two things the old constant label dropped (CF-41):
    ///
    /// - the `~`. It is the ONLY signal separating a locally-guessed count from a
    ///   provider-reported one, and reading a bare integer aloud makes a stronger claim than the
    ///   badge ever makes. Carried once as the word "Estimated" rather than twice as a symbol
    ///   VoiceOver does not pronounce.
    /// - the abbreviation. The badge reads "1.2K"; a label saying "1183" describes a string that
    ///   is not on screen, so a sighted helper and a VoiceOver user disagree about what it says.
    ///
    /// "thousand"/"million" instead of "K"/"M" because VoiceOver spells those letters out.
    nonisolated static func spokenLabel(for usage: TokenUsage) -> String {
        let lead = usage.isEstimated
            ? String(localized: "Estimated token usage")
            : String(localized: "Token usage")
        return "\(lead): \(spoken(usage.inputTokens)) input, \(spoken(usage.outputTokens)) output"
    }

    /// The single magnitude decision. 1,000 / 1,000,000 thresholds live here and nowhere else.
    enum Magnitude: Equatable {
        case units(Int)
        /// Already scaled and rounded to one decimal, e.g. "1.2".
        case thousands(String)
        case millions(String)
    }

    nonisolated static func magnitude(of count: Int) -> Magnitude {
        if count >= 1_000_000 { return .millions(String(format: "%.1f", Double(count) / 1_000_000)) }
        if count >= 1_000 { return .thousands(String(format: "%.1f", Double(count) / 1_000)) }
        return .units(count)
    }

    nonisolated static func abbreviated(_ count: Int) -> String {
        switch magnitude(of: count) {
        case .units(let n):     return "\(n)"
        case .thousands(let v): return "\(v)K"
        case .millions(let v):  return "\(v)M"
        }
    }

    nonisolated static func spoken(_ count: Int) -> String {
        switch magnitude(of: count) {
        case .units(let n):     return "\(n)"
        case .thousands(let v): return String(localized: "\(v) thousand")
        case .millions(let v):  return String(localized: "\(v) million")
        }
    }
}
