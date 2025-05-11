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
            // Show header only if a tab meant for this pane is selected
            if let tab = selectedTab, tab != .promptLibrary, tab != .settings {
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
                    NewChatTabView()
                        .environmentObject(viewModel)
                
                case .explorer:
                    ExplorerView() // Add the new ExplorerView
                        .environmentObject(viewModel)

                case .conversations:
                    // Assuming ConversationListView is defined and uses EnvironmentObject
                    ConversationListView()

                case .localModels:
                    LocalModelDiscoveryGridView(
                        ollamaService: viewModel.ollamaService,
                        mainViewModel: viewModel
                    )
                
                // MARK: - Added case for promptLibrary
                // This case should ideally not be hit if ActivityBarButton logic is correct,
                // as .promptLibrary opens a panel, not this pane.
                // Adding it to make the switch exhaustive.
                case .promptLibrary:
                    Spacer() // Or EmptyView(). The prompt library is a separate panel.
                    Text("Prompt Library is open in a separate panel.") // Placeholder if needed
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)


                case .agents:
                    AgentsTabView()

                case .settings:
                    // Settings also opens as a separate panel.
                    // This case in SideBarPaneView might be redundant if selectedTab is never set to .settings.
                    Spacer() // Or EmptyView(). Settings is a separate panel.
                    Text("Settings are open in a separate panel.") // Placeholder if needed
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)


                case .user:
                    UserTabView()

                case .none:
                    Spacer() // Fill space if nothing is selected (sidebar pane is hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .frame(maxHeight: .infinity)
    }
}

// Assuming ConversationListView, NewChatTabView, AgentsTabView, UserTabView are defined
// and use @EnvironmentObject var viewModel: MainApplicationViewModel where needed.
// LocalModelDiscoveryGridView is passed viewModel and ollamaService directly.

// MARK: - Preview Provider
struct SideBarPaneView_Previews: PreviewProvider {
    // Container to manage state and ViewModel creation for preview
    struct PreviewContainer: View {
        @State var selectedTab: SidebarTab? = .conversations

        static let defaultOllamaService: OllamaService = {
            let service = OllamaService()
            return service
        }()

        static let modelsOllamaService: OllamaService = {
            let service = OllamaService()
            service.localModels = ["mistral:7b", "phi3:mini"]
            service.serverStatus = .connected
            return service
        }()

        let convoViewModel: MainApplicationViewModel = MainApplicationViewModel(ollamaService: defaultOllamaService)
        let modelsViewModel: MainApplicationViewModel = MainApplicationViewModel(ollamaService: modelsOllamaService)
        
        init() {
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
                .frame(width: 120) // Increased width for better readability of tab titles
                .padding()

                SideBarPaneView(selectedTab: $selectedTab)
                    .environmentObject(selectedTab == .localModels ? modelsViewModel : convoViewModel)
                    .frame(width: 350)
            }
            .frame(height: 600)
        }
    }

    static var previews: some View {
        PreviewContainer()
            .previewDisplayName("Side Bar Pane (Interactive)")
    }
}
