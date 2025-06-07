//
//  AgentsTabView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

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
                                .environmentObject(viewModel)
                                .padding(.horizontal)
                                .onTapGesture {
                                    // **[NEW]** Single tap to select the agent
                                    viewModel.selectedAgentID = agent.id
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

// MARK: - AgentRowView (Updated)
struct AgentRowView: View {
    let agent: Agent
    @EnvironmentObject var viewModel: MainApplicationViewModel

    private var linkedOllamaProfile: OllamaProfile? {
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
            Spacer() // Pushes content to the left
            
            // **[NEW]** Show a checkmark if the agent is active
            if agent.isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title2)
            }
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(10)
        .overlay(
            // **[NEW]** Add a green border if the agent is active
            RoundedRectangle(cornerRadius: 10)
                .stroke(agent.isActive ? Color.green : Color.clear, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.15), radius: 3, x: 0, y: 1)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: agent.isActive) // Animate the border change
    }
}

// MARK: - Preview Provider
struct AgentsTabView_Previews: PreviewProvider {
    static var previews: some View {
        let mockOllamaProfileStore: OllamaProfileStore = {
            let store = OllamaProfileStore()
            let defaultProfile = OllamaProfile.defaultProfile()
            let remoteProfile = OllamaProfile(
                id: UUID(),
                profileName: "Remote Ollama",
                baseURL: "http://remote:11434",
                llmModelName: "llama3:8b",
                temperature: 0.7, topK: 30, topP: 0.8, repeatPenalty: 1.0, contextWindowSize: 2048, gpuLayers: 0,
                maxInlineChars: 2000, maxAttachedFiles: 2, textFileInclusionStrategy: .preferInlining, imageHandlingStrategy: .includePathWithWarning, binaryFileHandlingStrategy: .includePathWithWarning
            )
            store.profiles = [defaultProfile, remoteProfile]
            store.selectedProfileID = defaultProfile.id
            return store
        }()

        let mockAgentStore: AgentStore = {
            let store = AgentStore()
            var defaultAgent = Agent.defaultAgent()
            defaultAgent.isActive = true // Make the first one active for the preview
            let testAgent = Agent(id: UUID(), name: "Test Agent", description: "Another agent for testing.", isActive: false, baseURL: "http://test:8000", linkedOllamaProfileID: mockOllamaProfileStore.profiles[1].id, selectedAgentTool: "Web Search")
            let inactiveAgent = Agent(id: UUID(), name: "Inactive Agent", description: "This agent is not active.", isActive: false, baseURL: "http://inactive:8000", linkedOllamaProfileID: nil, selectedAgentTool: "None")
            store.agents = [defaultAgent, testAgent, inactiveAgent]
            return store
        }()

        let mockOllamaService = OllamaService()

        let mockMainApplicationViewModel = MainApplicationViewModel(
            ollamaService: mockOllamaService,
            ollamaProfileStore: mockOllamaProfileStore,
            agentStore: mockAgentStore
        )

        AgentsTabView()
            .environmentObject(mockMainApplicationViewModel)
            .frame(width: 350, height: 500)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Agents Tab View")
    }
}
