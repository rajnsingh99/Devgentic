//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

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
    // Binding to the sidebarWidth
    @Binding var sidebarWidth: CGFloat

    // Access to the shared ViewModel (passed via environment from container)
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow // To open new windows for settings

    // MARK: - Initializer to accept sidebarWidth binding
    init(selectedTab: Binding<SidebarTab?>, sidebarWidth: Binding<CGFloat>) {
        self._selectedTab = selectedTab
        self._sidebarWidth = sidebarWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { // Use a VStack for vertical layout
            // --- Header ---
            // Show header only if a tab meant for this pane is selected
            if let tab = selectedTab, tab != .promptLibrary, tab != .settings {
                HStack { // Added HStack for title and settings button
                    Text(tab.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    // Add settings button for specific tabs
                    if tab == .agents { // MARK: New: Agent settings button
                        Button {
                            openWindow(id: "agent-settings")
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.plain)
                        .help("Agent Settings")
                    }
                }
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

                case .ollama:
                    // MARK: - UPDATED: Using the new OllamaSidebarView
                    OllamaSidebarView(sidebarWidth: $sidebarWidth)
                    // The viewModel is already available from the parent's environment

                case .promptLibrary:
                    Spacer() // Or EmptyView(). The prompt library is a separate panel.
                    Text("Prompt Library is open in a separate panel.") // Placeholder if needed
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)


                case .agents:
                    AgentsTabView() // MARK: AgentsTabView now directly displayed
                        .environmentObject(viewModel) // Ensure viewModel is passed

                case .settings:
                    // Settings also opens as a separate panel.
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

// Preview Provider would remain the same, but ensure you add OllamaSidebarView to your project
// so the preview can compile.
struct SideBarPaneView_Previews: PreviewProvider {
    // Container to manage state and ViewModel creation for preview
    struct PreviewContainer: View {
        @State var selectedTab: SidebarTab? = .ollama // Set initial tab to ollama for preview
        @State var previewSidebarWidth: CGFloat = 350 // Define a width for the preview

        static let mockOllamaService: OllamaService = {
            let service = OllamaService()
            service.localModels = ["mistral:7b", "phi3:mini", "my-custom-model:latest"]
            service.serverStatus = .connected
            return service
        }()

        static let mockOllamaProfileStore: OllamaProfileStore = {
            let store = OllamaProfileStore()
            // Ensure there's at least one profile for the view model to use
            if store.profiles.isEmpty {
                var defaultProfile = OllamaProfile.defaultProfile()
                defaultProfile.llmModelName = "mistral:7b" // Make one model active
                store.profiles.append(defaultProfile)
                store.selectedProfileID = store.profiles.first?.id
            }
            return store
        }()
        
        static let mockAgentStore: AgentStore = {
            let store = AgentStore()
            if store.agents.isEmpty {
                store.agents.append(Agent.defaultAgent())
            }
            return store
        }()

        let mainViewModel: MainApplicationViewModel = MainApplicationViewModel(
            ollamaService: mockOllamaService,
            ollamaProfileStore: mockOllamaProfileStore,
            agentStore: mockAgentStore
        )
        
        var body: some View {
            SideBarPaneView(selectedTab: $selectedTab, sidebarWidth: $previewSidebarWidth)
                .environmentObject(mainViewModel)
                .frame(width: previewSidebarWidth, height: 600)
        }
    }

    static var previews: some View {
        PreviewContainer()
            .previewDisplayName("Side Bar Pane (Ollama)")
    }
}
