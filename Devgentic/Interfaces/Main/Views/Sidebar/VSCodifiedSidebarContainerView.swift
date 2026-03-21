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
    
    private let fixedSidebarWidth: CGFloat = 320
    private let activityBarWidth: CGFloat = 50

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
            .padding(.leading, 12)
            .padding(.vertical, 12)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSidebarVisible)
        }
        .frame(maxHeight: .infinity)
        .onChange(of: selectedTab) { newTab in
            if newTab != nil && !isSidebarVisible {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    isSidebarVisible = true
                }
            }
        }
        .onAppear {
            self.sidebarWidth = fixedSidebarWidth
        }
    }
}
