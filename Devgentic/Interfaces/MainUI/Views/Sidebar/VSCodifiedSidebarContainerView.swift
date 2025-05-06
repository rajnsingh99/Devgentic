// Views/Sidebar/VSCodifiedSidebarContainerView.swift (Pane Animation)
import SwiftUI
import Combine
import os

// Logger (Optional)
// private let logger = Logger(...)

// MARK: - Main Sidebar Container View
struct VSCodifiedSidebarContainerView: View {
    // --- State Management ---
    // Selected tab remains internal state
    @State private var selectedTab: SidebarTab? = .conversations

    // *** Use @Binding for isSidebarVisible ***
    @Binding var isSidebarVisible: Bool

    // Access to the shared ViewModel (assuming it's passed via environment)
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // No explicit init() needed, the memberwise initializer will be synthesized

    var body: some View {
        HStack(spacing: 0) {
            // --- Activity Bar (Icon Bar) ---
            // Always present, provides its own background
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)

            // --- Side Bar Pane (Content Area) ---
            // Conditionally display the pane based on the binding
            if isSidebarVisible {
                SideBarPaneView(selectedTab: $selectedTab)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
                    // Apply transition directly to the pane for slide effect
                    .transition(.move(edge: .leading))
                    // *** Apply animation directly to the pane ***
                    // This controls the timing of the transition for this specific view
                    .animation(.easeInOut(duration: 0.3), value: isSidebarVisible)
            }
        }
        // *** REMOVED Animation modifier from HStack ***
        // The animation is now handled directly by the SideBarPaneView
        // .animation(.easeInOut(duration: 0.3), value: isSidebarVisible)
        .frame(maxHeight: .infinity)
        // Background is handled by ActivityBarView and SideBarPaneView individually
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9)) // Keep background for Activity Bar area when pane is hidden
    }
}

// MARK: - Preview Provider for VSCodifiedSidebarContainerView
#Preview {
    // Need a state variable in the preview wrapper to hold the binding
    struct PreviewWrapper: View {
        @State var sidebarVisible = true // State for the binding
        @StateObject var vm = MainApplicationViewModel() // Dummy VM

        var body: some View {
             HStack { // Add HStack for button + sidebar preview
                 VStack { // Buttons to toggle visibility
                      Button("Toggle Sidebar") {
                           // Use withAnimation here to trigger the transition smoothly in preview
                           // Match the duration used in the main view's animation modifier
                           // IMPORTANT: withAnimation block is needed here to trigger the transition/animation
                           withAnimation(.easeInOut(duration: 0.3)) {
                                sidebarVisible.toggle()
                           }
                      }
                      Spacer()
                 }
                 .padding()

                 VSCodifiedSidebarContainerView(isSidebarVisible: $sidebarVisible)
                     .environmentObject(vm)
                     // Add a background to the *preview* container for visibility
                     .background(Color.gray.opacity(0.3))
             }
        }
    }
    return PreviewWrapper()
        .frame(width: 500, height: 600) // Wider frame to see effect
        .previewDisplayName("Sidebar Container (Pane Animation)")
}

// Assume SidebarTab, ActivityBarView, SideBarPaneView are defined elsewhere correctly.
