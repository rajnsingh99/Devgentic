// Views/ChatHeaderView.swift
import SwiftUI

struct ChatHeaderView: View {
    // The title of the current chat, passed from the parent view
    let chatTitle: String

    // Flag indicating if the "user messages only" filter is active
    let isFilterActive: Bool

    // Action to perform when the eye button is tapped
    let onEyeButtonTapped: () -> Void

    // --- NEW: Action for the transfer button ---
    /// Action to perform when the transfer button is tapped. Optional because it might not always be available/enabled.
    let onTransferButtonTapped: (() -> Void)?
    /// Flag indicating if a conversation is selected (to enable/disable the transfer button).
    let isConversationSelected: Bool
    // --- END NEW ---

    @Environment(\.appTheme) private var theme: any Theme

    // A subtle color for the bottom border, adaptable to light/dark mode
    private var borderColor: Color {
        return theme.dividerColor.opacity(0.6)
    }

    var body: some View {
        HStack {
            // Chat Title on the left
            Text(chatTitle)
                .font(.headline) // Suitable font size for a header title
                .foregroundColor(theme.primaryText) // Adapts to light/dark mode
                .lineLimit(1) // Prevent title from wrapping
                .truncationMode(.tail) // Truncate if too long

            Spacer() // Pushes the title left and the buttons right

            // --- NEW: Transfer to Overlay Button ---
            Button(action: {
                onTransferButtonTapped?() // Call the closure if it exists
            }) {
                Image(systemName: "arrow.up.forward.app") // Icon suggesting sending to another app/panel
                    .font(.title3) // Match eye icon size
            }
            .buttonStyle(.plain)
            .foregroundColor(isConversationSelected ? theme.secondaryText : theme.secondaryText.opacity(0.5)) // Use secondary color, gray out if disabled
            .help(isConversationSelected ? "Continue this chat in Quick Access overlay" : "Select a chat to transfer")
            .accessibilityLabel("Transfer to Quick Access")
            .disabled(!isConversationSelected) // Disable if no conversation is selected
            // --- END NEW ---
            
            // Existing Eye icon button
            Button(action: onEyeButtonTapped) {
                Image(systemName: isFilterActive ? "eye.slash.fill" : "eye.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundColor(isFilterActive ? theme.streamingIndicator : theme.secondaryText)
            .help(isFilterActive ? "Show all messages" : "Show only my messages")
            .accessibilityLabel(isFilterActive ? "Show all messages" : "Show only my messages")
        }
        .padding(.horizontal) // Horizontal padding for content
        .padding(.vertical, 12) // Vertical padding
        .overlay( // Draw the bottom border
            Rectangle()
                .frame(height: 0.5) // Thin border
                .foregroundColor(borderColor), // Use the defined border color
            alignment: .bottom
        )
    }
}

// MARK: - Preview Provider
struct ChatHeaderView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            ChatHeaderView(
                chatTitle: "Standard Conversation Title",
                isFilterActive: false,
                onEyeButtonTapped: { print("Eye tapped") },
                onTransferButtonTapped: { print("Transfer tapped") }, // Provide action for preview
                isConversationSelected: true // Enable transfer button in preview
            )
            
            ChatHeaderView(
                chatTitle: "Filtered User Messages View",
                isFilterActive: true,
                onEyeButtonTapped: { print("Eye tapped") },
                onTransferButtonTapped: { print("Transfer tapped") },
                isConversationSelected: true
            )

            ChatHeaderView(
                 chatTitle: "No Conversation Selected",
                 isFilterActive: false,
                 onEyeButtonTapped: {},
                 onTransferButtonTapped: nil, // Can be nil
                 isConversationSelected: false // Disable transfer button
             )
        }
        .padding()
        .background(AppThemes.MaterialTheme().primaryBackground) // Preview-only
        .previewLayout(.sizeThatFits)
    }
}
