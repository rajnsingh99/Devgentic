// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VSCodifiedSidebarContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//
//  Refactored on 27/08/25 to remove LLM Integration sidebar.
//  Refactored on 27/08/25 to remove redundant NewChatTabView.
//  Refactored on 27/08/25 to improve UI to match modern standards.
//  Refactored on 28/08/25 to slim down the sidebar for a cleaner aesthetic.
//  Refactored on 21/04/26 — selectedTab persisted via @AppStorage, shadow
//  themed, user-resizable via drag handle on trailing edge.
//

import SwiftUI
import os

// MARK: - Main Sidebar Container View
struct VSCodifiedSidebarContainerView: View {

    /// Persists across launches — previously `@State` reset the tab to
    /// `.conversations` every cold start.
    @AppStorage(SidebarTab.storageKey) private var selectedTabRawValue: String = SidebarTab.conversations.rawValue

    @Binding var isSidebarVisible: Bool
    @Binding var sidebarWidth: CGFloat

    private let defaultSidebarWidth: CGFloat = 320
    private let minSidebarWidth: CGFloat = 240
    private let maxSidebarWidth: CGFloat = 520
    private let activityBarWidth: CGFloat = 50

    // Drag-resize state
    @State private var isResizing: Bool = false
    @State private var isHoveringHandle: Bool = false
    @State private var resizeStartWidth: CGFloat = 320

    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme
    @Environment(\.surfaceStyle) private var surfaceStyle

    init(isSidebarVisible: Binding<Bool>, sidebarWidth: Binding<CGFloat>) {
        self._isSidebarVisible = isSidebarVisible
        self._sidebarWidth = sidebarWidth
    }

    /// Computed binding that bridges `@AppStorage` String ↔ `SidebarTab?`.
    /// Empty rawValue → nil (Home state); a valid case → that tab.
    private var selectedTabBinding: Binding<SidebarTab?> {
        Binding(
            get: { selectedTabRawValue.isEmpty ? nil : SidebarTab(rawValue: selectedTabRawValue) },
            set: { selectedTabRawValue = $0?.rawValue ?? "" }
        )
    }

    private var selectedTab: SidebarTab? {
        selectedTabRawValue.isEmpty ? nil : SidebarTab(rawValue: selectedTabRawValue)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Detached Floating Sidebar Unit
            HStack(spacing: 0) {
                // Activity Bar (Leftmost icon strip)
                ActivityBarView(selectedTab: selectedTabBinding, isSidebarVisible: $isSidebarVisible)
                    .frame(width: activityBarWidth, alignment: .center)
                    .frame(maxHeight: .infinity)

                if isSidebarVisible {
                    // Vertical Separator
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.secondaryText.opacity(0.12),
                                    theme.surfaceOverlayStrong.opacity(0.4),
                                    theme.secondaryText.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 1)
                        .padding(.vertical, 14)
                        .transition(.opacity)

                    // Sidebar Content Pane + Drag Handle
                    SideBarPaneView(selectedTab: selectedTabBinding, sidebarWidth: $sidebarWidth)
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) { resizeHandle }
                        .transition(.opacity)
                        .clipped()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.secondaryBackground)
                    .shadow(
                        color: surfaceStyle == .glassmorphic ? theme.shadowColor.opacity(0.6) : Color.clear,
                        radius: surfaceStyle == .glassmorphic ? 20 : 0,
                        x: 0,
                        y: surfaceStyle == .glassmorphic ? 8 : 0
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        surfaceStyle == .glassmorphic
                            ? LinearGradient(
                                colors: [
                                    theme.isDark ? Color.white.opacity(0.18) : theme.dividerColor,
                                    theme.dividerColor.opacity(0.6),
                                    theme.accentColor.opacity(0.25)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    theme.isDark ? Color.white.opacity(0.08) : theme.dividerColor.opacity(0.7)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                        lineWidth: 1
                    )
            )
            .padding(.leading, 12)
            .padding(.vertical, 12)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: selectedTab) { _, newTab in
            if newTab != nil && !isSidebarVisible {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSidebarVisible = true
                }
            }
        }
        .onAppear {
            if sidebarWidth < minSidebarWidth {
                sidebarWidth = defaultSidebarWidth
            }
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
            
            // Central hairline indicator with magnetic glow
            ZStack {
                Rectangle()
                    .fill(isResizing ? theme.accentColor : theme.secondaryText.opacity(0.4))
                    .frame(width: 1.5)
                    .shadow(color: isResizing ? theme.accentColor.opacity(0.8) : .clear, radius: 4)

                if isHoveringHandle || isResizing {
                    VStack(spacing: 3) {
                        Circle().fill(theme.accentColor).frame(width: 2.5, height: 2.5)
                        Circle().fill(theme.accentColor).frame(width: 2.5, height: 2.5)
                        Circle().fill(theme.accentColor).frame(width: 2.5, height: 2.5)
                    }
                    .shadow(color: theme.accentColor.opacity(0.8), radius: 3)
                }
            }
            .padding(.vertical, 12)
            .opacity(isHoveringHandle || isResizing ? 1.0 : 0.0)
        }
        .contentShape(Rectangle())
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringHandle = hovering
            }
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isResizing {
                        isResizing = true
                        resizeStartWidth = sidebarWidth
                    }
                    let proposed = resizeStartWidth + value.translation.width
                    sidebarWidth = min(max(proposed, minSidebarWidth), maxSidebarWidth)
                }
                .onEnded { _ in
                    isResizing = false
                }
        )
        .accessibilityLabel("Sidebar resize handle")
        .accessibilityHint("Drag to resize the sidebar")
    }
}
