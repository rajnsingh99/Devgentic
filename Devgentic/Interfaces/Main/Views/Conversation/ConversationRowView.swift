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
    // Drives the amber "needs input" pulse on the accent rail.
    @State private var needsInputPulse = false
    @Environment(\.appTheme) private var theme

    // Batch selection properties
    var isSelectionMode: Bool = false
    var isBatchSelected: Bool = false

    /// [F2] This conversation has a pending HITL request — surface a "needs input" indicator in the
    /// sidebar so an unfocused (or background/remote/scheduled) run that's waiting is discoverable.
    var needsInput: Bool = false

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
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            // Left rail = STATE: Amber/warning rail only when the run needs user attention (input).
            if needsInput {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(
                        LinearGradient(colors: railGradientColors, startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: 3, height: 14)
                    .padding(.trailing, 6)
                    .shadow(
                        color: theme.warningColor.opacity(needsInputPulse ? 0.85 : 0.2),
                        radius: needsInputPulse ? 7 : 2
                    )
                    .help("Needs your input")
                    .accessibilityLabel("Needs your input")
            } else {
                Spacer().frame(width: 9)
            }

            // Title row
            HStack(spacing: 5) {
                // Backend origin dot (theme-aware palette) — decoupled from the state rail.
                if hasBackendDot {
                    Circle()
                        .fill(theme.backendColor(for: conversation.backendType ?? .none))
                        .frame(width: 6, height: 6)
                }

                Text(conversation.displayTitle)
                    .font(theme.fontFootnote.weight(.medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }

            Spacer()

            // Streaming indicator, Hover Actions, or Timestamp (mutually exclusive swap to prevent overlaps)
            Group {
                if conversation.isStreaming {
                    StreamingPulseIndicator()
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
        // Drive the amber "needs input" pulse from a stable parent so it tracks the state reliably.
        .onChange(of: needsInput, initial: true) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                    needsInputPulse = true
                }
            } else {
                withAnimation(.easeInOut(duration: 0.2)) { needsInputPulse = false }
            }
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
                    tint: .red.opacity(0.7),
                    action: onDelete
                )
            }
        }
    }

    // MARK: - Background
    @ViewBuilder
    private var backgroundView: some View {
        if isSelected {
            // Selected state — neutral accent tint (origin is carried by the dot, not the selection).
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.accentColor.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: theme.accentColor.opacity(0.05), radius: 4, x: 0, y: 0)
        } else if isHovering {
            // Subtle hover plate
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceOverlay)
        } else {
            Color.clear
        }
    }

    // MARK: - Helpers

    /// Whether to show the backend origin dot (hidden for conversations with no backend).
    private var hasBackendDot: Bool {
        if let backendType = conversation.backendType { return backendType != .none }
        return false
    }

    /// Left-rail gradient = STATE: amber when the run needs input (highest priority), else the
    /// selection accent — bright when selected, dim on hover.
    private var railGradientColors: [Color] {
        return [theme.warningColor, theme.warningColor.opacity(0.55)]
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
            .background(AppThemes.DefaultTheme().primaryBackground)
        }
    }
}
