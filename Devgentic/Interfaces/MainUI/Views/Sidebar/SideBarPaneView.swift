// Views/Sidebar/SideBarPaneView.swift (Updated)
import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "SideBarPaneView")

// MARK: - Side Bar Pane View
/// The wider pane displayed to the right of the Activity Bar.
/// Its content changes based on the selected Activity Bar tab.
struct SideBarPaneView: View {
    // Binding to the selected tab state from the container view
    @Binding var selectedTab: SidebarTab?

    // Access to the shared ViewModel (passed via environment from container)
    @EnvironmentObject var viewModel: MainApplicationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // Use a VStack for vertical layout
            // --- Header ---
            // Display the title of the currently selected tab
            if let tab = selectedTab {
                Text(tab.title)
                    .font(.title3) // Slightly smaller title
                    .fontWeight(.semibold)
                    .padding(.horizontal)
                    .padding(.top, 12) // Add padding top/bottom
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading) // Align left
                Divider() // Separator below the header
            }

            // --- Content Area ---
            // Use a switch statement to display the appropriate view based on the selected tab
            // Wrap the content in a frame that takes maximum available space
             VStack { // Added VStack to contain the switched content
                switch selectedTab {
                case .newChat:
                    // Keep the NewChatTabView placeholder/implementation
                    NewChatTabView()
                        .environmentObject(viewModel) // Ensure it gets the ViewModel

                case .conversations:
                    // *** INTEGRATED: Use the modified ConversationListView ***
                    // Ensure the modified ConversationListView doesn't have its own
                    // background or fixed frame anymore.
                    ConversationListView()
                        // It already uses @EnvironmentObject, so it should pick up the viewModel
                        // No need to pass onNewConversation

                case .localModels:
                    // *** INTEGRATED: Use the new LocalModelDiscoveryGridView ***
                    LocalModelDiscoveryGridView()
                        // It also uses @EnvironmentObject

                case .agents:
                    // Keep the AgentsTabView placeholder
                    AgentsTabView()

                case .settings:
                    // Keep the SettingsTabView placeholder
                    SettingsTabView()

                case .user:
                    // Keep the UserTabView placeholder
                    UserTabView()

                case .none:
                    // View to display if no tab is selected (e.g., when sidebar is hidden)
                    Spacer() // Fill space if nothing is selected
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Ensure content area fills space

        }
        // Use a standard control background color that adapts to light/dark mode
        .background(Color(NSColor.controlBackgroundColor))
        // Ensure the pane takes the full available height
        .frame(maxHeight: .infinity)
    }
}

// MARK: - Placeholder Content Views (Keep remaining placeholders)
// These views (NewChatTabView, AgentsTabView, SettingsTabView, UserTabView)
// remain as defined in Phase 1 for now, unless already implemented.

// Assuming NewChatTabView, AgentsTabView, SettingsTabView, UserTabView
// are defined as in the previous step (Phase 1 code block).
// If not, they would need to be included here as well.


// MARK: - Preview Provider
#Preview {
    // Container to manage state and ViewModel creation *inside* the struct
    // This resolves the "cannot close over value" error.
    struct PreviewContainer: View {
        @State var selectedTab: SidebarTab? = .conversations // Start with conversations tab

        // Define ViewModels *inside* the PreviewContainer struct
        let convoViewModel: MainApplicationViewModel = {
            let vm = MainApplicationViewModel()
            vm.conversations = [
                Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Preview Chat 1"),
                Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Preview Chat 2")
            ]
            vm.selectedConversationID = vm.conversations[0].id
            return vm
        }()

        let modelsViewModel: MainApplicationViewModel = {
            let vm = MainApplicationViewModel()
            vm.localOllamaModels = ["mistral:7b"]
            vm.ollamaServerStatus = .connected
            return vm
        }()

        var body: some View {
            HStack(spacing: 0) {
                // Mock Activity Bar to change selection
                VStack {
                    ForEach(SidebarTab.allCases) { tab in
                        Button(tab.title) { selectedTab = tab }
                            .padding(.bottom, 5)
                    }
                    Spacer()
                }
                .frame(width: 100)
                .padding()

                // The SideBarPaneView being previewed
                SideBarPaneView(selectedTab: $selectedTab)
                    // Provide the appropriate ViewModel based on selected tab for preview
                    // Use the ViewModels defined within this struct
                    .environmentObject(selectedTab == .localModels ? modelsViewModel : convoViewModel)
                    .frame(width: 300) // Simulate pane width
            }
        }
    }

    // Return the PreviewContainer instance
    return PreviewContainer()
        .frame(height: 600)
        .previewDisplayName("Side Bar Pane (Interactive)")

}
