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
//

import SwiftUI
import Combine
import os

// MARK: - Main Sidebar Container View
struct VSCodifiedSidebarContainerView: View {
    
    @State private var selectedTab: SidebarTab? = .conversations
    @Binding var isSidebarVisible: Bool
    @Binding var sidebarWidth: CGFloat
    
    @State private var isHoveringOnDivider = false
    
    private let minSidebarWidth: CGFloat = 260 // Slightly narrower min width for modern feel
    private let maxSidebarWidth: CGFloat = 600
    private let activityBarWidth: CGFloat = 50

    // Remember preferred widths for each tab type
    @State private var preferredWidths: [SidebarTab: CGFloat] = [
        .conversations: 320,
        .explorer: 300,
        .promptLibrary: 350,
        .scheduler: 350,
        .settings: 300
    ]

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    init(isSidebarVisible: Binding<Bool>, sidebarWidth: Binding<CGFloat>) {
        self._isSidebarVisible = isSidebarVisible
        self._sidebarWidth = sidebarWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            // Detached Floating Sidebar Unit
            HStack(spacing: 0) {
                // Activity Bar (Leftmost icon strip)
                ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                    .frame(width: activityBarWidth, alignment: .center)
                    .frame(maxHeight: .infinity)

                if isSidebarVisible {
                    // Vertical Separator (Padded so it doesn't touch the outer border)
                    Rectangle()
                        .fill(theme.surfaceOverlayStrong.opacity(0.3))
                        .frame(width: 1)
                        .padding(.vertical, 16)

                    // Sidebar Content Pane
                    SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $sidebarWidth)
                        .frame(width: sidebarWidth)
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
                    .shadow(color: Color.black.opacity(0.18), radius: 15, x: 0, y: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong.opacity(0.5), lineWidth: 1)
            )
            .overlay(alignment: .trailing) {
                if isSidebarVisible {
                    // Resize Handle (Overlapping the border)
                    ZStack {
                        // Invisible hit target area (wider than the visual line)
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 10)

                        // Visual Divider Line (subtle highlight on hover)
                        Rectangle()
                            .fill(isHoveringOnDivider ? theme.accentColor : Color.clear)
                            .frame(width: 1.5)
                            .padding(.vertical, 20) // Don't touch the corners
                    }
                    .contentShape(Rectangle())
                    .frame(width: 10)
                    .offset(x: 5) // Center the 10pt hit area on the 1pt border
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = self.sidebarWidth + value.translation.width
                                self.sidebarWidth = min(max(newWidth, self.minSidebarWidth), self.maxSidebarWidth)

                                // Save preference
                                if let tab = selectedTab {
                                    preferredWidths[tab] = self.sidebarWidth
                                }
                            }
                    )
                    .onHover { hovering in
                        self.isHoveringOnDivider = hovering
                        if hovering {
                            NSCursor.resizeLeftRight.set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 12)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: selectedTab) { newTab in
            if let newTab = newTab {
                if !isSidebarVisible {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        isSidebarVisible = true
                    }
                }
                
                // Restore preferred width
                if let savedWidth = preferredWidths[newTab] {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.sidebarWidth = min(max(savedWidth, self.minSidebarWidth), self.maxSidebarWidth)
                    }
                }
            } else {
                // If tab selection is cleared, maybe hide sidebar?
                // Keeping it visible but empty is also valid, but let's stick to current logic.
            }
        }
        .onAppear {
            if let initialTab = selectedTab, let initialPreferredWidth = preferredWidths[initialTab] {
                self.sidebarWidth = min(max(initialPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
            }
        }
    }
}
