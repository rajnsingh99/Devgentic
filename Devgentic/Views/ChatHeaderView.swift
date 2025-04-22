// Views/ChatHeaderView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "ChatHeaderView")

struct ChatHeaderView: View {
    // State & Data passed down
    @Binding var isSidebarCollapsed: Bool
    let currentConversationTitle: String
    let onToggleSidebar: () -> Void
    let onShowSettings: () -> Void

    var body: some View {
        HStack {
            // Sidebar Toggle Button
            Button(action: onToggleSidebar) { // Use the passed closure
                Image(systemName: isSidebarCollapsed ? "sidebar.right" : "sidebar.left")
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(PlainButtonStyle())
            .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed) // Animate icon change

            // Conversation Title
            Text(currentConversationTitle)
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading) // Allow title to expand

            Spacer() // Pushes buttons to edges

            // Settings Button
            Button(action: onShowSettings) { // Use the passed closure
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color.gray.opacity(0.2)) // Background for the header
    }
}

// Preview Provider
struct ChatHeaderView_Previews: PreviewProvider {
    @State static var isCollapsed = false

    static var previews: some View {
        ChatHeaderView(
            isSidebarCollapsed: $isCollapsed,
            currentConversationTitle: "A Sample Chat Title That Might Be Long",
            onToggleSidebar: { isCollapsed.toggle() },
            onShowSettings: { print("Preview: Show Settings Tapped") }
        )
        .previewLayout(.sizeThatFits) // Adjust preview size

        ChatHeaderView(
            isSidebarCollapsed: .constant(true), // Preview collapsed state
            currentConversationTitle: "Devgentic",
            onToggleSidebar: { },
            onShowSettings: { }
        )
        .previewLayout(.sizeThatFits)
    }
}
