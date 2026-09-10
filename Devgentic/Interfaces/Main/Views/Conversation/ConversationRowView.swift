// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    @Environment(\.appTheme) private var theme

    // Batch selection properties
    var isSelectionMode: Bool = false
    var isBatchSelected: Bool = false

    /// [F2] This conversation has a pending HITL request — surface a "needs input" indicator in the
    /// sidebar so an unfocused (or background/remote/scheduled) run that's waiting is discoverable.
    var needsInput: Bool = false

    /// [P8] Live streaming flag, computed at the call site from ActiveStreamManager —
    /// the struct's own `conversation.isStreaming` is structurally always false (the
    /// persisted column doesn't exist), so the pulse indicator below had never
    /// rendered once. Same live-flag pattern as `needsInput` [F2].
    var isStreamingLive: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isSelectionMode {
                Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(.body))
                    .foregroundColor(isBatchSelected ? theme.accentColor : theme.secondaryText.opacity(0.4))
                    .padding(.leading, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if isRenaming {
                // Modern renaming field that blends in
                TextField("", text: $editableName, prompt: Text("Name this chat").foregroundColor(.secondary.opacity(0.7)))
                    .textFieldStyle(.plain)
                    .font(theme.fontFootnote.weight(.medium))
                    .focused(isRenameFieldFocused)
                    .onSubmit(onCommitRename)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(theme.surfaceOverlayStrong)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                standardContentView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .sidebarRowBackground(isSelected: isSelected, isHovering: isHovering)
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
        HStack(alignment: .center, spacing: 0) {
            // Title. (The backend-origin dot and the amber HITL rail were REMOVED by
            // user decision 2026-07-19 — no profile/backend colors in the sidebar;
            // run state lives in the single pulse indicator on the right.)
            Text(conversation.displayTitle)
                .font(theme.fontFootnote.weight(.medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            // ONE state indicator, two colors — or hover actions / timestamp
            // (mutually exclusive swap to prevent overlaps).
            // Priority: needs-input BEFORE streaming — a run parked on HITL still
            // holds a live stream task, so both flags can be true at once, and
            // "waiting on you" is the actionable truth ("generating" would lie).
            Group {
                if needsInput {
                    StreamingPulseIndicator(color: theme.warningColor)
                        .help("Needs your input")
                        .accessibilityLabel("Needs your input")
                } else if isStreamingLive {
                    StreamingPulseIndicator()
                        .help("Generating…")
                        .accessibilityLabel("Generating a response")
                } else if isHovering && !isSelectionMode {
                    hoverActionsView
                } else {
                    Text(conversation.relativeTimestamp)
                        .font(.system(.caption2))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            .layoutPriority(1)
        }
    }

    // MARK: - Hover Actions
    @ViewBuilder
    private var hoverActionsView: some View {
        HStack(alignment: .center, spacing: 4) {
            if let onPin = onPin {
                HoverActionButton(
                    icon: conversation.isPinned ? "pin.slash" : "pin",
                    action: onPin
                )
            }
            if let onDelete = onDelete {
                HoverActionButton(
                    icon: "trash",
                    tint: theme.errorColor.opacity(0.85),
                    action: onDelete
                )
            }
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
            .background(AppThemes.MaterialTheme().primaryBackground)
        }
    }
}
