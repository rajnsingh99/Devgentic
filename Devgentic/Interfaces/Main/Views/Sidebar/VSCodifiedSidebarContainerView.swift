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
    @AppStorage("sidebar.selectedTab") private var selectedTabRawValue: String = SidebarTab.conversations.rawValue

    @Binding var isSidebarVisible: Bool
    @Binding var sidebarWidth: CGFloat

    private let defaultSidebarWidth: CGFloat = 320
    private let minSidebarWidth: CGFloat = 240
    private let maxSidebarWidth: CGFloat = 520
    private let activityBarWidth: CGFloat = 50

    // Drag-resize state
    @State private var isResizing: Bool = false
    @State private var resizeStartWidth: CGFloat = 320

    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

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
                    // Vertical Separator (Padded so it doesn't touch the outer border)
                    Rectangle()
                        .fill(theme.surfaceOverlayStrong.opacity(0.3))
                        .frame(width: 1)
                        .padding(.vertical, 16)

                    // Sidebar Content Pane + Drag Handle
                    SideBarPaneView(selectedTab: selectedTabBinding, sidebarWidth: $sidebarWidth)
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) { resizeHandle }
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                        .clipped()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.secondaryBackground)
                    .shadow(color: theme.shadowColor, radius: 15, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong.opacity(0.5), lineWidth: 1)
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
            // Seed width on first launch if the persisted value is missing/invalid
            if sidebarWidth < minSidebarWidth {
                sidebarWidth = defaultSidebarWidth
            }
        }
    }

    // MARK: - Resize Handle

    /// A 4pt-wide invisible hit-target on the pane's trailing edge. The user
    /// drags it to resize; width is clamped to `[minSidebarWidth, maxSidebarWidth]`.
    /// The handle lights up subtly while hovered/dragging so there's a visible
    /// affordance without adding permanent chrome.
    private var resizeHandle: some View {
        Rectangle()
            .fill(isResizing ? theme.accentColor.opacity(0.4) : Color.clear)
            .contentShape(Rectangle())
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .onHover { hovering in
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
