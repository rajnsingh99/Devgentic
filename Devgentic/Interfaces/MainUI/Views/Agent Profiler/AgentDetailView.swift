//
//  AgentDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentDetailView")

struct AgentDetailView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Binding var agent: Agent // Now receives a Binding to the agent

    // State for editable fields
    @State private var editableAgentName: String
    @State private var editableAgentURL: String
    @State private var editableAgentDescription: String
    @State private var selectedOllamaProfileID: UUID? // For Ollama Profile Chooser
    @State private var selectedAgentTool: String // For Agent Tools

    init(agent: Binding<Agent>) {
        _agent = agent // Assign the binding directly
        _editableAgentName = State(initialValue: agent.wrappedValue.name)
        _editableAgentURL = State(initialValue: agent.wrappedValue.baseURL)
        _editableAgentDescription = State(initialValue: agent.wrappedValue.description)
        _selectedOllamaProfileID = State(initialValue: agent.wrappedValue.linkedOllamaProfileID)
        _selectedAgentTool = State(initialValue: agent.wrappedValue.selectedAgentTool)
    }

    var body: some View {
        Form {
            Section(header: Text("Profile Details")) {
                // Modified HStack for Profile Name
                HStack {
                    Text("Profile Name:") // Added explicit label
                        .frame(width: 120, alignment: .leading) // Fixed width for alignment
                    TextField("", text: $editableAgentName) // Removed placeholder as label is now explicit
                    Button("Update") {
                        agent.name = editableAgentName // Update via binding
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentName == agent.name || editableAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Modified HStack for Agent URL
                HStack {
                    Text("Agent URL:") // Added explicit label
                        .frame(width: 120, alignment: .leading) // Fixed width for alignment
                    TextField("", text: $editableAgentURL) // Removed placeholder as label is now explicit
                    Button("Update") {
                        agent.baseURL = editableAgentURL // Update via binding
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentURL == agent.baseURL || editableAgentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                // Modified HStack for Description
                HStack {
                    Text("Description:") // Added explicit label
                        .frame(width: 120, alignment: .leading) // Fixed width for alignment
                    TextField("", text: $editableAgentDescription) // Removed placeholder as label is now explicit
                    Button("Update") {
                        agent.description = editableAgentDescription // Update via binding
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentDescription == agent.description || editableAgentDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section(header: Text("LLM Integration")) {
                Picker(selection: $selectedOllamaProfileID) { // Removed inline label for explicit Text
                    Text("None").tag(nil as UUID?) // Option for no Ollama profile
                    ForEach(viewModel.ollamaProfileStore.profiles) { profile in
                        Text(profile.profileName).tag(profile.id as UUID?)
                    }
                } label: { // Explicit label for Picker
                    Text("Ollama Profile:")
                        .frame(width: 120, alignment: .leading) // Fixed width for alignment
                }
                .help("Select an Ollama profile for this agent to use.")
                .onChange(of: selectedOllamaProfileID) { newID in
                    agent.linkedOllamaProfileID = newID // Update via binding
                }
            }

            Section(header: Text("Agent Capabilities")) {
                Picker(selection: $selectedAgentTool) { // Removed inline label for explicit Text
                    Text("None").tag("None")
                    Text("Code Interpreter").tag("Code Interpreter")
                    Text("Web Search").tag("Web Search")
                } label: { // Explicit label for Picker
                    Text("Agent Tools:")
                        .frame(width: 120, alignment: .leading) // Fixed width for alignment
                }
                .help("Select tools available to this agent.")
                .onChange(of: selectedAgentTool) { newTool in
                    agent.selectedAgentTool = newTool // Update via binding
                }

                Button("Orchestration Settings (Coming Soon)") {
                    // Action for orchestration settings
                    logger.info("Orchestration Settings button tapped for agent: \(agent.name)")
                }
                .disabled(true) // Disable until implemented
            }
            
            Section {
                Button("Delete Agent") {
                    // In a real app, you'd show a confirmation dialog here
                    logger.info("Delete button tapped for agent: \(agent.name)")
                    viewModel.agentStore.deleteAgent(id: agent.id)
                    // The parent view (AgentProfiler) will handle selecting a new agent or showing placeholder
                }
                .foregroundColor(.red)
            }
        }
        .navigationTitle(agent.name)
        // Apply padding to the Form itself to give some margin from the edges
        .padding(.horizontal) // Added horizontal padding
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure content aligns to leading edge
    }
}
