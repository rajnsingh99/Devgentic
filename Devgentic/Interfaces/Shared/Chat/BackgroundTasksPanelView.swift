// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  BackgroundTasksPanelView.swift
//  Devgentic
//
//  The floating panel that hosts `BackgroundTasksListView` — the persistent list of everything
//  this conversation has run.
//
//  ⚠️ A SIBLING of the Code Viewer panel, not a tab inside it. `CodeViewerTab` is a source-editor
//  tab — `editedCode`, `lastSavedBuffer`, `lastSavedDisk`, `preWriteDisk`, dirty tracking and
//  save-drift guards, with five test suites around its subtleties. A task list has none of those
//  and would carry all of them as dead weight, while making a fragile type polymorphic to do it.
//
//  Both panels occupy the same trailing slot, so they are MUTUALLY EXCLUSIVE — enforced by the
//  `didSet` pair on `ChatHistoryViewModel`, not by whoever remembers to close the other one.
//

import SwiftUI
import AppKit

struct BackgroundTasksPanelView: View {

    let conversationID: UUID?

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    @State private var isHoveringOnDivider = false
    @State private var dragStartWidth: Double? = nil
    @State private var containerWidth: CGFloat = .infinity

    private var presentation: CodeViewerPresentation { chatHistoryViewModel.backgroundTasksPresentation }
    private var liveDragWidth: Double? { chatHistoryViewModel.codeViewerLiveDragWidth }
    private var displayedWidth: Double { liveDragWidth ?? panelWidth }

    private var maxPanelWidth: CGFloat {
        guard presentation == .split,
              containerWidth.isFinite else { return containerWidth }
        return max(400, containerWidth - ChatUIConstants.splitModeMinChatWidth - 24)
    }

