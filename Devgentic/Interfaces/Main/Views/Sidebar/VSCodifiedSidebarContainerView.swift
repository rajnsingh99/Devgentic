//
//  VSCodifiedSidebarContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
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
    
    private let minSidebarWidth: CGFloat = 300
    private let maxSidebarWidth: CGFloat = 400
    private let activityBarWidth: CGFloat = 50

    @State private var preferredWidths: [SidebarTab: CGFloat] = [
        .newChat: 300,
        .conversations: 350,
        .explorer: 350,
        .integration: 400,
        .promptLibrary: 400,
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
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                .frame(width: activityBarWidth)

            if isSidebarVisible {
                SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $sidebarWidth)
                    .frame(width: sidebarWidth)
                    .transition(.move(edge: .leading))

                // The draggable divider
                Divider()
                    .frame(width: 2)
                    // Change background based on hover state for better visual feedback
                    .background(isHoveringOnDivider ? Color.blue.opacity(0.5) : Color.gray.opacity(0.01))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let newWidth = self.sidebarWidth + value.translation.width
                                self.sidebarWidth = min(max(newWidth, self.minSidebarWidth), self.maxSidebarWidth)
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
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .onChange(of: selectedTab) { newTab in
            if let newTab = newTab, let newPreferredWidth = preferredWidths[newTab] {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.sidebarWidth = min(max(newPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
                }
            }
        }
        .onAppear {
            if let initialTab = selectedTab, let initialPreferredWidth = preferredWidths[initialTab] {
                self.sidebarWidth = min(max(initialPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
            }
        }
    }
}



