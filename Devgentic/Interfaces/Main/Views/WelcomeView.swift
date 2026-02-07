//
//  WelcomeView.swift
//  Devgentic
//
//  Created by Raj Singh on 20/08/25.
//

import SwiftUI

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 32) {
            // MARK: - Hero Section
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.15), .purple.opacity(0.15)],
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
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .purple.opacity(0.3), radius: 10, x: 0, y: 5)
                }

                VStack(spacing: 6) {
                    Text("Devgentic")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    
                    Text("Your AI Development Companion")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Shortcuts Card
            VStack(alignment: .leading, spacing: 16) {
                ShortcutRow(keys: ["⌘", "B"], description: "Toggle Sidebar")
                Divider().opacity(0.5)
                ShortcutRow(keys: ["⌘", "O"], description: "Add Context")
                Divider().opacity(0.5)
                ShortcutRow(keys: ["⇧", "⌘", "C"], description: "New Conversation")
                Divider().opacity(0.5)
                ShortcutRow(keys: ["⇧", "⌘", "A"], description: "Settings")
            }
            .padding(24)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
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

    var body: some View {
        HStack {
            Text(description)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

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
    
    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(minWidth: 24)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.primary.opacity(0.1), lineWidth: 0.5)
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
