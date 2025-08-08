//
//  SideBarPaneView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SideBarPaneView")

struct SideBarPaneView: View {
    @Binding var selectedTab: SidebarTab?
    @Binding var sidebarWidth: CGFloat

    // --- THEME INTEGRATION ---
    // Access the ThemeManager from the environment.
    @EnvironmentObject var themeManager: ThemeManager
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    @State private var isHoveringSettingsButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header logic remains the same. We will refactor its text color.
            if let tab = selectedTab, tab != .explorer, tab != .conversations, tab != .promptLibrary, tab != .settings {
                HStack {
                    Text(tab.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.currentTheme.primaryText) // Use themed text color
                    
                    Spacer()
                    
                    if tab == .integration {
                        Button { openWindow(id: "llm-integrations") } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).onHover { isHoveringSettingsButton = $0 }.help("Manage Backend Profiles & Settings")
                            .foregroundColor(themeManager.currentTheme.secondaryText) // Use themed icon color
                    }
                }
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
                
                Divider()
                    .background(themeManager.currentTheme.dividerColor) // Use themed divider color
            }

            // --- Main Content ---
            VStack {
                switch selectedTab {
                case .newChat: NewChatTabView()
                case .explorer: ExplorerView()
                case .conversations: ConversationListView()
                case .integration: LLMIntegrationsSidebarView(sidebarWidth: $sidebarWidth)
                case .promptLibrary: PromptLibrarySidebarView() // ADDED: The new prompt library sidebar view
                case .settings, .user, .none:
                    Spacer()
                    Text(selectedTab?.title ?? "Nothing Selected")
                        .foregroundColor(themeManager.currentTheme.secondaryText) // Use themed text color
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // --- THEME INTEGRATION ---
        // Replace the hardcoded color with the theme's background color.
        .background(themeManager.currentTheme.secondaryBackground)
        .frame(maxHeight: .infinity)
    }
}


// MARK: - Preview Provider
struct SideBarPaneView_Previews: PreviewProvider {
    static func createMockViewModel() -> MainApplicationViewModel {
        let agentStore = AgentStore()
        if agentStore.agents.isEmpty {
            agentStore.agents.append(AgentProfileModel.defaultAgent())
        }
        // MODIFIED: Pass a ChatHistoryViewModel instance
        return MainApplicationViewModel(llmIntegrationStore: LLMIntegrationStore(), agentStore: agentStore, chatHistoryViewModel: ChatHistoryViewModel())
    }

    static var previews: some View {
        let mockViewModel = createMockViewModel()
        let mockToolStore = ToolStore()
        let themeManager = ThemeManager() // Create a theme manager for the preview

        Group {
            SideBarPaneView(selectedTab: .constant(.conversations), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .environmentObject(themeManager) // Inject into preview
                .onAppear {
                    // Switch to Dracula for this specific preview
                    if let dracula = themeManager.availableThemes.first(where: { $0.id == "dracula" }) {
                        themeManager.applyTheme(dracula)
                    }
                }
                .previewDisplayName("Conversations Pane (Dracula Theme)")
        }
        .frame(height: 600)
    }
}
