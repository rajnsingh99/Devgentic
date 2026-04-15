//
//  CodeBlockCardView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/07/25.
//
//  MODERNIZED: Glassmorphic card design with language badges.
//  THEME: Migrated to centralized AppTheme via @Environment(\.appTheme).

import SwiftUI

struct CodeBlockCardView: View {
    let language: String
    let lineCount: Int
    let fileName: String?
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.appTheme) private var theme

    private var title: String {
        if let fileName = fileName, !fileName.isEmpty { return fileName }
        return language.isEmpty ? "Code Snippet" : "\(language.capitalized) Snippet"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [theme.streamingIndicator.opacity(0.2), theme.accentColor.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)

                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(.body, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("\(lineCount) lines • Tap to expand")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Language Badge
                Text(language.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced)) // Fixed size: monospaced
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceOverlayStrong)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.surfaceOverlayStrong, lineWidth: 1))

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText.opacity(0.5))
            }
            .padding(12)
            // MARK: Liquid Glass
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
            // --- To revert to pre-Liquid-Glass, comment out the line above and uncomment below ---
            // .background(.ultraThinMaterial)
            // .clipShape(RoundedRectangle(cornerRadius: 12))
            // .overlay(
            //     RoundedRectangle(cornerRadius: 12)
            //         .stroke(isHovering ? theme.accentColor.opacity(0.5) : theme.surfaceOverlayStrong, lineWidth: 1)
            // )
            // .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(lineCount) lines")
        .accessibilityHint("Double-tap to open in code viewer")
        .accessibilityAddTraits(.isButton)
        .frame(maxWidth: 400, alignment: .leading)
        .padding(.vertical, 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}
