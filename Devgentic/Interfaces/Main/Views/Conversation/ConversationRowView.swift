// Views/Sidebar/ConversationRowView.swift
import SwiftUI

struct ConversationRowView: View {
    // Input properties
    let conversation: Conversation
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var editableName: String
    var isRenameFieldFocused: FocusState<Bool>.Binding
    
    let onSelect: () -> Void
    let onCommitRename: () -> Void
    
    // Local state for hover effect
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if isRenaming {
                // Show a TextField when in renaming mode
                TextField("Enter new name", text: $editableName)
                    .textFieldStyle(.plain)
                    .focused(isRenameFieldFocused)
                    .onSubmit(onCommitRename) // Commit on Enter key
                    .padding(.leading, 5) // Align with normal title position
            } else {
                // Show the standard content when not renaming
                standardContentView
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(backgroundView)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isRenaming {
                onSelect()
            }
        }
        .onHover { hovering in
            // Animate the change in hover state
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
        // Animate changes when the selection state changes
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
    
    // The standard view content extracted for clarity
    @ViewBuilder
    private var standardContentView: some View {
        // Status Icon: Only show for non-normal states
        if conversation.isStreaming || conversation.hasError {
            Image(systemName: conversation.statusIcon)
                .foregroundColor(conversation.statusColor)
                .font(.body.weight(.medium))
                .frame(width: 20, alignment: .center)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }

        // Title and Last Message Snippet
        VStack(alignment: .leading, spacing: 3) {
            Text(conversation.displayTitle)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
            
            Text(conversation.lastMessageSnippet)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }

        Spacer()

        // Relative Timestamp
        Text(conversation.relativeTimestamp)
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        // This view builder provides a more robust, animatable background.
        if isSelected && !isRenaming {
            // Prominent background for selected items.
            Color.accentColor.opacity(0.3)
        } else if !isRenaming {
            // Subtle background for hover, which animates in and out.
            Color.secondary.opacity(isHovering ? 0.2 : 0)
        }
        // No background when renaming.
    }
}

// MARK: - Preview Provider

struct ConversationRowView_Previews: PreviewProvider {
    static let previewConversationId = UUID()
    
    @FocusState static var isFocused: Bool
    
    static func createSample(
        title: String?,
        lastMessageContent: MessageContent,
        isStreaming: Bool = false,
        timestamp: Date
    ) -> Conversation {
        let message = ChatMessage(
            conversationId: previewConversationId,
            timestamp: timestamp,
            sender: .agent,
            content: lastMessageContent,
            isStreaming: isStreaming
        )
        return Conversation(
            id: previewConversationId,
            messages: [message],
            timestamp: timestamp,
            userDefinedTitle: title
        )
    }

    static var previews: some View {
        let normalConv = createSample(
            title: "SwiftUI Best Practices",
            lastMessageContent: .plainText("Remember to use @State..."),
            timestamp: Calendar.current.date(byAdding: .minute, value: -5, to: .now)!
        )

        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation List")
                .font(.headline)
                .padding(.horizontal, 8)
            
            ConversationRowView(
                conversation: normalConv,
                isSelected: true,
                isRenaming: false,
                editableName: .constant(""),
                isRenameFieldFocused: $isFocused,
                onSelect: {},
                onCommitRename: {}
            )
            
            ConversationRowView(
                conversation: normalConv,
                isSelected: false,
                isRenaming: false,
                editableName: .constant(""),
                isRenameFieldFocused: $isFocused,
                onSelect: {},
                onCommitRename: {}
            )
            
            ConversationRowView(
                conversation: normalConv,
                isSelected: false,
                isRenaming: true,
                editableName: .constant("New Awesome Title"),
                isRenameFieldFocused: $isFocused,
                onSelect: {},
                onCommitRename: {}
            )
        }
        .padding()
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
        .previewLayout(.sizeThatFits)
    }
}
