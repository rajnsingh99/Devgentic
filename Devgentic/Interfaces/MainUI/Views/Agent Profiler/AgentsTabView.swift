// AgentsTabView.swift
import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentTabView")

// MARK: - AgentsTabView
struct AgentsTabView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                if viewModel.agentStore.agents.isEmpty {
                    Text("No agents configured yet. Add a new agent to get started.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    VStack(spacing: 10) {
                        ForEach(viewModel.agentStore.agents) { agent in
                            AgentRowView(agent: agent)
                                .padding(.horizontal)
                                .onTapGesture {
                                    // Use the new centralized selection property
                                    viewModel.agentStore.selectedAgentID = agent.id
                                }
                                .onTapGesture(count: 2) {
                                    logger.info("Double-tapped agent: \(agent.name). Opening Agent Profiler for ID: \(agent.id.uuidString)")
                                    openWindow(id: "agent-settings", value: agent.id)
                                }
                        }
                    }
                    .padding(.vertical)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AgentRowView
struct AgentRowView: View {
    let agent: AgentProfileModel
    @EnvironmentObject var viewModel: MainApplicationViewModel

    // Check if this agent is the currently selected one
    private var isAgentActive: Bool {
        viewModel.agentStore.selectedAgentID == agent.id
    }

    private var linkedOllamaProfile: OllamaProfileModel? {
        if let profileID = agent.linkedOllamaProfileID {
            return viewModel.ollamaProfileStore.profiles.first(where: { $0.id == profileID })
        }
        return nil
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundColor(.primary)

                if let profile = linkedOllamaProfile {
                    Text("\(profile.profileName) - \(profile.llmModelName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("No Ollama profile linked")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            
            // Display checkmark if the agent is active
            if isAgentActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isAgentActive ? Color.blue : Color.gray.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isAgentActive)
    }
}

// MARK: - Preview Provider (FIXED)

struct AgentsTabView_Previews: PreviewProvider {
    // 1. Create a static, fully configured mock view model.
    // This separates data setup from the View return, fixing the build error.
    static var mockViewModel: MainApplicationViewModel = {
        // Create mock stores. For previews, we don't need real persistence.
        let ollamaProfileStore = OllamaProfileStore()
        let agentStore = AgentStore()
        
        // Create a mock ollama profile to link to an agent
        let mockOllamaProfile = OllamaProfileModel(
            id: UUID(),
            profileName: "Local Llama 3",
            baseURL: "http://localhost:11434",
            llmModelName: "llama3:8b",
            temperature: 0.8, topK: 40, topP: 0.9, repeatPenalty: 1.1, contextWindowSize: 4096, gpuLayers: -1, maxInlineChars: 5000, maxAttachedFiles: 5, textFileInclusionStrategy: .preferInlining, imageHandlingStrategy: .includePathWithWarning, binaryFileHandlingStrategy: .includePathWithWarning
        )
        ollamaProfileStore.profiles = [mockOllamaProfile]

        // Create mock agents
        let agent1 = AgentProfileModel(id: UUID(), name: "Developer Agent", role: "Your personal development assistant.", baseURL: "http://localhost:8000", linkedOllamaProfileID: mockOllamaProfile.id, tools: [])
        let agent2 = AgentProfileModel(id: UUID(), name: "Research Assistant", role: "Helps with research and data gathering.", baseURL: "http://localhost:8001", linkedOllamaProfileID: nil, tools: [])
        
        // Populate the agent store
        agentStore.agents = [agent1, agent2]
        agentStore.selectedAgentID = agent1.id // Set the first agent as active for the preview

        // Create the main view model with the mock stores
        let viewModel = MainApplicationViewModel(
            ollamaProfileStore: ollamaProfileStore,
            agentStore: agentStore
        )
        return viewModel
    }()

    // 2. The previews property simply returns the view with the mock data.
    // This structure is clean and reliable for SwiftUI Previews.
    static var previews: some View {
        AgentsTabView()
            .environmentObject(mockViewModel)
            .frame(width: 350, height: 500)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Agents Tab View")
    }
}
