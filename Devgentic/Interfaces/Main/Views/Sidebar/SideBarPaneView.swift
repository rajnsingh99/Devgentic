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

    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    @State private var isHoveringSettingsButton = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // --- Updated Header ---
            // The header is now only displayed for tabs that are NOT .conversations.
            if let tab = selectedTab, tab != .conversations, tab != .promptLibrary, tab != .settings {
                HStack {
                    Text(tab.title).font(.title3).fontWeight(.semibold)
                    Spacer()
                    if tab == .agents {
                        Button { openWindow(id: "agent-config") } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).onHover { isHoveringSettingsButton = $0 }.help("Agent Settings")
                    } else if tab == .ollama {
                        Button { openWindow(id: "llm-integrations") } label: { Image(systemName: "gearshape") }
                            .buttonStyle(.plain).onHover { isHoveringSettingsButton = $0 }.help("Manage Ollama Profiles & Settings")
                    }
                }
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 8)
                Divider()
            }

            // --- Main Content ---
            VStack {
                switch selectedTab {
                case .newChat: NewChatTabView()
                case .explorer: ExplorerView()
                case .conversations: ConversationListView() // This view now contains its own search bar
                case .ollama: LLMIntegrationsSidebarView(sidebarWidth: $sidebarWidth)
                case .agents: AgentsTabView()
                case .promptLibrary, .settings, .user, .none:
                    Spacer()
                    Text(selectedTab?.title ?? "Nothing Selected").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .environmentObject(viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(NSColor.controlBackgroundColor))
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
        
        return MainApplicationViewModel(
            llmIntegrationStore: LLMIntegrationStore(),
            agentStore: agentStore
        )
    }

    static var previews: some View {
        let mockViewModel = createMockViewModel()
        let mockToolStore = ToolStore()

        Group {
            // Preview for a tab with a header (e.g., Agents)
            SideBarPaneView(selectedTab: .constant(.agents), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .environmentObject(mockToolStore)
                .previewDisplayName("Agents Pane (With Header)")

            // Preview for the Conversations tab (no header)
            SideBarPaneView(selectedTab: .constant(.conversations), sidebarWidth: .constant(350))
                .environmentObject(mockViewModel)
                .previewDisplayName("Conversations Pane (No Header)")
        }
        .frame(height: 600)
    }
}
