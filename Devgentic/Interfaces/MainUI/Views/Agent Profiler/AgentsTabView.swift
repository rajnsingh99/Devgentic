//
//  AgentsTabView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentTabView")

// MARK: - AgentsTabView (Updated)
struct AgentsTabView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel // Access MainApplicationViewModel
    @Environment(\.openWindow) var openWindow // To open new windows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // List of agents
            ScrollView {
                if viewModel.agentStore.agents.isEmpty {
                    Text("No agents configured yet. Add a new agent to get started.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    // ForEach observes changes in viewModel.agentStore.agents
                    ForEach(viewModel.agentStore.agents) { agent in
                        AgentRowView(agent: agent)
                            .environmentObject(viewModel) // Pass environment object
                            .padding(.vertical, 4)
                            .padding(.horizontal)
                            .onTapGesture(count: 2) { // MARK: New: Double-tap gesture
                                logger.info("Double-tapped agent: \(agent.name). Opening Agent Profiler for ID: \(agent.id.uuidString)")
                                openWindow(id: "agent-settings", value: agent.id) // Pass agent ID
                            }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - AgentRowView
struct AgentRowView: View {
    let agent: Agent
    @EnvironmentObject var viewModel: MainApplicationViewModel

    var body: some View {
        HStack {
            Image(systemName: agent.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundColor(agent.isActive ? .green : .gray)
                .onTapGesture {
                    var updatedAgent = agent
                    updatedAgent.isActive.toggle()
                    viewModel.agentStore.updateAgent(agent: updatedAgent)
                }

            VStack(alignment: .leading) {
                Text(agent.name)
                    .font(.headline)
                Text(agent.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            // Add more controls here if needed, e.g., edit button, delete button
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle()) // Makes the whole row tappable
        // Removed onTapGesture here as it's now on the ForEach in AgentsTabView
    }
}
