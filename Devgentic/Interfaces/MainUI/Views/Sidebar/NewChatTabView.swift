//
//  NewChatTabView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "NewChatTabView")

// MARK: - New Chat Tab View
struct NewChatTabView: View {

    // Explicit initializer to resolve potential ambiguity for the #Preview macro.
    init() {}

    var body: some View {
        VStack {
            Spacer() // Push content to center vertically

            Image(systemName: "bubble.left.and.bubble.right") // Icon suggesting chat
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)

            Text("Ready for your prompt")
                .font(.title2) // Slightly larger text
                .padding(.bottom, 5)

            Text("Type your message below to start a new conversation.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer() // Push content to center vertically
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill available space
        .padding() // Add padding around the content
    }
}

// MARK: - Preview Provider
#Preview {
    NewChatTabView()
        .frame(width: 300, height: 400) // Simulate sidebar pane size
        .previewDisplayName("New Chat Tab Placeholder")
}
