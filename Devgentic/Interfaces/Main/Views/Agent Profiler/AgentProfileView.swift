//
//  AgentProfilerView.swift
//  Devgentic
//
//  Created by Raj Singh on 03/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentProfilerView")

struct AgentProfilerView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    private var agentStore: AgentStore { viewModel.agentStore }

    @State private var selectedAgentID: UUID?
    @State private var showingAddAgentSheet = false
    @State private var detailHasUnsavedChanges = false
    @State private var showUnsavedChangesAlert = false
    @State private var pendingSelectionID: UUID?
    
    @State private var newAgentName: String = ""
    @State private var newAgentURL: String = "http://127.0.0.1:8000"
    @State private var newAgentRole: String = ""

    var body: some View {
        NavigationSplitView {
            agentList
        } detail: {
            agentDetail
        }
        .sheet(isPresented: $showingAddAgentSheet) { addAgentSheet }
        .onAppear {
            if selectedAgentID == nil {
                 selectedAgentID = agentStore.agents.first?.id
            }
        }
        .onChange(of: selectedAgentID) { oldValue, newValue in
            handleSelectionChange(oldValue: oldValue, newValue: newValue)
        }
        .alert("Unsaved Changes", isPresented: $showUnsavedChangesAlert) {
            unsavedChangesAlertButtons
        }
    }

    private var agentList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                Button {
                    resetNewAgentForm()
                    showingAddAgentSheet = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).help("Add New Agent Profile")
            }
            .padding()
            
            List(selection: $selectedAgentID) {
                ForEach(agentStore.agents) { agent in
                    Text(agent.name)
                        .tag(agent.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { handleDelete(agent.id) }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var agentDetail: some View {
        if let agentID = selectedAgentID,
           let index = agentStore.agents.firstIndex(where: { $0.id == agentID }) {
            
            let agentBinding = $viewModel.agentStore.agents[index]
            
            AgentDetailView(
                agent: agentBinding,
                hasUnsavedChanges: $detailHasUnsavedChanges,
                onDelete: { handleDelete(agentID) }
            )
            .environmentObject(viewModel)
            // NOTE: The old ToolStore is no longer injected here.
            // AgentDetailView now manages its own ToolStore instance.
        } else {
            Text("Select an Agent Profile or Add a New One")
                .font(.title).foregroundColor(.secondary)
        }
    }

    private var addAgentSheet: some View {
        VStack(spacing: 20) {
            Text("Add New Agent Profile").font(.title2).fontWeight(.bold)
            TextField("Agent Name (e.g., My Dev Agent)", text: $newAgentName)
            TextField("Agent URL (e.g., http://127.0.0.1:8000)", text: $newAgentURL)
            TextField("Role / Description", text: $newAgentRole, axis: .vertical).lineLimit(2...4)
            HStack {
                Button("Cancel") { showingAddAgentSheet = false }.buttonStyle(.bordered)
                Button("Add Agent") {
                    addNewAgent()
                    showingAddAgentSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(30)
        .frame(minWidth: 450, minHeight: 300)
    }
    
    private var unsavedChangesAlertButtons: some View {
        Group {
            Button("Discard Changes", role: .destructive) {
                detailHasUnsavedChanges = false
                selectedAgentID = pendingSelectionID
                pendingSelectionID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSelectionID = nil
            }
        }
    }
    
    // MARK: - Logic
    private func resetNewAgentForm() {
        newAgentName = ""
        newAgentURL = "http://127.0.0.1:8000"
        newAgentRole = ""
    }
    
    private func addNewAgent() {
        let newAgent = AgentProfileModel(
            id: UUID(),
            name: newAgentName,
            role: newAgentRole,
            baseURL: newAgentURL,
            linkedIntegrationID: viewModel.llmIntegrationStore.selectedIntegrationID,
            tools: []
        )
        agentStore.addAgent(agent: newAgent)
        selectedAgentID = newAgent.id
    }
    
    private func handleSelectionChange(oldValue: UUID?, newValue: UUID?) {
        if oldValue != nil && detailHasUnsavedChanges {
            pendingSelectionID = newValue
            showUnsavedChangesAlert = true
            selectedAgentID = oldValue
        } else {
            detailHasUnsavedChanges = false
        }
    }

    private func handleDelete(_ idToDelete: UUID) {
        guard let indexToDelete = agentStore.agents.firstIndex(where: { $0.id == idToDelete }) else { return }

        if selectedAgentID == idToDelete {
            if agentStore.agents.count > 1 {
                selectedAgentID = (indexToDelete == agentStore.agents.count - 1)
                    ? agentStore.agents[indexToDelete - 1].id
                    : agentStore.agents[indexToDelete + 1].id
            } else {
                selectedAgentID = nil
            }
        }

        agentStore.deleteAgent(id: idToDelete)
        detailHasUnsavedChanges = false
    }
}


// MARK: - Preview Provider (Corrected)
struct AgentProfilerView_V3_Previews: PreviewProvider {
    static var previews: some View {
        let mockLlmIntegrationStore: LLMIntegrationStore = {
            let store = LLMIntegrationStore()
            let defaultIntegration = LLMIntegrationModel.defaultOllama()
            store.integrations = [defaultIntegration]
            store.selectedIntegrationID = defaultIntegration.id
            return store
        }()

        let mockAgentStore: AgentStore = {
            let store = AgentStore()
            var agent1 = AgentProfileModel.defaultAgent()
            agent1.name = "Developer Agent"
            agent1.linkedIntegrationID = mockLlmIntegrationStore.integrations.first?.id
            
            var agent2 = AgentProfileModel.defaultAgent()
            agent2.name = "Research Assistant"
            agent2.role = "Helps with research and data gathering."
            
            store.agents = [agent1, agent2]
            return store
        }()

        let mockToolStore = ToolStore()
        
        let mockMainViewModel = MainApplicationViewModel(
            llmIntegrationStore: mockLlmIntegrationStore,
            agentStore: mockAgentStore
        )

        AgentProfilerView()
            .environmentObject(mockMainViewModel)
            .environmentObject(mockToolStore)
            .frame(width: 800, height: 600)
            .previewDisplayName("Agent Profiler View")
    }
}
