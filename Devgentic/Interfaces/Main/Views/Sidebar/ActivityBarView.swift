//
//  CommandCentreView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI

struct ActivityBarView: View {
    // Binding to the selected tab state in the container view
    @Binding var selectedTab: SidebarTab?
    // Binding to the sidebar visibility state in the container view
    @Binding var isSidebarVisible: Bool

    // Define the order of top icons explicitly, including the Prompt Library
    private let topTabs: [SidebarTab] = [.newChat, .conversations, .explorer, .integration, .promptLibrary]
    // Define the order of bottom icons explicitly
    private let bottomTabs: [SidebarTab] = [.settings, .user]


    var body: some View {
        VStack(spacing: 0) { // No vertical space between buttons initially
            // --- Top Icons ---
            ForEach(topTabs) { tab in
                ActivityBarButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    isSidebarVisible: $isSidebarVisible
                )
            }

            Spacer() // Pushes the bottom icons down

            // --- Bottom Icons ---
            ForEach(bottomTabs) { tab in
                ActivityBarButton(
                    tab: tab,
                    selectedTab: $selectedTab,
                    isSidebarVisible: $isSidebarVisible
                )
            }
        }
        .frame(width: 50) // Fixed width for the Activity Bar
        .padding(.vertical, 10) // Add some padding at the top and bottom
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        .frame(maxHeight: .infinity)
    }
}
