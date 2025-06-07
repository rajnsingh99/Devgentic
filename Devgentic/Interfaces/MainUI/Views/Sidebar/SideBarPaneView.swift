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
                    if tab == .agents {
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
                    ExplorerView()
                        .environmentObject(viewModel)

                case .conversations:
                    ConversationListView()

                case .ollama:
                    // This view now correctly uses the shared service instance
                    // provided through the viewModel environment object.
                    OllamaSidebarView(sidebarWidth: $sidebarWidth)
                        .environmentObject(viewModel)

                case .promptLibrary:
                    Spacer()
                    Text("Prompt Library is open in a separate panel.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .agents:
                    AgentsTabView()
                        .environmentObject(viewModel)

                case .settings:
                    Spacer()
                    Text("Settings are open in a separate panel.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .user:
                    UserTabView()

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


// MARK: - Preview Provider
struct SideBarPaneView_Previews: PreviewProvider {
    // Helper function to create a MainApplicationViewModel for previews.
    // This now correctly uses the new initializer.
    static func createMockViewModel() -> MainApplicationViewModel {
        let profileStore = OllamaProfileStore()
        if profileStore.profiles.isEmpty {
            profileStore.profiles.append(OllamaProfileModel.defaultProfile())
            profileStore.selectedProfileID = profileStore.profiles.first?.id
        }
        let agentStore = AgentStore()
        if agentStore.agents.isEmpty {
            agentStore.agents.append(AgentProfileModel.defaultAgent())
        }
        
        // Correctly initialize without the OllamaService parameter
        return MainApplicationViewModel(
            ollamaProfileStore: profileStore,
            agentStore: agentStore
        )
    }

    static var previews: some View {
        let mockViewModel = createMockViewModel()

        Group {
            // Preview for Ollama Tab - Default State
            SideBarPaneView(selectedTab: .constant(.ollama), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .onAppear {
                    // For previews, we configure the state of the SHARED service instance
                    let service = OllamaService.shared
                    service.serverStatus = .connected
                    service.localModels = ["mistral:7b", "phi3:mini"]
                    service.isLoadingModels = false
                    service.isPullingModel = false
                    service.modelLoadingError = nil
                }
                .previewDisplayName("Ollama Pane (Connected)")

            // Preview for Ollama Tab - Disconnected State
            SideBarPaneView(selectedTab: .constant(.ollama), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .onAppear {
                    let service = OllamaService.shared
                    service.serverStatus = .disconnected
                    service.localModels = []
                    service.isLoadingModels = false
                }
                .previewDisplayName("Ollama Pane (Disconnected)")

            // Preview for Agents Tab
            SideBarPaneView(selectedTab: .constant(.agents), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .previewDisplayName("Agents Pane")
        }
        .frame(height: 600)
    }
}
