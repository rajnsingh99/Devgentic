// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TrailingSidePanel.swift
//  Devgentic
//
//  The chrome shared by the panels that occupy the chat's trailing slot — Background Tasks and Git
//  Changes: the floating card, the resizable divider, the split/full width rules and the title bar's
//  presentation controls. Each panel supplies only its title, extras and content.
//
//  ⚠️ Extracted 2026-10-04 from two ~137-line copies that differed only in content. A fix to the
//  divider or the width rules (the CF-15 live-drag fix is one) must land in every panel; one copy is
//  how it does. The Code Viewer still has its own — its header is editor-specific.
//
//  Verified pixel-equivalent to the copies it replaced: both panels rendered across surface style ×
//  presentation × Code-Viewer-tabs before and after, within the renderer's own run-to-run noise.
//

import SwiftUI
import AppKit

struct TrailingSidePanel<TitleAccessory: View, Controls: View, Content: View>: View {

    let title: String
    let presentation: CodeViewerPresentation
    let onToggleSplit: () -> Void
    let onToggleExpansion: () -> Void
    let onClose: () -> Void
    /// Shown right after the title (e.g. the Git panel's branch label).
    @ViewBuilder let titleAccessory: () -> TitleAccessory
    /// Shown before the presentation controls, in the same button group (e.g. Refresh).
    @ViewBuilder let extraControls: () -> Controls
    @ViewBuilder let content: () -> Content

    @Environment(ChatHistoryViewModel.self) private var chatHistoryViewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle
    @AppStorage(AppSettings.chatFontSizeKey) private var chatFontSize: Double = 14.0
    /// Shared with the Code Viewer: every panel in the slot opens at the width the user last chose.
    @AppStorage("codeViewerPanelWidth") private var panelWidth: Double = 600

    @State private var isHoveringOnDivider = false
    @State private var dragStartWidth: Double? = nil
    @State private var containerWidth: CGFloat = .infinity

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
            .background(closeShortcut)
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
            // GLOBAL coordinate space is load-bearing. The divider is the panel's leading edge, so it
            // MOVES as a result of its own drag — in `.local` space `translation.width` then includes
            // the divider's own (one-frame-stale) displacement on top of the cursor's, the width
            // overshoots, the next frame compensates back, and the edge oscillates under the cursor.
            // Global space measures the CURSOR alone. (Same reasoning as `CodeViewerPanelView`.)
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    // `translation.width` is cumulative from the gesture's START, so it applies to
                    // the width AT THAT START — not the live width, which is already moving.
                    // Subtracting it from a moved width compounds and the panel races to the clamp.
                    let start = dragStartWidth ?? displayedWidth
                    if dragStartWidth == nil { dragStartWidth = start }
                    let newWidth = CGFloat(start) - value.translation.width
                    // Whole points (sub-pixel widths re-solve text layout for no visible gain);
                    // clamped to the MEASURED container, not an arbitrary cap. Published per tick on
                    // the view model so the chat's split inset tracks the divider live (CF-15).
                    chatHistoryViewModel.codeViewerLiveDragWidth =
                        Double(min(max(newWidth, 400), maxPanelWidth)).rounded()
                }
                .onEnded { _ in
                    if let final = liveDragWidth {
                        panelWidth = final   // persist ONCE per drag, not per tick
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
            content()
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
            Text(title)
                .font(.system(size: chatFontSize - 1, weight: .medium))
                .foregroundStyle(theme.primaryText)

            titleAccessory()

            Spacer()

            // Switch back to the Code Viewer — every panel in the slot offers it while tabs exist.
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

            HStack(spacing: 3) {
                extraControls()

                PanelHeaderIconButton(
                    action: onToggleSplit,
                    icon: "rectangle.split.2x1",
                    helpText: presentation == .split
                        ? String(localized: "Overlay the chat")
                        : String(localized: "Split view with chat"),
                    foregroundColor: presentation == .split ? theme.accentColor : theme.secondaryText,
                    hoverBackground: theme.secondaryText.opacity(0.15),
                    isActive: presentation == .split
                )

                PanelHeaderIconButton(
                    action: onToggleExpansion,
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

                PanelHeaderIconButton(
                    action: onClose,
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

    /// ⌘W closes the panel. Label-less: it exists only for its shortcut, and an empty `Button("")`
    /// would put an empty key in the String Catalog.
    private var closeShortcut: some View {
        Button(action: onClose) { EmptyView() }
            .keyboardShortcut("w", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

extension TrailingSidePanel where TitleAccessory == EmptyView, Controls == EmptyView {
    /// A panel with no title accessory and no extra controls.
    init(title: String,
         presentation: CodeViewerPresentation,
         onToggleSplit: @escaping () -> Void,
         onToggleExpansion: @escaping () -> Void,
         onClose: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, presentation: presentation,
                  onToggleSplit: onToggleSplit, onToggleExpansion: onToggleExpansion, onClose: onClose,
                  titleAccessory: { EmptyView() }, extraControls: { EmptyView() }, content: content)
    }
}

// MARK: - Header Icon Button

/// The title-bar icon button of every `TrailingSidePanel`.
struct PanelHeaderIconButton: View {
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
