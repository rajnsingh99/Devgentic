// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeBlockCardView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI

/// A card summarizing a code block (language badge, line count, file name) that opens it in the viewer.
struct CodeBlockCardView: View {
    let language: String
    let lineCount: Int
    let fileName: String?
    /// The code itself, so the card can be copied without opening the viewer first.
    var content: String = ""
    let action: () -> Void

    @State private var isHovering = false
    @State private var didCopy = false
    @Environment(\.appTheme) private var theme

    private var title: String {
        if let fileName = fileName, !fileName.isEmpty { return fileName }
        return language.isEmpty ? "Code Snippet" : "\(language.capitalized) Snippet"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Icon Container
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [theme.accentColor.opacity(0.25), theme.streamingIndicator.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 42, height: 42)
                        .overlay(Circle().stroke(theme.accentColor.opacity(0.3), lineWidth: 0.5))

                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(theme.fontBody.weight(.semibold))
                        .foregroundColor(theme.primaryText)

                    Text("\(lineCount) lines • Click to open")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                // Right Cluster: Language Capsule + Open CTA Pill
                HStack(spacing: 8) {
                    if !language.isEmpty {
                        Text(language.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.primaryText.opacity(0.8))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(theme.surfaceOverlayStrong))
                            .overlay(Capsule().stroke(theme.secondaryText.opacity(0.2), lineWidth: 0.5))
                    }

                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .semibold))
                        Text(didCopy ? "Copied" : "Open")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(didCopy ? theme.successColor : theme.accentColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4.5)
                    .background(Capsule().fill(theme.accentColor.opacity(isHovering ? 0.2 : 0.12)))
                    .overlay(Capsule().stroke(theme.accentColor.opacity(isHovering ? 0.4 : 0.2), lineWidth: 0.5))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appSurface(in: .rect(cornerRadius: 12), elevation: .card)
            .scaleEffect(isHovering ? 1.01 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(lineCount) lines")
        .accessibilityHint("Double-tap to open in code viewer")
        .accessibilityAddTraits(.isButton)
        // Copy lives in a context menu, not a nested button: nesting makes the inner button unreliable
        // for mouse and VoiceOver, while a context menu is reachable by Control-click and VO-Shift-M.
        .contextMenu {
            Button(action: copyCode) {
                Label("Copy Code", systemImage: "doc.on.doc")
            }
            .disabled(content.isEmpty)
        }
        .accessibilityAction(named: "Copy code") { copyCode() }
        .frame(maxWidth: 400, alignment: .leading)
        .padding(.vertical, 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }

    private func copyCode() {
        guard !content.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        withAnimation(.easeInOut) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeInOut) { didCopy = false }
        }
    }
}
