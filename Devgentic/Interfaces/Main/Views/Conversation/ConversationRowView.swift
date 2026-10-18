// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationRowView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

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

    /// Live streaming flag, computed at the call site from `ActiveStreamManager`.
    /// The struct's own `conversation.isStreaming` is always false because no persisted column backs it.
    var isStreamingLive: Bool = false

    /// This conversation has a background task that will add a turn to it when it ends.
    /// Computed at the call site from `PendingBackgroundReports`, the same predicate the transcript footer uses.
    /// Surfaces the task in the sidebar, since the footer and tasks pill cover only the displayed conversation.
    var hasPendingBackgroundReport: Bool = false

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
        .pointingHandCursor(enabled: !isRenaming)
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
            Text(conversation.displayTitle)
                .font(theme.fontFootnote.weight(.medium))
                .foregroundColor(theme.primaryText)
                .lineLimit(1)

            Spacer()

            // One state indicator, or hover actions / timestamp (mutually exclusive, to prevent overlaps).
            // Needs-input is checked before streaming: a run parked on a HITL still holds a live stream task.
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
                } else if hasPendingBackgroundReport {
                    // Deliberately not a pulse: this means something will speak here later, not that a run is live.
                    // Placed after the hover branch so it takes the timestamp's slot and the delete button stays available.
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(.caption2))
                        .foregroundColor(theme.accentColor)
                        .help("A background task will report here when it finishes")
                        .accessibilityLabel("A background task will report here when it finishes")
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
        if let onDelete = onDelete {
            HoverActionButton(
                icon: "trash",
                tint: theme.errorColor.opacity(0.85),
                action: onDelete
            )
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
        isPinned: Bool = false
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
            isPinned: isPinned
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

        let pinnedConv = createSample(
            title: "Project Architecture",
            lastMessageContent: .plainText("Let me outline the MVVM pattern..."),
            timestamp: Calendar.current.date(byAdding: .hour, value: -2, to: .now)!,
            isPinned: true
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
