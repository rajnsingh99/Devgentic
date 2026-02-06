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
                // Modern renaming field that blends in
                TextField("", text: $editableName, prompt: Text("Name this chat").foregroundColor(.secondary.opacity(0.7)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused(isRenameFieldFocused)
                    .onSubmit(onCommitRename)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(6)
            } else {
                standardContentView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6) // Internal padding for the hover plate
        .padding(.vertical, 6)
        .background(backgroundView)
        .cornerRadius(10) // Softer corners
        .contentShape(Rectangle())
        .onTapGesture {
            if !isRenaming {
                onSelect()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                self.isHovering = hovering
            }
        }
        // Smooth transitions for selection state
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
    
    // The standard view content extracted for clarity
    @ViewBuilder
    private var standardContentView: some View {
        HStack(alignment: .top, spacing: 10) {
            // Optional: Status Indicator / Favicon placeholder area
            // If streaming/error, we show icon. If regular, we could show a dot or nothing.
            if conversation.isStreaming || conversation.hasError {
                Image(systemName: conversation.statusIcon)
                    .foregroundColor(conversation.statusColor)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16, height: 16, alignment: .center)
                    .padding(.top, 2)
            } else {
                // Placeholder for alignment if needed, or just remove to keep tight
                // For a command center look, maybe a subtle dot for unread?
                // Currently keeping clean.
            }

            // Title and Last Message Snippet
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.displayTitle)
                        .font(.system(size: 13, weight: .medium)) // Refined font
                        .foregroundColor(isSelected ? .white : .primary)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Relative Timestamp
                    Text(conversation.relativeTimestamp)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary.opacity(0.6))
                        .lineLimit(1)
                }
                
                Text(conversation.lastMessageSnippet)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .allowsTightening(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            // "Illuminated" active state - Dark Mode professional feel
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                )
        } else if isHovering {
            // Subtle hover plate
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
        } else {
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
            title: "SwiftUI Layout Refactor",
            lastMessageContent: .plainText("Using LazyVStack for better performance..."),
            timestamp: Calendar.current.date(byAdding: .minute, value: -5, to: .now)!
        )
        
        let streamingConv = createSample(
            title: "Debugging CoreData",
            lastMessageContent: .plainText("Analyzing the fetch request predicate..."),
            isStreaming: true,
            timestamp: .now
        )
        
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("SIDEBAR PREVIEW").font(.caption).foregroundColor(.secondary).padding()
                
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
                    conversation: streamingConv,
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
                    editableName: .constant("Renaming this chat..."),
                    isRenameFieldFocused: $isFocused,
                    onSelect: {},
                    onCommitRename: {}
                )
            }
            .padding()
            .frame(width: 300)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}
