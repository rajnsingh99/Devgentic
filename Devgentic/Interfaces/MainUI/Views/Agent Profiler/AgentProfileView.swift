//
//  AgentProfilerView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentProfilerView_V3")

struct AgentProfilerView_V3: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @EnvironmentObject var toolStore: ToolStore
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
                
                Divider()

                List(selection: $selectedAgentID) {
                    ForEach(agentStore.agents) { agent in
                        Text(agent.name)
                            .tag(agent.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) { handleDelete(agent.id) }
                            }
                            .padding(5)
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
                .environmentObject(toolStore)

            } else {
                Text("Select an Agent Profile or Add a New One")
                    .font(.title)
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $showingAddAgentSheet) {
            AddAgentSheet(isShowing: $showingAddAgentSheet, newAgentName: $newAgentName, newAgentURL: $newAgentURL, newAgentDescription: $newAgentDescription) {
                let activeOllamaProfileID = viewModel.ollamaProfileStore.selectedProfileID
                
                let newAgent = AgentProfileModel(
                    id: UUID(),
                    name: newAgentName,
                    role: newAgentDescription,
                    isActive: true,
                    baseURL: newAgentURL,
                    linkedOllamaProfileID: activeOllamaProfileID, // Assign active profile
                    tools: []
                )
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
                detailHasUnsavedChanges = false
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
        guard let indexToDelete = agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else {
            return
        }

        if selectedAgentID == idToDelete {
            if agentStore.agents.count > 1 {
                if indexToDelete == agentStore.agents.count - 1 {
                    selectedAgentID = agentStore.agents[indexToDelete - 1].id
                } else {
                    selectedAgentID = agentStore.agents[indexToDelete + 1].id
                }
            } else {
                selectedAgentID = nil
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
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New Agent Profile").font(.title2).fontWeight(.bold)
            TextField("Agent Name (e.g., My Dev Agent)", text: $newAgentName)
            TextField("Agent URL (e.g., http://localhost:8000)", text: $newAgentURL)
            TextField("Description (e.g., My personal coding assistant)", text: $newAgentDescription)
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

// MARK: - Preview Provider
struct AgentProfilerView_V3_Previews: PreviewProvider {
    static var previews: some View {
        let mockOllamaProfileStore: OllamaProfileStore = {
            let store = OllamaProfileStore()
            let defaultProfile = OllamaProfileModel.defaultProfile()
            store.profiles = [defaultProfile]
            store.selectedProfileID = defaultProfile.id
            return store
        }()

        let mockAgentStore: AgentStore = {
            let store = AgentStore()
            var agent1 = AgentProfileModel.defaultAgent()
            agent1.name = "Developer Agent"
            agent1.linkedOllamaProfileID = mockOllamaProfileStore.profiles.first?.id
            
            var agent2 = AgentProfileModel.defaultAgent()
            agent2.name = "Research Assistant"
            agent2.role = "Helps with research and data gathering."
            agent2.isActive = false
            
            store.agents = [agent1, agent2]
            return store
        }()

        let mockToolStore = ToolStore()
        
        let mockMainViewModel = MainApplicationViewModel(
            ollamaProfileStore: mockOllamaProfileStore,
            agentStore: mockAgentStore
        )

        AgentProfilerView_V3()
            .environmentObject(mockMainViewModel)
            .environmentObject(mockToolStore)
            .frame(width: 800, height: 600)
            .previewDisplayName("Agent Profiler View")
    }
}
