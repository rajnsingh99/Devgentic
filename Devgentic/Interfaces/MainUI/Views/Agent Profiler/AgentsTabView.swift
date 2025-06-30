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

    private var isAgentActive: Bool {
        viewModel.agentStore.selectedAgentID == agent.id
    }

    // --- MODIFIED: This now fetches from the new LLMIntegrationStore ---
    private var linkedIntegration: LLMIntegrationModel? {
        if let integrationID = agent.linkedIntegrationID {
            // Use the new llmIntegrationStore from the viewModel
            return viewModel.llmIntegrationStore.integrations.first { $0.id == integrationID }
        }
        return nil
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundColor(.primary)

                // --- MODIFIED: Updated logic to display info from the new model ---
                if let integration = linkedIntegration {
                    // Display the integration's display name and the specific model name
                    let modelName = integration.ollamaModelName ?? integration.remoteModelName ?? "N/A"
                    Text("\(integration.displayName) - \(modelName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text("No LLM integration linked")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            
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

// MARK: - Preview Provider (Updated for new data model)
struct AgentsTabView_Previews: PreviewProvider {
    static var mockViewModel: MainApplicationViewModel = {
        // --- MODIFIED: Create mock LLMIntegrationStore ---
        let llmIntegrationStore = LLMIntegrationStore()
        let agentStore = AgentStore()
        
        // Create a mock LLM integration to link to an agent
        let mockIntegration = LLMIntegrationModel(
            id: UUID(),
            displayName: "Local Llama 3",
            providerType: .ollama,
            ollamaBaseURL: "http://localhost:11434",
            ollamaModelName: "llama3:8b"
        )
        llmIntegrationStore.integrations = [mockIntegration]

        // Create mock agents and link them to the new integration
        let agent1 = AgentProfileModel(
            id: UUID(),
            name: "Developer Agent",
            role: "Your personal development assistant.",
            baseURL: "http://localhost:8000",
            // --- MODIFIED: Use new property name ---
            linkedIntegrationID: mockIntegration.id,
            tools: []
        )
        let agent2 = AgentProfileModel(
            id: UUID(),
            name: "Research Assistant",
            role: "Helps with research and data gathering.",
            baseURL: "http://localhost:8001",
            linkedIntegrationID: nil,
            tools: []
        )
        
        agentStore.agents = [agent1, agent2]
        agentStore.selectedAgentID = agent1.id

        // Create the main view model with the new mock store
        let viewModel = MainApplicationViewModel(
            // --- MODIFIED: Pass new store to initializer ---
            llmIntegrationStore: llmIntegrationStore,
            agentStore: agentStore
        )
        return viewModel
    }()

    static var previews: some View {
        AgentsTabView()
            .environmentObject(mockViewModel)
            .frame(width: 350, height: 500)
            .previewLayout(.sizeThatFits)
            .previewDisplayName("Agents Tab View")
    }
}
