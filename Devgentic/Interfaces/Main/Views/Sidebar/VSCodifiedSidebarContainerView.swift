// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  VSCodifiedSidebarContainerView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

// MARK: - Main Sidebar Container View
/// The sidebar container: hosts the selected sidebar pane, with the selected tab persisted via `@AppStorage` and a
/// user-resizable width through a drag handle on its trailing edge.
struct VSCodifiedSidebarContainerView: View {

    /// The selected tab, persisted across launches.
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
    @State private var dragStartWidth: CGFloat? = nil

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

                    // Sidebar Content Pane
                    SideBarPaneView(selectedTab: selectedTabBinding, sidebarWidth: $sidebarWidth)
                        .frame(width: sidebarWidth)
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
            .overlay(alignment: .trailing) {
                if isSidebarVisible {
                    resizeHandle
                }
            }
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
        let isHighlighted = isHoveringHandle || isResizing

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
        .offset(x: 7)
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? sidebarWidth
                    if dragStartWidth == nil {
                        dragStartWidth = start
                        isResizing = true
                    }
                    let proposed = start + value.translation.width
                    sidebarWidth = min(max(proposed, minSidebarWidth), maxSidebarWidth)
                }
                .onEnded { _ in
                    isResizing = false
                    dragStartWidth = nil
                    if !isHoveringHandle {
                        NSCursor.arrow.set()
                    }
                }
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHoveringHandle = hovering
            }
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else if !isResizing {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
        .accessibilityLabel("Sidebar resize handle")
        .accessibilityHint("Drag to resize the sidebar")
    }
}
