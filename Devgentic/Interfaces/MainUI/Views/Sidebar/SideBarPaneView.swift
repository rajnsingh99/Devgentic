// Views/Sidebar/SideBarPaneView.swift
import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

// MARK: - Side Bar Pane View
/// The wider pane displayed to the right of the Activity Bar.
/// Its content changes based on the selected Activity Bar tab.
struct SideBarPaneView: View {
    // Binding to the selected tab state from the container view
    @Binding var selectedTab: SidebarTab?

    // Access to the shared ViewModel (passed via environment from container)
    // This viewModel instance now contains an ollamaService property.
    @EnvironmentObject var viewModel: MainApplicationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // Use a VStack for vertical layout
            // --- Header ---
            if let tab = selectedTab {
                Text(tab.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }

            // --- Content Area ---
             VStack {
                switch selectedTab {
                case .newChat:
                    NewChatTabView() // Assuming this view uses EnvironmentObject or is self-contained
                        .environmentObject(viewModel)


                case .conversations:
                    ConversationListView() // Assuming this view uses EnvironmentObject
                                           // and doesn't need ollamaService directly.

                case .localModels:
                    // *** UPDATED: Pass MainApplicationViewModel's OllamaService instance ***
                    LocalModelDiscoveryGridView(
                        ollamaService: viewModel.ollamaService, // Pass the service from MainViewModel
                        mainViewModel: viewModel                // Pass the MainViewModel itself
                    )
                    // No need to .environmentObject(viewModel) here if LocalModelDiscoveryGridView
                    // takes viewModel as an @ObservedObject as designed.

                case .agents:
                    AgentsTabView() // Assuming this view uses EnvironmentObject or is self-contained

                case .settings:
                    SettingsTabView() // Assuming this view uses EnvironmentObject or is self-contained

                case .user:
                    UserTabView() // Assuming this view uses EnvironmentObject or is self-contained

                case .none:
                    Spacer() // Fill space if nothing is selected
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxHeight: .infinity)
    }
}

// Assuming ConversationListView is defined elsewhere and uses @EnvironmentObject var viewModel: MainApplicationViewModel
// Assuming LocalModelDiscoveryGridView is defined as per the refactored version.

// MARK: - Preview Provider
struct SideBarPaneView_Previews: PreviewProvider {
    // Define a simple SidebarTab enum for preview context if not globally available
    enum PreviewSidebarTab: String, CaseIterable, Identifiable {
        case newChat, conversations, localModels, agents, settings, user
        var id: String { self.rawValue }
        var title: String { self.rawValue.capitalized }
    }
    
    // Container to manage state and ViewModel creation for preview
    struct PreviewContainer: View {
        @State var selectedTab: SidebarTab? = .conversations

        // Create OllamaService instances for different preview scenarios
        static let defaultOllamaService: OllamaService = {
            let service = OllamaService()
            // Configure service for default/conversation view if needed
            return service
        }()

        static let modelsOllamaService: OllamaService = {
            let service = OllamaService()
            service.localModels = ["mistral:7b", "phi3:mini"]
            service.serverStatus = .connected
            return service
        }()

        // Create MainApplicationViewModel instances, injecting the appropriate OllamaService
        let convoViewModel: MainApplicationViewModel = MainApplicationViewModel(ollamaService: defaultOllamaService)
        let modelsViewModel: MainApplicationViewModel = MainApplicationViewModel(ollamaService: modelsOllamaService)
        
        init() {
            // Further configure convoViewModel if needed for conversation previews
            convoViewModel.conversations = [
                Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Preview Chat 1"),
                Conversation(id: UUID(), messages: [], timestamp: Date(), userDefinedTitle: "Preview Chat 2")
            ]
            if !convoViewModel.conversations.isEmpty {
                convoViewModel.selectedConversationID = convoViewModel.conversations[0].id
            }
        }


        var body: some View {
            HStack(spacing: 0) {
                VStack {
                    ForEach(SidebarTab.allCases) { tab in
                        Button(tab.title) { selectedTab = tab }
                            .padding(.bottom, 5)
                    }
                    Spacer()
                }
                .frame(width: 100)
                .padding()

                SideBarPaneView(selectedTab: $selectedTab)
                    // Provide the MainApplicationViewModel. It holds the correct OllamaService.
                    // The views inside SideBarPaneView will then receive the correct instances.
                    .environmentObject(selectedTab == .localModels ? modelsViewModel : convoViewModel)
                    .frame(width: 350) // Simulate pane width
            }
            .frame(height: 600)
        }
    }

    static var previews: some View {
        PreviewContainer()
            .previewDisplayName("Side Bar Pane (Interactive)")
    }
}
