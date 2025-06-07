//
//  AgentProfileView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentProfilerView_V3")

struct AgentProfilerView_V3: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    private var agentStore: AgentStore { viewModel.agentStore }

    @State private var selectedAgentID: UUID?
    @State private var showingAddAgentSheet = false
    
    // State for managing unsaved changes
    @State private var detailHasUnsavedChanges = false
    @State private var showUnsavedChangesAlert = false
    @State private var pendingSelectionID: UUID?
    
    // State for the new agent form
    @State private var newAgentName: String = ""
    @State private var newAgentURL: String = "http://localhost:8000"
    @State private var newAgentDescription: String = ""
    @State private var newAgentTool: String = "None"

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Add Agent")
                        .font(.headline)
                    Spacer()
                    Button {
                        newAgentName = ""
                        newAgentURL = "http://localhost:8000"
                        newAgentDescription = ""
                        newAgentTool = "None"
                        showingAddAgentSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Add New Agent Profile")
                }
                .padding()

                List(selection: $selectedAgentID) {
                    ForEach(agentStore.agents) { agent in
                        Text(agent.name)
                            .tag(agent.id)
                            .contextMenu {
                                if agentStore.agents.count > 1 {
                                    Button("Delete", role: .destructive) { handleDelete(agent.id) }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220)
            
        } detail: {
            if let agentID = selectedAgentID,
               let index = agentStore.agents.firstIndex(where: { $0.id == agentID }) {
                
                let agentBinding = $viewModel.agentStore.agents[index]
                
                AgentDetailView(
                    agent: agentBinding,
                    hasUnsavedChanges: $detailHasUnsavedChanges,
                    onDelete: { handleDelete(agentID) }
                )
                .environmentObject(viewModel)

            } else {
                Text("Select an Agent Profile or Add a New One")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingAddAgentSheet) {
            AddAgentSheet(isShowing: $showingAddAgentSheet, newAgentName: $newAgentName, newAgentURL: $newAgentURL, newAgentDescription: $newAgentDescription, newAgentTool: $newAgentTool) {
                let newAgent = AgentProfileModel(id: UUID(), name: newAgentName, description: newAgentDescription, isActive: true, baseURL: newAgentURL, linkedOllamaProfileID: nil, selectedAgentTool: newAgentTool)
                agentStore.addAgent(agent: newAgent)
                selectedAgentID = newAgent.id
            }
            .environmentObject(viewModel)
        }
        .onAppear {
            if selectedAgentID == nil {
                 selectedAgentID = agentStore.agents.first?.id
            }
        }
        .onChange(of: selectedAgentID) { oldValue, newValue in
            if oldValue != nil && detailHasUnsavedChanges {
                pendingSelectionID = newValue
                showUnsavedChangesAlert = true
                selectedAgentID = oldValue
            } else {
                detailHasUnsavedChanges = false
            }
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            Button("Discard Changes", role: .destructive) {
                detailHasUnsavedChanges = false // Reset the flag
                selectedAgentID = pendingSelectionID
                pendingSelectionID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSelectionID = nil
            }
        } message: {
            Text("You have unsaved changes. If you continue, your changes will be lost.")
        }
    }

    private func handleDelete(_ idToDelete: UUID) {
        guard agentStore.agents.count > 1 else {
            logger.warning("Attempted to delete the last agent. This is not allowed.")
            return
        }
        
        guard let indexToDelete = agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else {
            return
        }

        if selectedAgentID == idToDelete {
            if indexToDelete == agentStore.agents.count - 1 {
                selectedAgentID = agentStore.agents[indexToDelete - 1].id
            } else {
                selectedAgentID = agentStore.agents[indexToDelete + 1].id
            }
        }

        agentStore.deleteAgent(id: idToDelete)
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

