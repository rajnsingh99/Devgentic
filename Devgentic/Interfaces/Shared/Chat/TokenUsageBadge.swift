// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TokenUsageBadge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// Compact token usage indicator shown below agent message bubbles: input/output counts, with a "~" prefix for estimates.
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
    // The badge string and spoken label render one decision, so estimate flag and abbreviation thresholds cannot drift.
    // `nonisolated static` so both are unit-testable without hosting a view.

    /// What the badge shows.
    nonisolated static func badgeText(for usage: TokenUsage) -> String {
        let prefix = usage.isEstimated ? "~" : ""
        return "\(prefix)\(abbreviated(usage.inputTokens)) in \u{00B7} \(prefix)\(abbreviated(usage.outputTokens)) out"
    }

    /// What VoiceOver is told: the badge's count, abbreviated the same way, with "Estimated" in place of the `~` symbol.
    /// The `~` is the only signal separating a guessed count from a provider-reported one.
    /// Uses "thousand"/"million" instead of "K"/"M" because VoiceOver spells those letters out.
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

    /// Chooses the magnitude bucket from the rounded value, not the raw count, so `%.1f` cannot round past a threshold
    /// (999,950 would otherwise print "1000.0K"). The millions branch scales from the millions divisor.
    nonisolated static func magnitude(of count: Int) -> Magnitude {
        if count < 1_000 { return .units(count) }
        // Would the thousands rendering round up to four digits? Then it is really a million.
        let roundedThousandths = ((Double(count) / 1_000) * 10).rounded()
        if roundedThousandths >= 10_000 {
            return .millions(String(format: "%.1f", Double(count) / 1_000_000))
        }
        return .thousands(String(format: "%.1f", Double(count) / 1_000))
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
