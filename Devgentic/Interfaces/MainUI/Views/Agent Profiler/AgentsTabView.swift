//
//  AgentsTabView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentTabView")

struct AgentsTabView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                if viewModel.agentStore.agents.isEmpty {
                    ContentUnavailableView("No Agents", systemImage: "person.3.sequence", description: Text("Add a new agent to get started."))
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
                                    openWindow(id: "agent-config", value: agent.id)
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

// MARK: - AgentRowView (Refactored)
struct AgentRowView: View {
    let agent: AgentProfileModel
    @EnvironmentObject var viewModel: MainApplicationViewModel

    private var isAgentActive: Bool {
        viewModel.agentStore.selectedAgentID == agent.id
    }

    private var linkedIntegration: LLMIntegrationModel? {
        guard let integrationID = agent.linkedIntegrationID else { return nil }
        return viewModel.llmIntegrationStore.integrations.first { $0.id == integrationID }
    }

    private var integrationDisplayInfo: (name: String, model: String) {
        guard let integration = linkedIntegration else {
            return ("Not Linked", "N/A")
        }
        
        let modelName: String
        if integration.providerType == .ollama {
            modelName = integration.ollamaConfig?.modelName ?? "Not Set"
        } else {
            modelName = integration.remoteConfig?.modelName ?? "Not Set"
        }
        
        return (integration.displayName, modelName)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(agent.name)
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("\(integrationDisplayInfo.name) - \(integrationDisplayInfo.model)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            
            if isAgentActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlAlternatingRowBackgroundColors.first ?? .clear))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isAgentActive ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isAgentActive)
    }
}


// MARK: - Preview Provider (Fixed)
struct AgentsTabView_Previews: PreviewProvider {
    static var mockViewModel: MainApplicationViewModel = {
        let llmIntegrationStore = LLMIntegrationStore()
        let agentStore = AgentStore()
        
        // --- FIXED: Use the new nested model structure for initialization ---
        let mockIntegration = LLMIntegrationModel(
            id: UUID(),
            displayName: "Local Llama 3",
            providerType: .ollama,
            ollamaConfig: OllamaConfigModel(
                baseURL: "http://localhost:11434",
                modelName: "llama3:8b",
                temperature: 0.8,
                contextWindowSize: 4096
            ),
            remoteConfig: nil
        )
        llmIntegrationStore.integrations = [mockIntegration]

        let agent1 = AgentProfileModel(
            id: UUID(),
            name: "Developer Agent",
            role: "Your personal development assistant.",
            baseURL: "http://localhost:8000",
            linkedIntegrationID: mockIntegration.id,
            tools: []
        )
        agentStore.agents = [agent1]
        agentStore.selectedAgentID = agent1.id

        let viewModel = MainApplicationViewModel(
            llmIntegrationStore: llmIntegrationStore,
            agentStore: agentStore
        )
        return viewModel
    }()

    static var previews: some View {
        AgentsTabView()
            .environmentObject(mockViewModel)
            .frame(width: 350, height: 500)
    }
}
