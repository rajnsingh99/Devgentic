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

    // The initial ID passed when the window is opened.
    let initialAgentID: UUID?
    
    // The internal state that drives the UI selection.
    @State private var selectedAgentID: UUID?
    
    @State private var showingAddAgentSheet = false

    // State for the new agent form
    @State private var newAgentName: String = ""
    @State private var newAgentURL: String = "http://localhost:8000"
    @State private var newAgentDescription: String = ""
    @State private var newAgentTool: String = "None"

    // State to manage unsaved changes alert
    @State private var detailHasUnsavedChanges = false
    @State private var showUnsavedChangesAlert = false
    @State private var pendingSelectionID: UUID?

    init(initialAgentID: UUID?) {
        self.initialAgentID = initialAgentID
    }

    var body: some View {
        // MARK: - FIX: Replaced NavigationView with NavigationSplitView
        NavigationSplitView {
            // MARK: - Sidebar (Master View)
            VStack(spacing: 0) {
                HStack {
                    Text("Add Agent")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        // Reset form fields before showing sheet
                        newAgentName = ""
                        newAgentURL = "http://localhost:8000"
                        newAgentDescription = ""
                        newAgentTool = "None"
                        showingAddAgentSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Add New Agent Profile")
                }
                .padding()

                List(selection: $selectedAgentID) {
                    ForEach(viewModel.agentStore.agents) { agent in
                        Text(agent.name)
                            .tag(agent.id) // Use .tag for selection
                            .contextMenu {
                                if viewModel.agentStore.agents.count > 1 {
                                    Button("Delete", role: .destructive) { handleDelete(agent.id) }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220)
            
        } detail: {
            // MARK: - Detail View
            if let agentID = selectedAgentID,
               let index = viewModel.agentStore.agents.firstIndex(where: { $0.id == agentID }) {
                
                let agentBinding = $viewModel.agentStore.agents[index]
                
                // We pass a binding to the agent and a binding for the unsaved changes flag
                AgentDetailView(
                    agent: agentBinding,
                    hasUnsavedChanges: $detailHasUnsavedChanges,
                    onDelete: { handleDelete(agentID) }
                )
                .environmentObject(viewModel)
                
            } else {
                Text("Select an Agent Profile or Add a New One")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 400)
        .sheet(isPresented: $showingAddAgentSheet) {
            AddAgentSheet(isShowing: $showingAddAgentSheet, newAgentName: $newAgentName, newAgentURL: $newAgentURL, newAgentDescription: $newAgentDescription, newAgentTool: $newAgentTool) {
                let newAgent = Agent(id: UUID(), name: newAgentName, description: newAgentDescription, isActive: true, baseURL: newAgentURL, linkedOllamaProfileID: nil, selectedAgentTool: newAgentTool)
                viewModel.agentStore.addAgent(agent: newAgent)
                // Select the new agent after adding it
                selectedAgentID = newAgent.id
            }
            .environmentObject(viewModel)
        }
        .onAppear {
            if selectedAgentID == nil {
                // If an initial agent ID was passed and it's valid, select it.
                if let id = initialAgentID, viewModel.agentStore.agents.contains(where: { $0.id == id }) {
                    selectedAgentID = id
                } else {
                    // Otherwise, fall back to the first agent in the store.
                    selectedAgentID = viewModel.agentStore.agents.first?.id
                }
            }
        }
        .onChange(of: selectedAgentID) { oldValue, newValue in
            // When selection changes away from a view with unsaved changes, show an alert.
            if oldValue != nil && detailHasUnsavedChanges {
                pendingSelectionID = newValue // Store where the user intended to go
                showUnsavedChangesAlert = true
                // Revert the selection visually until the user makes a choice in the alert
                selectedAgentID = oldValue
            } else {
                // If there are no unsaved changes, just clear the flag for the new view.
                detailHasUnsavedChanges = false
            }
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                detailHasUnsavedChanges = false // Reset the flag
                // Now, proceed to the destination the user originally clicked
                selectedAgentID = pendingSelectionID
                pendingSelectionID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSelectionID = nil // Forget the pending destination
            }
        } message: {
            Text("You have unsaved changes. If you continue, your changes will be lost.")
        }
    }

    private func handleDelete(_ idToDelete: UUID) {
        guard viewModel.agentStore.agents.count > 1 else {
            logger.warning("Attempted to delete the last agent. This should not be possible.")
            return
        }
        
        guard let indexToDelete = viewModel.agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else {
            return
        }

        // Determine the next selection before deleting
        if selectedAgentID == idToDelete {
            if indexToDelete == viewModel.agentStore.agents.count - 1 {
                // If it's the last agent in the list, select the one before it
                selectedAgentID = viewModel.agentStore.agents[indexToDelete - 1].id
            } else {
                // Otherwise, select the one after it
                selectedAgentID = viewModel.agentStore.agents[indexToDelete + 1].id
            }
        }

        viewModel.agentStore.deleteAgent(id: idToDelete)
        detailHasUnsavedChanges = false // Deleting discards any unsaved changes
    }
}


// MARK: - AddAgentSheet
struct AddAgentSheet: View {
    @Binding var isShowing: Bool
    @Binding var newAgentName: String
    @Binding var newAgentURL: String
    @Binding var newAgentDescription: String
    @Binding var newAgentTool: String
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Agent Profile").font(.title2).fontWeight(.bold)
            TextField("Agent Name (e.g., My Dev Agent)", text: $newAgentName)
            TextField("Agent URL (e.g., http://localhost:8000)", text: $newAgentURL)
            TextField("Description (e.g., My personal coding assistant)", text: $newAgentDescription)
            Picker("Default Tool:", selection: $newAgentTool) {
                Text("None").tag("None")
                Text("Code Interpreter").tag("Code Interpreter")
                Text("Web Search").tag("Web Search")
            }.pickerStyle(.menu)
            HStack {
                Button("Cancel") { isShowing = false }.buttonStyle(.bordered)
                Button("Add Agent") {
                    onAdd()
                    isShowing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newAgentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(30)
        .frame(minWidth: 400, minHeight: 300)
    }
}
