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

    // Hover action callbacks (optional — for inline pin/delete buttons)
    var onPin: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

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
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Hover action buttons overlay
        .overlay(alignment: .trailing) {
            if isHovering && !isRenaming {
                hoverActionsView
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
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

    // MARK: - Standard Content View
    @ViewBuilder
    private var standardContentView: some View {
        HStack(alignment: .top, spacing: 0) {
            // Accent gradient line on left for selected state
            if isSelected {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 6)
                    .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
            }

            // Status indicator (streaming/error)
            if conversation.isStreaming || conversation.hasError {
                Group {
                    if conversation.isStreaming {
                        // Pulsing streaming indicator
                        StreamingPulseIndicator()
                    } else {
                        Image(systemName: conversation.statusIcon)
                            .foregroundColor(conversation.statusColor)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(width: 16, height: 16, alignment: .center)
                .padding(.top, 2)
                .padding(.trailing, 6)
            }

            // Title, snippet, metadata
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    // Inline pin icon
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.6))
                            .rotationEffect(.degrees(-45))
                    }

                    Text(conversation.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer()

                    // Hide timestamp when hovering (to make room for action buttons)
                    if !isHovering {
                        Text(conversation.relativeTimestamp)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }

                HStack(spacing: 6) {
                    Text(conversation.lastMessageSnippet)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    // Backend badge chip
                    if let backendType = conversation.backendType, backendType != .none {
                        Text(backendType.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(badgeColor(for: backendType).opacity(0.12))
                            .foregroundColor(badgeColor(for: backendType).opacity(0.9))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    // MARK: - Hover Actions
    @ViewBuilder
    private var hoverActionsView: some View {
        HStack(spacing: 2) {
            if let onPin = onPin {
                HoverActionButton(
                    icon: conversation.isPinned ? "pin.slash" : "pin",
                    action: onPin
                )
            }
            if let onDelete = onDelete {
                HoverActionButton(
                    icon: "trash",
                    tint: .red.opacity(0.7),
                    action: onDelete
                )
            }
        }
        .padding(.trailing, 8)
    }

    // MARK: - Background
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            // Accent-tinted selected state
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
        } else if isHovering {
            // Subtle hover plate
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        } else {
            Color.clear
        }
    }

    // MARK: - Helpers
    private func badgeColor(for backendType: BackendType) -> Color {
        switch backendType {
        case .agent: return .purple
        case .ollama: return .orange
        case .remote: return .blue
        case .none: return .secondary
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
        timestamp: Date,
        isPinned: Bool = false,
        backendType: BackendType? = nil
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
            userDefinedTitle: title,
            isPinned: isPinned,
            backendType: backendType
        )
    }

    static var previews: some View {
        let normalConv = createSample(
            title: "SwiftUI Layout Refactor",
            lastMessageContent: .plainText("Using LazyVStack for better performance..."),
            timestamp: Calendar.current.date(byAdding: .minute, value: -5, to: .now)!,
            backendType: .remote
        )

        let streamingConv = createSample(
            title: "Debugging CoreData",
            lastMessageContent: .plainText("Analyzing the fetch request predicate..."),
            isStreaming: true,
            timestamp: .now,
            backendType: .ollama
        )

        let pinnedConv = createSample(
            title: "Project Architecture",
            lastMessageContent: .plainText("Let me outline the MVVM pattern..."),
            timestamp: Calendar.current.date(byAdding: .hour, value: -2, to: .now)!,
            isPinned: true,
            backendType: .agent
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
                    onCommitRename: {},
                    onPin: {},
                    onDelete: {}
                )

                ConversationRowView(
                    conversation: streamingConv,
                    isSelected: false,
                    isRenaming: false,
                    editableName: .constant(""),
                    isRenameFieldFocused: $isFocused,
                    onSelect: {},
                    onCommitRename: {},
                    onPin: {},
                    onDelete: {}
                )

                ConversationRowView(
                    conversation: pinnedConv,
                    isSelected: false,
                    isRenaming: false,
                    editableName: .constant(""),
                    isRenameFieldFocused: $isFocused,
                    onSelect: {},
                    onCommitRename: {},
                    onPin: {},
                    onDelete: {}
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
