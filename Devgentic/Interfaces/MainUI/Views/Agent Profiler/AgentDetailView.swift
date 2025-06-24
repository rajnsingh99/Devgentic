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
    @EnvironmentObject var toolStore: ToolStore
    
    @Binding var agent: AgentProfileModel
    @Binding var hasUnsavedChanges: Bool
    
    var onDelete: () -> Void

    @State private var editableAgent: AgentProfileModel
    @State private var showingDeleteConfirm = false

    private let toolCapsuleColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 5)
    ]

    init(agent: Binding<AgentProfileModel>, hasUnsavedChanges: Binding<Bool>, onDelete: @escaping () -> Void) {
        self._agent = agent
        self._hasUnsavedChanges = hasUnsavedChanges
        self.onDelete = onDelete
        self._editableAgent = State(initialValue: agent.wrappedValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                profileDetailsSection
                Divider()
                llmIntegrationSection
                Divider()
                agentCapabilitiesSection
                Spacer()
            }
        }
        .padding()
        .safeAreaInset(edge: .bottom) {
            actionButtons
        }
        .onChange(of: editableAgent) { _, _ in checkForChanges() }
        .onChange(of: agent) { _, newAgent in resetState(with: newAgent) }
        .onAppear {
            if editableAgent.linkedOllamaProfileID == nil {
                editableAgent.linkedOllamaProfileID = viewModel.ollamaProfileStore.profiles.first?.id
            }
        }
        .alert("Delete Agent?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the agent named \"\(agent.name)\"? This action cannot be undone.")
        }
    }

    // MARK: - View Components

    private var profileDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile Details").font(.headline)
            formRow(label: "Profile Name:") { TextField("Agent Name", text: $editableAgent.name) }
            formRow(label: "Agent URL:") { TextField("Agent URL", text: $editableAgent.baseURL) }
            formRow(label: "Role:") { TextField("Role", text: $editableAgent.role) }
        }.padding(.vertical, 10)
    }

    private var llmIntegrationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LLM Integration").font(.headline)
            formRow(label: "Ollama Profile:") {
                Picker("Ollama Profile", selection: $editableAgent.linkedOllamaProfileID) {
                    ForEach(viewModel.ollamaProfileStore.profiles) { Text($0.profileName).tag($0.id as UUID?) }
                }.pickerStyle(.menu)
            }
            formRow(label: "LLM Model:") {
                Text(viewModel.ollamaProfileStore.profiles.first { $0.id == editableAgent.linkedOllamaProfileID }?.llmModelName ?? "No model selected")
                    .foregroundColor(.secondary)
            }
        }.padding(.vertical, 10)
    }
    
    private var agentCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Capabilities").font(.headline)
            
            formRow(label: "Agent Tools:") {
                VStack(alignment: .leading, spacing: 12) {
                    Menu {
                        toolMenuContent()
                    } label: {
                        Text("Add Tool...")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    if !editableAgent.tools.isEmpty {
                        LazyVGrid(columns: toolCapsuleColumns, alignment: .leading, spacing: 8) {
                            ForEach(editableAgent.tools) { selectedTool in
                                ToolCapsuleView(tool: selectedTool) {
                                    removeTool(withId: selectedTool.id)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }
    
    @ViewBuilder
    private func toolMenuContent() -> some View {
        ForEach(toolStore.providers) { provider in
            Section(header: Text(provider.displayName)) {
                ForEach(provider.availableTools) { tool in
                    Button(tool.id) {
                        addTool(tool, from: provider)
                    }
                    .disabled(editableAgent.tools.contains { $0.id == tool.id && $0.providerID == provider.id })
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Delete Profile") { showingDeleteConfirm = true }
                .foregroundColor(.red)
                .buttonStyle(.bordered)
            
            Spacer()
            Button("Save") { saveChanges() }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges || !isAgentDataValid())
        }
        .padding()
        .background(.bar)
    }
    
    // MARK: - Helper UI
    
    @ViewBuilder
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 120, alignment: .leading)
                .padding(.top, 5)
            content()
            Spacer()
        }
    }
    
    // MARK: - Functions

    private func addTool(_ tool: ProvidedTool, from provider: ToolConfigModel) {
        let newSelectedTool = SelectedTool(id: tool.id, providerID: provider.id, displayName: tool.id)
        if !editableAgent.tools.contains(newSelectedTool) {
            editableAgent.tools.append(newSelectedTool)
        }
    }

    private func removeTool(withId toolId: String) {
        editableAgent.tools.removeAll { $0.id == toolId }
    }
    
    private func checkForChanges() {
        hasUnsavedChanges = (editableAgent != agent)
    }

    private func saveChanges() {
        // First, apply the changes from the local editable state to the binding
        agent.name = editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.baseURL = editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.role = editableAgent.role.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.linkedOllamaProfileID = editableAgent.linkedOllamaProfileID
        agent.tools = editableAgent.tools
        
        // MODIFIED: Explicitly call the agent store to persist the changes to Core Data.
        // This is the crucial step to ensure data is saved correctly.
        viewModel.agentStore.updateAgent(agent: agent)
        
        hasUnsavedChanges = false
        logger.info("Saved changes for agent: \(agent.name)")
    }
    
    private func resetState(with newAgent: AgentProfileModel) {
        if editableAgent != newAgent {
            editableAgent = newAgent
            hasUnsavedChanges = false
        }
    }

    private func isAgentDataValid() -> Bool {
        !editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}


// MARK: - Supporting Views

struct ToolCapsuleView: View {
    let tool: SelectedTool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(tool.displayName)
                .font(.system(size: 12))
                .lineLimit(1)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.primary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .background(Circle().fill(.primary.opacity(0.15)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.08))
        .cornerRadius(20)
    }
}

// MARK: - Preview Provider

struct AgentDetailView_PreviewContainer: View {
    @State private var agent: AgentProfileModel
    @State private var hasUnsavedChanges = false
    
    private let viewModel: MainApplicationViewModel
    private let toolStore: ToolStore

    init() {
        // Initialize mock stores
        let ollamaProfileStore = OllamaProfileStore()
        let agentStore = AgentStore()
        let ts = ToolStore()
        
        // Create a mock agent profile
        var mockAgent = AgentProfileModel.defaultAgent()
        
        // Add some mock tools to the agent for a more complete preview
        if let provider = ts.providers.first, let tool = provider.availableTools.first {
            mockAgent.tools.append(SelectedTool(id: tool.id, providerID: provider.id, displayName: tool.id))
        }
        if let provider = ts.providers.last, let tool = provider.availableTools.first {
             mockAgent.tools.append(SelectedTool(id: tool.id, providerID: provider.id, displayName: tool.id))
        }
        
        // Setup the stores with mock data
        agentStore.agents = [mockAgent]
        // We need at least one Ollama profile for the picker to work
        if ollamaProfileStore.profiles.isEmpty {
            ollamaProfileStore.profiles.append(OllamaProfileModel.defaultProfile())
        }
        mockAgent.linkedOllamaProfileID = ollamaProfileStore.profiles.first?.id

        // Initialize state and environment objects
        _agent = State(initialValue: mockAgent)
        viewModel = MainApplicationViewModel(ollamaProfileStore: ollamaProfileStore, agentStore: agentStore)
        toolStore = ts
    }

    var body: some View {
        AgentDetailView(
            agent: $agent,
            hasUnsavedChanges: $hasUnsavedChanges,
            onDelete: { print("Delete action triggered in preview.") }
        )
        .environmentObject(viewModel)
        .environmentObject(toolStore)
    }
}

struct AgentDetailView_Previews: PreviewProvider {
    static var previews: some View {
        AgentDetailView_PreviewContainer()
            .frame(width: 650)
            .previewLayout(.sizeThatFits)
            .padding()
    }
}
