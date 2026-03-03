//
//  WelcomeView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//

import SwiftUI

struct WelcomeView: View {
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        VStack(spacing: 32) {
            // MARK: - Hero Section
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.15), theme.accentMuted.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                        .blur(radius: 20)
                    
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 60, height: 60)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [theme.accentColor, theme.accentMuted],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: theme.accentMuted.opacity(0.3), radius: 10, x: 0, y: 5)
                }

                VStack(spacing: 6) {
                    Text("Devgentic")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(theme.primaryText)
                    
                    Text("Your AI Development Companion")
                        .font(.title3)
                        .foregroundColor(theme.secondaryText)
                }
            }

            // MARK: - Shortcuts Card
            VStack(alignment: .leading, spacing: 16) {
                ShortcutRow(keys: ["⌘", "B"], description: "Toggle Sidebar")
                Rectangle().fill(theme.dividerColor).frame(height: 1).opacity(0.5)
                ShortcutRow(keys: ["⌘", "O"], description: "Add Context")
                Rectangle().fill(theme.dividerColor).frame(height: 1).opacity(0.5)
                ShortcutRow(keys: ["⇧", "⌘", "C"], description: "New Conversation")
                Rectangle().fill(theme.dividerColor).frame(height: 1).opacity(0.5)
                ShortcutRow(keys: ["⇧", "⌘", "A"], description: "Settings")
            }
            .padding(24)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(theme.controlBackground)
                    .shadow(color: theme.primaryText.opacity(0.05), radius: 15, x: 0, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
                    )
            }
            .frame(maxWidth: 400)
        }
        .padding()
    }
}

// MARK: - Helper Views

struct ShortcutRow: View {
    let keys: [String]
    let description: String
    @Environment(\.appTheme) private var theme

    var body: some View {
        HStack {
            Text(description)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.secondaryText)

            Spacer()

            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    KeyboardKeyView(symbol: key)
                }
            }
        }
    }
}

struct KeyboardKeyView: View {
    let symbol: String
    @Environment(\.appTheme) private var theme
    
    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundColor(theme.primaryText)
            .frame(minWidth: 24)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.secondaryBackground)
                    .shadow(color: theme.primaryText.opacity(0.1), radius: 1, x: 0, y: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 0.5)
            )
    }
}

#Preview {
    ZStack {
        Color.gray.opacity(0.1).ignoresSafeArea()
        WelcomeView()
    }
    .frame(width: 800, height: 600)
}
