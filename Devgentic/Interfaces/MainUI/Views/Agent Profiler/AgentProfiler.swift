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

    // The initial ID passed when the window is opened. This is a stable property.
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
    @State private var nextSelection: UUID? = nil
    @State private var showUnsavedChangesAlert = false

    init(initialAgentID: UUID?) {
        // In init, we only store the initial ID. We don't touch @State variables here.
        self.initialAgentID = initialAgentID
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
                        // Reset form fields before showing sheet
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
                        Text(agent.name)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { handleSelection(agent.id) }
                            .listRowBackground(agent.id == selectedAgentID ? Color.accentColor.opacity(0.3) : Color.clear)
                            .contextMenu {
                                Button("Delete", role: .destructive) { handleDelete(agent.id) }
                            }
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180)
            }
            .background(Color(NSColor.windowBackgroundColor))


            // MARK: - Right Pane: Agent Profile Settings
            Group {
                if let selectedID = selectedAgentID,
                   viewModel.agentStore.agents.contains(where: { $0.id == selectedID }) {
                    
                    let agentBinding = Binding<Agent>(
                        get: {
                            guard let agent = viewModel.agentStore.agents.first(where: { $0.id == selectedID }) else {
                                logger.warning("Binding 'get' could not find agent with ID \(selectedID.uuidString).")
                                return Agent.defaultAgent()
                            }
                            return agent
                        },
                        set: { updatedAgent in
                            viewModel.agentStore.updateAgent(agent: updatedAgent)
                        }
                    )
                    
                    // We assume AgentDetailView exists and is correct.
                    // If this screen is still blank, the issue lies within AgentDetailView.
                    AgentDetailView(
                        agent: agentBinding,
                        hasUnsavedChanges: $detailHasUnsavedChanges,
                        onDelete: { handleDelete(selectedID) }
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
            AddAgentSheet(isShowing: $showingAddAgentSheet, newAgentName: $newAgentName, newAgentURL: $newAgentURL, newAgentDescription: $newAgentDescription, newAgentTool: $newAgentTool) {
                let newAgent = Agent(id: UUID(), name: newAgentName, description: newAgentDescription, isActive: true, baseURL: newAgentURL, linkedOllamaProfileID: nil, selectedAgentTool: newAgentTool)
                viewModel.agentStore.addAgent(agent: newAgent)
                handleSelection(newAgent.id)
            }
            .environmentObject(viewModel)
        }
        // MARK: - Corrected: Use onAppear to reliably set the initial state
        .onAppear {
            logger.debug("AgentProfiler appeared with initialAgentID: \(initialAgentID?.uuidString ?? "nil")")
            // If an initial agent ID was passed and it's valid, select it.
            if let id = initialAgentID, viewModel.agentStore.agents.contains(where: { $0.id == id }) {
                selectedAgentID = id
            } else {
                // Otherwise, fall back to the first agent in the store.
                selectedAgentID = viewModel.agentStore.agents.first?.id
            }
            logger.debug("onAppear finished. selectedAgentID is now: \(selectedAgentID?.uuidString ?? "nil")")
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                detailHasUnsavedChanges = false
                if let nextID = nextSelection { selectedAgentID = nextID }
                nextSelection = nil
            }
            Button("Cancel", role: .cancel) { nextSelection = nil }
        } message: {
            Text("You have unsaved changes. If you continue, your changes will be lost.")
        }
    }

    private func handleSelection(_ tappedID: UUID) {
        guard tappedID != selectedAgentID else { return }

        if detailHasUnsavedChanges {
            nextSelection = tappedID
            showUnsavedChangesAlert = true
        } else {
            selectedAgentID = tappedID
        }
    }

    private func handleDelete(_ idToDelete: UUID) {
        guard let indexToDelete = viewModel.agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else {
            return
        }

        if selectedAgentID == idToDelete {
            let agentsCount = viewModel.agentStore.agents.count
            if agentsCount > 1 {
                if indexToDelete == agentsCount - 1 {
                    selectedAgentID = viewModel.agentStore.agents[indexToDelete - 1].id
                } else {
                    selectedAgentID = viewModel.agentStore.agents[indexToDelete + 1].id
                }
            } else {
                selectedAgentID = nil
            }
        }

        viewModel.agentStore.deleteAgent(id: idToDelete)
        detailHasUnsavedChanges = false
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
