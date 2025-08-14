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
        HStack(spacing: 0) {
            if isRenaming {
                // Use a modern TextField style for renaming
                TextField("", text: $editableName, prompt: Text("Enter new name").foregroundColor(.secondary))
                    .textFieldStyle(.plain)
                    .focused(isRenameFieldFocused)
                    .onSubmit(onCommitRename)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
            } else {
                standardContentView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(backgroundView)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isRenaming {
                onSelect()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                self.isHovering = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
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
                .padding(.leading, 4)
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
        }

        // Title and Last Message Snippet
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.displayTitle)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
            
            HStack {
                Text(conversation.lastMessageSnippet)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer()
                
                // Relative Timestamp
                Text(conversation.relativeTimestamp)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.leading, conversation.isStreaming || conversation.hasError ? 4 : 12)
        .padding(.trailing, 12)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            // A more distinct selected state
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.25))
        } else if isHovering {
            // Subtle background for hover
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.15))
        } else {
            // Default clear background
            Color.clear
        }
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
        hasError: Bool = false,
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
            title: "SwiftUI Best Practices & Modern Layouts",
            lastMessageContent: .plainText("Remember to use @State for transient UI state and..."),
            timestamp: Calendar.current.date(byAdding: .minute, value: -5, to: .now)!
        )
        
        let streamingConv = createSample(
            title: "Live Code Generation",
            lastMessageContent: .plainText("Here is the updated code snippet..."),
            isStreaming: true,
            timestamp: .now
        )
        
        let errorConv = createSample(
            title: "API Connection Issue",
            lastMessageContent: .plainText("Failed to fetch the requested data."),
            hasError: true,
            timestamp: Calendar.current.date(byAdding: .hour, value: -1, to: .now)!
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("MODERN SIDEBAR ROWS").font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                
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
                    conversation: streamingConv,
                    isSelected: false,
                    isRenaming: false,
                    editableName: .constant(""),
                    isRenameFieldFocused: $isFocused,
                    onSelect: {},
                    onCommitRename: {}
                )
                
                ConversationRowView(
                    conversation: errorConv,
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
        }
        .frame(width: 340)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
