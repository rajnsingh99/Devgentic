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
    @Binding var agent: Agent // Receives a Binding to the agent
    
    // Binding to communicate dirty state to parent
    @Binding var hasUnsavedChanges: Bool
    
    // Closure to handle deletion, provided by the parent view
    var onDelete: () -> Void

    // State for editable fields
    @State private var editableAgentName: String
    @State private var editableAgentURL: String
    @State private var editableAgentDescription: String
    @State private var selectedOllamaProfileID: UUID?
    @State private var selectedAgentTool: String

    // State for confirmation dialogs
    @State private var showingDeleteConfirm = false

    init(agent: Binding<Agent>, hasUnsavedChanges: Binding<Bool>, onDelete: @escaping () -> Void) {
        _agent = agent
        _hasUnsavedChanges = hasUnsavedChanges
        self.onDelete = onDelete
        
        // Initialize local state from the wrappedValue of the binding
        let initialAgent = agent.wrappedValue
        _editableAgentName = State(initialValue: initialAgent.name)
        _editableAgentURL = State(initialValue: initialAgent.baseURL)
        _editableAgentDescription = State(initialValue: initialAgent.description)
        _selectedOllamaProfileID = State(initialValue: initialAgent.linkedOllamaProfileID)
        _selectedAgentTool = State(initialValue: initialAgent.selectedAgentTool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // MARK: - Profile Details Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Profile Details")
                    .font(.headline)
                    .padding(.bottom, 5)

                HStack {
                    Text("Profile Name:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentName)
                        .textFieldStyle(.roundedBorder)
                    // Show indicator if changed
                    if editableAgentName != agent.name {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 8))
                    }
                }

                HStack {
                    Text("Agent URL:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentURL)
                        .textFieldStyle(.roundedBorder)
                    if editableAgentURL != agent.baseURL {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 8))
                    }
                }
                
                HStack {
                    Text("Description:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentDescription)
                        .textFieldStyle(.roundedBorder)
                    if editableAgentDescription != agent.description {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 8))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // MARK: - LLM Integration Section
            VStack(alignment: .leading, spacing: 10) {
                Text("LLM Integration")
                    .font(.headline)
                    .padding(.bottom, 5)

                HStack {
                    Picker(selection: $selectedOllamaProfileID) {
                        // Enhancement 1: Removed the "None" option.
                        ForEach(viewModel.ollamaProfileStore.profiles) { profile in
                            Text(profile.profileName).tag(profile.id as UUID?)
                        }
                    } label: {
                        Text("Ollama Profile:")
                            .frame(width: 120, alignment: .leading)
                    }
                    .help("Select an Ollama profile for this agent to use.")
                    .pickerStyle(.menu)
                    
                    if selectedOllamaProfileID != agent.linkedOllamaProfileID {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 8))
                    }
                }

                HStack {
                    Text("LLM Model:")
                        .frame(width: 120, alignment: .leading)
                    Text(viewModel.ollamaProfileStore.profiles.first(where: { $0.id == selectedOllamaProfileID })?.llmModelName ?? "No LLM model selected.")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // MARK: - Agent Capabilities Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Agent Capabilities")
                    .font(.headline)
                    .padding(.bottom, 5)

                HStack {
                    Picker(selection: $selectedAgentTool) {
                        Text("None").tag("None")
                        Text("Code Interpreter").tag("Code Interpreter")
                        Text("Web Search").tag("Web Search")
                    } label: {
                        Text("Agent Tools:")
                            .frame(width: 120, alignment: .leading)
                    }
                    .help("Select tools available to this agent.")
                    .pickerStyle(.menu)
                    
                    if selectedAgentTool != agent.selectedAgentTool {
                        Image(systemName: "circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 8))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            Spacer() // Pushes content to the top and buttons to the bottom

            // MARK: - Action Buttons
            HStack {
                Spacer() // Pushes buttons to the right
                
                // Enhancement 2: Only show delete button if there is more than one agent.
                if viewModel.agentStore.agents.count > 1 {
                    Button("Delete") {
                        showingDeleteConfirm = true // Trigger confirmation alert
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.bordered)
                }
                
                Button("Save") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges || !isAgentDataValid()) // Disable if no changes or data is invalid
            }
        }
        .navigationTitle(agent.name)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Check for changes whenever an editable field is modified
        .onChange(of: editableAgentName) { _ in checkForChanges() }
        .onChange(of: editableAgentURL) { _ in checkForChanges() }
        .onChange(of: editableAgentDescription) { _ in checkForChanges() }
        .onChange(of: selectedOllamaProfileID) { _ in checkForChanges() }
        .onChange(of: selectedAgentTool) { _ in checkForChanges() }
        // Reset local state if the underlying agent changes from the parent
        .onChange(of: agent) { newAgent in
            resetState(with: newAgent)
        }
        // Set a default Ollama profile if none is selected
        .onAppear {
            if selectedOllamaProfileID == nil {
                selectedOllamaProfileID = viewModel.ollamaProfileStore.profiles.first?.id
            }
        }
        // Alert for delete confirmation
        .alert("Delete Agent?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                // Call the onDelete closure provided by the parent
                onDelete()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the agent named \"\(agent.name)\"? This action cannot be undone.")
        }
    }
    
    /// Checks if any of the editable fields differ from the original agent data.
    private func checkForChanges() {
        let changed = editableAgentName != agent.name ||
                      editableAgentURL != agent.baseURL ||
                      editableAgentDescription != agent.description ||
                      selectedOllamaProfileID != agent.linkedOllamaProfileID ||
                      selectedAgentTool != agent.selectedAgentTool
        
        if changed != hasUnsavedChanges {
            hasUnsavedChanges = changed
        }
    }

    /// Saves the changes from the local state back to the agent binding.
    private func saveChanges() {
        var updatedAgent = agent
        updatedAgent.name = editableAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAgent.baseURL = editableAgentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAgent.description = editableAgentDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAgent.linkedOllamaProfileID = selectedOllamaProfileID
        updatedAgent.selectedAgentTool = selectedAgentTool
        
        // This assignment updates the binding, triggering the parent's update logic
        agent = updatedAgent
        
        // Once saved, there are no longer unsaved changes
        hasUnsavedChanges = false
        logger.info("Saved changes for agent: \(updatedAgent.name)")
    }
    
    /// Resets the local state to match the provided agent.
    private func resetState(with newAgent: Agent) {
        // This function is called when the parent switches the agent we're editing
        logger.debug("Resetting AgentDetailView state for new agent: \(newAgent.name)")
        editableAgentName = newAgent.name
        editableAgentURL = newAgent.baseURL
        editableAgentDescription = newAgent.description
        selectedOllamaProfileID = newAgent.linkedOllamaProfileID
        selectedAgentTool = newAgent.selectedAgentTool
        // After resetting, ensure the dirty state is cleared
        hasUnsavedChanges = false
    }

    /// Validates the agent data to enable/disable the save button.
    private func isAgentDataValid() -> Bool {
        // Name and URL should not be empty.
        return !editableAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !editableAgentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
