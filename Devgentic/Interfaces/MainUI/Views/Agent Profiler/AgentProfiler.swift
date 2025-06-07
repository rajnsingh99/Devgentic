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
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.dismiss) var dismiss

    @State private var selectedAgentID: UUID?
    @State private var showingAddAgentSheet = false

    // State for the new agent form
    @State private var newAgentName: String = ""
    @State private var newAgentURL: String = "http://localhost:8000"
    @State private var newAgentDescription: String = ""
    @State private var newAgentTool: String = "None"

    // State to manage unsaved changes alert
    @State private var detailHasUnsavedChanges = false
    @State private var nextSelection: UUID? = nil
    @State private var showUnsavedChangesAlert = false

    init(initialAgentID: UUID? = nil) {
        _selectedAgentID = State(initialValue: initialAgentID)
    }

    var body: some View {
        NavigationView {
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

                List {
                    ForEach(viewModel.agentStore.agents) { agent in
                        // Using a simple Text view with a tap gesture for selection handling
                        Text(agent.name)
                            .padding(.vertical, 4) // Add some padding to make tap targets larger
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle()) // Make the whole area tappable
                            .onTapGesture {
                                handleSelection(agent.id)
                            }
                            // Apply background based on selection
                            .listRowBackground(agent.id == selectedAgentID ? Color.accentColor.opacity(0.3) : Color.clear)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    handleDelete(agent.id)
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
                // **FIX:** Check for the agent's existence but don't rely on finding an index here.
                // The binding will be made safer to handle transient states during deletion.
                if let selectedID = selectedAgentID,
                   viewModel.agentStore.agents.contains(where: { $0.id == selectedID }) {
                    
                    // **FIX:** Create a more robust binding that finds the agent by ID each time.
                    // This avoids capturing a stale index and prevents the "Index out of range" crash.
                    let agentBinding = Binding<Agent>(
                        get: {
                            // Safely find the agent by its ID. If it has just been deleted,
                            // this will return a default value to prevent a crash while the UI updates.
                            guard let agent = viewModel.agentStore.agents.first(where: { $0.id == selectedID }) else {
                                logger.warning("Binding 'get' could not find agent with ID \(selectedID.uuidString). This is expected transiently during deletion.")
                                // Return a non-optional default agent. The view will be removed from the hierarchy
                                // shortly after, so this is just a temporary, safe value.
                                return Agent.defaultAgent()
                            }
                            return agent
                        },
                        set: { updatedAgent in
                            // The update function already safely finds the agent by its ID.
                            viewModel.agentStore.updateAgent(agent: updatedAgent)
                        }
                    )
                    
                    AgentDetailView(
                        agent: agentBinding,
                        hasUnsavedChanges: $detailHasUnsavedChanges,
                        onDelete: {
                            // The delete action is handled in this parent view.
                            handleDelete(selectedID)
                        }
                    )
                    .environmentObject(viewModel)
                } else {
                    Text("Select an Agent Profile or Add a New One")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(minWidth: 1000, minHeight: 400)
        .sheet(isPresented: $showingAddAgentSheet) {
            AddAgentSheet(
                isShowing: $showingAddAgentSheet,
                newAgentName: $newAgentName,
                newAgentURL: $newAgentURL,
                newAgentDescription: $newAgentDescription,
                newAgentTool: $newAgentTool
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
                handleSelection(newAgent.id) // Use selection handler
            }
            .environmentObject(viewModel)
        }
        .onAppear {
            // On first appear, ensure a valid agent is selected if possible.
            if selectedAgentID == nil || !viewModel.agentStore.agents.contains(where: { $0.id == selectedAgentID }) {
                selectedAgentID = viewModel.agentStore.agents.first?.id
            }
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                // Discard changes and proceed with navigation
                detailHasUnsavedChanges = false
                if let nextID = nextSelection {
                    selectedAgentID = nextID
                }
                nextSelection = nil
            }
            Button("Cancel", role: .cancel) {
                // Cancel navigation
                nextSelection = nil
            }
        } message: {
            Text("You have unsaved changes. If you continue, your changes will be lost.")
        }
    }

    /// Safely handles the selection of an agent, checking for unsaved changes first.
    private func handleSelection(_ tappedID: UUID) {
        // Don't do anything if the same agent is tapped
        guard tappedID != selectedAgentID else { return }

        if detailHasUnsavedChanges {
            // If there are changes, store the intended selection and show the alert
            nextSelection = tappedID
            showUnsavedChangesAlert = true
        } else {
            // If no changes, navigate immediately
            selectedAgentID = tappedID
        }
    }

    /// Safely handles the deletion of an agent and updates the selection to prevent crashes.
    private func handleDelete(_ idToDelete: UUID) {
        guard let indexToDelete = viewModel.agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else {
            logger.warning("Attempted to delete an agent that does not exist: \(idToDelete.uuidString)")
            return
        }

        // **CRITICAL FIX**: If the agent being deleted is the currently selected one,
        // we MUST change the selection to a valid one *before* altering the data source.
        if selectedAgentID == idToDelete {
            let agentsCount = viewModel.agentStore.agents.count
            var nextAgentToSelectID: UUID? = nil
            if agentsCount > 1 {
                if indexToDelete == agentsCount - 1 {
                    // If it's the last agent, select the one before it.
                    nextAgentToSelectID = viewModel.agentStore.agents[indexToDelete - 1].id
                } else {
                    // Otherwise, select the one after it.
                    nextAgentToSelectID = viewModel.agentStore.agents[indexToDelete + 1].id
                }
            }
            // Update the selection state *before* the deletion happens.
            selectedAgentID = nextAgentToSelectID
        }

        // Now, with the selection safely moved away, perform the deletion.
        logger.info("Deleting agent with ID: \(idToDelete.uuidString)")
        viewModel.agentStore.deleteAgent(id: idToDelete)
        
        // Final check: if no agents are left, ensure selection is nil.
        if viewModel.agentStore.agents.isEmpty {
            selectedAgentID = nil
        }
        
        // As the context has changed, there are no "unsaved changes" to worry about.
        detailHasUnsavedChanges = false
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
