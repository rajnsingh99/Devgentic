// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// [B] This conversation has a background task that will add a turn to it when it ends.
    ///
    /// ⚠️ THE POINT IS THE CONVERSATIONS YOU ARE NOT LOOKING AT. The in-transcript footer and the
    /// tasks pill are both scoped to the displayed conversation, so switching away takes the fact
    /// with it — and switching away is the common case, because starting something long and going
    /// elsewhere is what background tasks are FOR. Without this the sidebar is the only surface
    /// that could have told you, and it said nothing.
    ///
    /// Computed at the call site from `PendingBackgroundReports`, the same predicate the footer
    /// uses — same live-flag pattern as `needsInput` [F2] and `isStreamingLive` [P8].
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
                } else if hasPendingBackgroundReport {
                    // ⚠️ Deliberately NOT a pulse. The two pulses above mean "this is happening
                    // right now, in this conversation"; this means "something will speak here
                    // later, on its own" — a different promise, and a pulse would overstate it
                    // into looking like a live run.
                    //
                    // ⚠️ Placed AFTER the hover branch, so it takes the TIMESTAMP's slot rather
                    // than the delete button's. Ambient information belongs where ambient
                    // information already is, and a conversation must stay deletable while a task
                    // it started is still running.
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
