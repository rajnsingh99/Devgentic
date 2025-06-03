//
//  AgentProfiler.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentProfiler")

// MARK: - AgentProfiler View
struct AgentProfiler: View {
    // Ensure MainApplicationViewModel is provided as an EnvironmentObject
    // from the root of your application (e.g., in App.swift)
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.dismiss) var dismiss // To dismiss the window
    @Environment(\.openURL) var openURL // For opening URLs (e.g., agent documentation)

    @State private var selectedAgentID: UUID?
    @State private var showingAddAgentSheet = false

    // State for the new agent form
    @State private var newAgentName: String = ""
    @State private var newAgentURL: String = "http://localhost:8000" // Default URL
    @State private var newAgentDescription: String = ""
    @State private var newAgentTool: String = "None" // Default tool for new agent

    // MARK: New: Initializer to accept an optional agent ID for direct selection
    init(initialAgentID: UUID? = nil) {
        _selectedAgentID = State(initialValue: initialAgentID)
    }

    var body: some View {
        NavigationView { // Use NavigationView for the split view
            // MARK: - Left Pane: Agent List
            VStack(spacing: 0) {
                HStack {
                    Text("Agents")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        // Reset new agent form fields before showing sheet
                        newAgentName = ""
                        newAgentURL = "http://localhost:8000"
                        newAgentDescription = ""
                        newAgentTool = "None"
                        showingAddAgentSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Add New Agent Profile")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                List(selection: $selectedAgentID) {
                    ForEach(viewModel.agentStore.agents) { agent in
                        Text(agent.name)
                            .tag(agent.id)
                            .contextMenu {
                                Button("Delete") {
                                    // In a real app, you'd show a confirmation dialog here
                                    logger.info("Deleting agent: \(agent.name)")
                                    viewModel.agentStore.deleteAgent(id: agent.id)
                                    // After deletion, ensure a valid selection or nil
                                    if selectedAgentID == agent.id {
                                        selectedAgentID = viewModel.agentStore.agents.first?.id // Select first available
                                    }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180)
            }
            .background(Color(NSColor.windowBackgroundColor))


            // MARK: - Right Pane: Agent Profile Settings
            Group {
                if let selectedAgent = viewModel.agentStore.agents.first(where: { $0.id == selectedAgentID }) {
                    // Pass a binding to the selected agent so AgentDetailView can modify it
                    // and the changes are reflected in the store.
                    AgentDetailView(agent: Binding(
                        get: { selectedAgent },
                        set: { updatedAgent in
                            viewModel.agentStore.updateAgent(agent: updatedAgent)
                        }
                    ))
                    .environmentObject(viewModel) // Pass viewModel to detail view
                } else {
                    Text("Select an Agent Profile or Add a New One")
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor)) // Background for the detail pane
        }
        .frame(minWidth: 700, minHeight: 400) // Minimum window size
        // Removed the custom close button from the toolbar
        // .toolbar {
        //     ToolbarItem(placement: .navigation) {
        //         Button {
        //             dismiss()
        //         } label: {
        //             Image(systemName: "xmark.circle.fill")
        //         }
        //         .help("Close Window")
        //     }
        // }
        .sheet(isPresented: $showingAddAgentSheet) {
            AddAgentSheet(
                isShowing: $showingAddAgentSheet,
                newAgentName: $newAgentName,
                newAgentURL: $newAgentURL,
                newAgentDescription: $newAgentDescription,
                newAgentTool: $newAgentTool // Pass the new agent tool binding
            ) {
                // Action to perform when "Add Agent" is confirmed
                let newAgent = Agent(
                    id: UUID(),
                    name: newAgentName,
                    description: newAgentDescription,
                    isActive: true, // New agents are active by default
                    baseURL: newAgentURL, // Use the URL from the form
                    linkedOllamaProfileID: nil, // No Ollama profile linked on creation
                    selectedAgentTool: newAgentTool // Use the selected tool from the form
                )
                viewModel.agentStore.addAgent(agent: newAgent)
                selectedAgentID = newAgent.id // Automatically select the newly added agent
                // Reset form fields are handled in the button action above
            }
            .environmentObject(viewModel) // Pass viewModel to the sheet if needed
        }
        .onAppear {
            // If an initialAgentID was provided via the initializer, select it.
            // Otherwise, select the first agent if available.
            if let initialID = selectedAgentID {
                if !viewModel.agentStore.agents.contains(where: { $0.id == initialID }) {
                    selectedAgentID = viewModel.agentStore.agents.first?.id
                }
            } else if selectedAgentID == nil, let firstAgent = viewModel.agentStore.agents.first {
                selectedAgentID = firstAgent.id
            }
        }
    }
}

// MARK: - AddAgentSheet (Updated)
struct AddAgentSheet: View {
    @Binding var isShowing: Bool
    @Binding var newAgentName: String
    @Binding var newAgentURL: String
    @Binding var newAgentDescription: String
    @Binding var newAgentTool: String // New binding for agent tool
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Agent Profile")
                .font(.title2)
                .fontWeight(.bold)

            TextField("Agent Name (e.g., My Dev Agent)", text: $newAgentName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            TextField("Agent URL (e.g., http://localhost:8000)", text: $newAgentURL)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
            
            TextField("Description (e.g., My personal coding assistant)", text: $newAgentDescription)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Picker("Default Tool:", selection: $newAgentTool) {
                Text("None").tag("None")
                Text("Code Interpreter").tag("Code Interpreter")
                Text("Web Search").tag("Web Search")
            }
            .pickerStyle(.menu) // Ensure it's a dropdown menu
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    isShowing = false
                }
                .buttonStyle(.bordered)

                Button("Add Agent") {
                    onAdd()
                    isShowing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          newAgentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(30)
        .frame(minWidth: 400, minHeight: 300)
    }
}
