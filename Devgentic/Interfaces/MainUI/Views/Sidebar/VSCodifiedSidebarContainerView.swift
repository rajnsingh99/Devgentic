// VSCodifiedSidebarContainerView.swift
//
//  VSCodifiedSidebarContainerView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import Combine
import os

// Logger (Optional)
// private let logger = Logger(...)

// MARK: - Main Sidebar Container View
struct VSCodifiedSidebarContainerView: View {
    // --- State Management ---
    @State private var selectedTab: SidebarTab? = .conversations // Initial tab
    @Binding var isSidebarVisible: Bool

    // *** Use @Binding for sidebarWidth, passed from the parent (MainApplicationView) ***
    @Binding var sidebarWidth: CGFloat
    
    private let minSidebarWidth: CGFloat = 300
    private let maxSidebarWidth: CGFloat = 1000 // You can adjust this as needed
    private let activityBarWidth: CGFloat = 50

    // MARK: - New: Preferred widths for different tabs
    @State private var preferredWidths: [SidebarTab: CGFloat] = [
        .newChat: 300,
        .conversations: 300,
        .explorer: 300,
        .localModels: 500, // Custom wider width for local models
        .agents: 300,
        .promptLibrary: 300,
        .settings: 300,
        .user: 300
    ]

    // Access to the shared ViewModel
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // Explicit initializer now required due to the @Binding
    init(isSidebarVisible: Binding<Bool>, sidebarWidth: Binding<CGFloat>) {
        self._isSidebarVisible = isSidebarVisible
        self._sidebarWidth = sidebarWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            // --- Activity Bar (Icon Bar) ---
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)
                .frame(width: activityBarWidth)

            // --- Side Bar Pane (Content Area) & Draggable Divider ---
            // These are only added to the view if the sidebar is visible.
            if isSidebarVisible {
                SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $sidebarWidth) // MARK: Fix: Pass sidebarWidth
                    .frame(width: sidebarWidth) // Use the bound sidebarWidth
                    // Apply transition for visibility toggle
                    .transition(.move(edge: .leading))
                    // Animation for visibility toggle should be on the parent's control of isSidebarVisible

                // --- Draggable Divider ---
                // This divider and its gesture are only present when isSidebarVisible is true.
                Divider()
                    .frame(width: 8) // Increased width for easier touch/drag target
                    .background(Color.gray.opacity(0.01)) // Make it almost invisible but ensure it has a background for hit testing
                    .contentShape(Rectangle()) // Ensure the whole area is draggable
                    .gesture(
                        DragGesture(minimumDistance: 1) // Start drag after 1 point of movement
                            .onChanged { value in
                                let newWidth = self.sidebarWidth + value.translation.width
                                // Apply constraints directly to the binding
                                self.sidebarWidth = min(max(newWidth, self.minSidebarWidth), self.maxSidebarWidth)
                            }
                            // No .onEnded needed unless you want to persist the width or something
                    )
                    // The animation for resizing will be handled by MainApplicationView reacting to sidebarWidth changes
            }
        }
        .frame(maxHeight: .infinity)
        // The background for the activity bar area when the pane is hidden,
        // or the combined background when visible.
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
        // Animation for the overall container size change (due to sidebarWidth)
        // will be handled by MainApplicationView.
        // MARK: - New: Update sidebarWidth when selectedTab changes
        .onChange(of: selectedTab) { newTab in
            if let newTab = newTab, let newPreferredWidth = preferredWidths[newTab] {
                withAnimation(.easeInOut(duration: 0.2)) { // Optional: animate width change
                    self.sidebarWidth = min(max(newPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
                }
            } else if newTab == nil { // If no tab is selected, perhaps revert to a default or hide (if not already handled by isSidebarVisible)
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.sidebarWidth = self.minSidebarWidth // Or any default width when no tab is selected
                }
            }
        }
        // MARK: - New: Set initial sidebar width on appear
        .onAppear {
            if let initialTab = selectedTab, let initialPreferredWidth = preferredWidths[initialTab] {
                self.sidebarWidth = min(max(initialPreferredWidth, self.minSidebarWidth), self.maxSidebarWidth)
            }
        }
    }
}

// MARK: - Preview Provider for VSCodifiedSidebarContainerView
#Preview {
    struct PreviewWrapper: View {
        @State var sidebarVisible = true
        @State var currentSidebarWidth: CGFloat = 280 // Default width for preview
        // Fix: Provide mock OllamaProfileStore to MainApplicationViewModel
        @StateObject var vm = MainApplicationViewModel(
            ollamaService: OllamaService(), // Mock OllamaService
            ollamaProfileStore: OllamaProfileStore() // Mock OllamaProfileStore
        )

        var body: some View {
             HStack(spacing: 0) {
                 VStack {
                      Button("Toggle Sidebar") {
                           withAnimation(.easeInOut(duration: 0.2)) { // Match animation duration
                                sidebarVisible.toggle()
                           }
                      }
                      Text("Current Width: \(currentSidebarWidth, specifier: "%.0f")")
                      Spacer()
                 }
                 .padding()
                 .frame(width: 150)


                 VSCodifiedSidebarContainerView(
                    isSidebarVisible: $sidebarVisible,
                    sidebarWidth: $currentSidebarWidth // Pass the binding
                 )
                 .environmentObject(vm)
                 .background(Color.gray.opacity(0.3)) // Background for the sidebar container in preview
                 
                 // Simulate main content area
                 VStack {
                     Text("Main Content")
                 }
                 .frame(maxWidth: .infinity, maxHeight: .infinity)
                 .background(Color.blue.opacity(0.2))
             }
             .frame(width: 800, height: 600)
             .previewDisplayName("Resizable Sidebar Container")
        }
    }
    return PreviewWrapper()
}
