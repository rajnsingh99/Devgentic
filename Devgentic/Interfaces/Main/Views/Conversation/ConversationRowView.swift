// Views/Sidebar/ConversationRowView.swift
import SwiftUI

struct ConversationRowView: View {
    // Input properties
    let conversation: Conversation
    let isSelected: Bool
    let onSelect: () -> Void // Closure to handle selection

    var body: some View {
        HStack {
            Text(conversation.displayTitle)
                // Use primary color; background indicates selection state
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 10) // Slightly reduced vertical padding
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Apply background based on selection state
        .background(
            isSelected
                ? Color.accentColor.opacity(0.3) // More prominent selection
                : Color.secondary.opacity(0.1)   // Subtle background for non-selected
        )
        .cornerRadius(5)
        .contentShape(Rectangle()) // Ensure the whole area is tappable
        .onTapGesture(perform: onSelect) // Call the selection closure
    }
}

// Preview Provider for ConversationRowView
struct ConversationRowView_Previews: PreviewProvider {
    // --- Define a dummy conversation ID for previews ---
    static let previewConversationId = UUID()
    // -------------------------------------------------

    static let sampleConv = Conversation(id: previewConversationId, userDefinedTitle: "Sample Chat Preview")
    static let longConv = Conversation(
        id: previewConversationId, // Use the same ID for consistency in preview
        messages: [
            // --- FIXED: Provide conversationId to ChatMessage ---
            ChatMessage(
                conversationId: previewConversationId, // Added missing argument
                sender: .user,
                content: .plainText("This is a very long title that should be truncated")
            )
            // -------------------------------------------------
        ]
    )

    static var previews: some View {
        VStack(alignment: .leading, spacing: 5) {
            ConversationRowView(
                conversation: sampleConv,
                isSelected: false,
                onSelect: { print("Selected Sample (Not Selected)") }
            )
            ConversationRowView(
                conversation: sampleConv,
                isSelected: true,
                onSelect: { print("Selected Sample (Selected)") }
            )
            ConversationRowView(
                conversation: longConv,
                isSelected: false,
                onSelect: { print("Selected Long Title") }
            )
        }
        .padding()
        .frame(width: 250) // Typical sidebar width
        .previewLayout(.sizeThatFits)
    }
}
