// Views/Sidebar/VSCodifiedSidebarContainerView.swift (Corrected Binding)
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

    // *** CORRECTED: Use @Binding for isSidebarVisible ***
    // This allows the parent view (MainApplicationView) to control visibility
    @Binding var isSidebarVisible: Bool

    // Access to the shared ViewModel (assuming it's passed via environment)
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // No explicit init() needed, the memberwise initializer will be synthesized

    var body: some View {
        HStack(spacing: 0) {
            // --- Activity Bar (Icon Bar) ---
            // Pass the bindings down
            ActivityBarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible)

            // --- Side Bar Pane (Content Area) ---
            // Conditionally display the pane based on the binding
            if isSidebarVisible {
                SideBarPaneView(selectedTab: $selectedTab)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 400)
                    .transition(.move(edge: .leading))
            }
        }
        // Animation remains the same
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
        .frame(maxHeight: .infinity)
        // Ensure the background is set correctly, especially when pane is hidden
        .background(Color(NSColor.windowBackgroundColor).opacity(0.9)) // Background for Activity Bar area
    }
}

// MARK: - Preview Provider for VSCodifiedSidebarContainerView
#Preview {
    // Need a state variable in the preview wrapper to hold the binding
    struct PreviewWrapper: View {
        @State var sidebarVisible = true // State for the binding
        @StateObject var vm = MainApplicationViewModel() // Dummy VM

        var body: some View {
            // Now the call matches the expected initializer
            VSCodifiedSidebarContainerView(isSidebarVisible: $sidebarVisible)
                .environmentObject(vm)
        }
    }
    return PreviewWrapper()
        .frame(width: 400, height: 600)
        .previewDisplayName("Sidebar Container (Corrected Binding)")
}

// Assume SidebarTab, ActivityBarView, SideBarPaneView are defined elsewhere correctly.
