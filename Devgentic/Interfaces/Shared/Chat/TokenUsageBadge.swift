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
        .accessibilityLabel("Token usage: \(usage.inputTokens) input, \(usage.outputTokens) output")
    }

    private var formattedUsage: String {
        let prefix = usage.isEstimated ? "~" : ""
        let input = formatCount(usage.inputTokens)
        let output = formatCount(usage.outputTokens)
        return "\(prefix)\(input) in \u{00B7} \(prefix)\(output) out"
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}
