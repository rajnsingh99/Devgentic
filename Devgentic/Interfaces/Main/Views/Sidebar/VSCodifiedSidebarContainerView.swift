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
        .settings: 300,
        .user: 300
    ]

    @EnvironmentObject var viewModel: MainApplicationViewModel

    init(isSidebarVisible: Binding<Bool>, sidebarWidth: Binding<CGFloat>) {
        self._isSidebarVisible = isSidebarVisible
        self._sidebarWidth = sidebarWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            // Activity Bar (Leftmost icon strip)
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                .frame(width: activityBarWidth)
                .zIndex(1) // Ensure it sits "above" visually if needed

            if isSidebarVisible {
                // Sidebar Content Pane
                SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $sidebarWidth)
                    .frame(width: sidebarWidth)
                    // Apply Material background for native macOS vibrancy
                    .background(.regularMaterial)
                    .transition(.move(edge: .leading))
                    .clipped()

                // Resize Handle
                ZStack {
                    // Invisible hit target area (wider than the visual line)
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 6)
                    
                    // Visual Divider Line
                    Rectangle()
                        .fill(isHoveringOnDivider ? Color.accentColor : Color.primary.opacity(0.1))
                        .frame(width: 1)
                }
                .contentShape(Rectangle())
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
                .zIndex(2) // Resize handle on top
            }
        }
        .frame(maxHeight: .infinity)
        // Ensure the entire container has a clean background behind the transparency
        .background(Color.clear)
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