    private var floatingBorderStroke: some ShapeStyle {
        surfaceStyle == .glassmorphic
            ? AnyShapeStyle(LinearGradient(
                colors: [
                    theme.isDark ? Color.white.opacity(0.18) : theme.dividerColor,
                    theme.dividerColor.opacity(0.6),
                    theme.accentColor.opacity(0.25)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            : AnyShapeStyle(LinearGradient(
                colors: [
                    theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
    }

    private var floatingShadowColor: Color {
        surfaceStyle == .glassmorphic
            ? theme.shadowColor.opacity(0.6)
            : Color.black.opacity(theme.isDark ? 0.35 : 0.12)
    }

    var body: some View {
        panelCard
            .padding(.trailing, 12)
        .padding(.vertical, 12)
        .padding(.leading, presentation == .full ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            containerWidth = newWidth
        }
        .transition(.move(edge: .trailing))
        .background(keyboardShortcuts)
    }

    // MARK: - Resizable Divider

    private var resizableDivider: some View {
        let isDragging = chatHistoryViewModel.codeViewerLiveDragWidth != nil
        let isHighlighted = isHoveringOnDivider || isDragging

        return GeometryReader { geo in
            let handleHeight = min(max(geo.size.height * 0.12, 60), 96)

            ZStack {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 14, height: geo.size.height)
                    .contentShape(Rectangle())

                Capsule()
                    .fill(isHighlighted ? theme.accentColor : theme.secondaryText.opacity(0.4))
                    .frame(width: isHighlighted ? 2.5 : 1.5, height: handleHeight)
                    .shadow(color: isHighlighted ? theme.accentColor.opacity(0.6) : .clear, radius: 3)
            }
            .frame(width: 14, height: geo.size.height)
        }
        .frame(width: 14)
        .frame(maxHeight: .infinity)
        .offset(x: -7)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? displayedWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    let newWidth = CGFloat(start) - value.translation.width
                    chatHistoryViewModel.codeViewerLiveDragWidth =
                        Double(min(max(newWidth, 400), maxPanelWidth)).rounded()
                }
                .onEnded { _ in
                    if let final = liveDragWidth {
                        panelWidth = final
                    }
                    chatHistoryViewModel.codeViewerLiveDragWidth = nil
                    dragStartWidth = nil
                    if !isHoveringOnDivider {
                        NSCursor.arrow.set()
                    }
                }
        )
        .onHover { hovering in
            isHoveringOnDivider = hovering
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else if chatHistoryViewModel.codeViewerLiveDragWidth == nil {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
    }

    // MARK: - Panel Card

    private var panelCard: some View {
        VStack(spacing: 0) {
            titleBar
            if let conversationID {
                BackgroundTasksListView(
                    conversationID: conversationID,
                    focusTaskID: chatHistoryViewModel.backgroundTasksFocusTaskID
                )
            } else {
                Text(String(localized: "Open a conversation to see the commands it has run."))
                    .font(.system(size: chatFontSize - 2))
                    .foregroundStyle(theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
        }
        .frame(width: presentation == .full ? nil : min(CGFloat(displayedWidth), maxPanelWidth))
        .frame(maxWidth: presentation == .full ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.secondaryBackground)
                .shadow(
                    color: floatingShadowColor,
                    radius: surfaceStyle == .glassmorphic ? 20 : 16,
                    x: 0,
                    y: surfaceStyle == .glassmorphic ? 8 : 4
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(floatingBorderStroke, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if presentation != .full {
                resizableDivider
            }
        }
    }

    // MARK: - Title Bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text(String(localized: "Background tasks"))
                .font(.system(size: chatFontSize - 1, weight: .medium))
                .foregroundStyle(theme.primaryText)

            Spacer()

            if chatHistoryViewModel.hasCodeViewerTabs {
                Button {
                    chatHistoryViewModel.reopenCodeViewer()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(String(localized: "Code (\(chatHistoryViewModel.codeViewerTabs.count))"))
                            .font(.system(size: chatFontSize - 3, weight: .medium))
                    }
                    .foregroundStyle(theme.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.accentColor.opacity(0.12))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Switch to Code Viewer"))

                Capsule()
                    .fill(theme.secondaryText.opacity(0.2))
                    .frame(width: 1, height: 14)
            }

            // Presentation controls
            HStack(spacing: 3) {
                // Split view toggle
                PanelHeaderIconButton(
                    action: chatHistoryViewModel.toggleBackgroundTasksSplit,
                    icon: "rectangle.split.2x1",
                    helpText: presentation == .split
                        ? String(localized: "Overlay the chat")
                        : String(localized: "Split view with chat"),
                    foregroundColor: presentation == .split ? theme.accentColor : theme.secondaryText,
                    hoverBackground: theme.secondaryText.opacity(0.15),
                    isActive: presentation == .split
                )

                // Full-width toggle
                PanelHeaderIconButton(
                    action: chatHistoryViewModel.toggleBackgroundTasksExpansion,
                    icon: presentation == .full
                        ? "arrow.down.forward.and.arrow.up.backward"
                        : "arrow.up.backward.and.arrow.down.forward",
                    helpText: presentation == .full
                        ? String(localized: "Restore previous width")
                        : String(localized: "Expand to full width"),
                    foregroundColor: presentation == .full ? theme.accentColor : theme.secondaryText,
                    hoverBackground: theme.secondaryText.opacity(0.15),
                    isActive: presentation == .full
                )

                // Close button
                PanelHeaderIconButton(
                    action: chatHistoryViewModel.hideBackgroundTasks,
                    icon: "xmark",
                    helpText: String(localized: "Close"),
                    foregroundColor: theme.secondaryText,
                    hoverBackground: theme.secondaryText.opacity(0.15),
                    isActive: false
                )
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.secondaryText.opacity(0.12))
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    // MARK: - Keyboard Shortcuts

    private var keyboardShortcuts: some View {
        Button("") {
            chatHistoryViewModel.hideBackgroundTasks()
        }
        .keyboardShortcut("w", modifiers: .command)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Header Icon Button

fileprivate struct PanelHeaderIconButton: View {
    let action: () -> Void
    let icon: String
    let helpText: String
    let foregroundColor: Color
    let hoverBackground: Color
    var isActive: Bool = false
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isEnabled ? (isActive ? foregroundColor : (isHovering ? foregroundColor : foregroundColor.opacity(0.75))) : foregroundColor.opacity(0.2))
                .frame(width: 28, height: 28)
                .background(
                    isActive
                        ? foregroundColor.opacity(0.18)
                        : (isHovering && isEnabled ? hoverBackground.opacity(0.6) : Color.clear)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isActive
                                ? foregroundColor.opacity(0.4)
                                : (isHovering && isEnabled ? foregroundColor.opacity(0.25) : Color.clear),
                            lineWidth: isActive ? 0.8 : 0.5
                        )
                )
                .scaleEffect(isHovering && isEnabled ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel(helpText)
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                self.isHovering = hovering
            }
        }
    }
}
