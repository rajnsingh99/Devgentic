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
    
    @StateObject private var toolStore = ToolStore()
    
    @Binding var agent: AgentProfileModel
    @Binding var hasUnsavedChanges: Bool
    
    var onDelete: () -> Void

    @State private var editableAgent: AgentProfileModel
    @State private var showingDeleteConfirm = false
    @State private var showingSelectIntegrationSheet = false
    @State private var showingSelectToolSheet = false

    // Definition for the two-column grid layout for tools.
    private let toolGridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    init(agent: Binding<AgentProfileModel>, hasUnsavedChanges: Binding<Bool>, onDelete: @escaping () -> Void) {
        self._agent = agent
        self._hasUnsavedChanges = hasUnsavedChanges
        self.onDelete = onDelete
        self._editableAgent = State(initialValue: agent.wrappedValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                profileDetailsSection
                Divider()
                llmIntegrationSection
                Divider()
                agentCapabilitiesSection
                Spacer()
            }
        }
        .padding()
        .safeAreaInset(edge: .bottom) { actionButtons }
        .sheet(isPresented: $showingSelectIntegrationSheet) {
            SelectLLMIntegrationView(selectedIntegrationID: $editableAgent.linkedIntegrationID)
                .environmentObject(viewModel.llmIntegrationStore)
        }
        .sheet(isPresented: $showingSelectToolSheet) {
            SelectToolView(selectedTools: $editableAgent.tools)
                .environmentObject(toolStore)
        }
        .task(id: editableAgent.baseURL) {
            await toolStore.fetchAvailableTools(baseURL: editableAgent.baseURL)
        }
        .onChange(of: editableAgent) { _, _ in checkForChanges() }
        .onChange(of: agent) { _, newAgent in resetState(with: newAgent) }
        .alert("Delete Agent?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the agent named \"\(agent.name)\"? This action cannot be undone.")
        }
    }

    // MARK: - View Components

    private var profileDetailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            formRow(label: "Name:") {
                TextField("Name", text: $editableAgent.name)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            
            formRow(label: "Agent URL:") {
                TextField("Agent URL", text: $editableAgent.baseURL)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            
            formRow(label: "Instructions:") {
                let placeholder = """
                                - You are a senior software architect specializing in secure backend services.
                                - Your goal is to analyze user requirements and generate robust, scalable code.
                                - Always format code in markdown blocks. Explain your design choices clearly.
                                - Do not use deprecated libraries. Prioritize performance over readability if necessary.
                                """
                TextField(placeholder, text: $editableAgent.role, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(8...20)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
        }
    }

    private var llmIntegrationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LLM Provider").font(.headline)
                Spacer()
                Button("Link Provider...") { showingSelectIntegrationSheet = true }
            }
            
            if let integrationID = editableAgent.linkedIntegrationID,
               let integration = viewModel.llmIntegrationStore.integrations.first(where: { $0.id == integrationID }) {
                LLMIntegrationCardView(integration: integration)
            } else {
                ContentUnavailableView {
                    Label("No LLM Provider Linked", systemImage: "link.badge.plus")
                } description: {
                    Text("Link a LLM provider to enable this agent.")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }
    
    private var agentCapabilitiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent Capabilities").font(.headline)
                Spacer()
                Button("Select Tools...") { showingSelectToolSheet = true }
                .disabled(toolStore.isLoading)
            }
            
            if toolStore.isLoading {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading tools from agent URL...").foregroundColor(.secondary)
                }
            } else if let error = toolStore.errorMessage {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red).font(.caption)
            } else if editableAgent.tools.isEmpty {
                 ContentUnavailableView {
                    Label("No Tools Selected", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text("Click 'Select Tools' to add capabilities to this agent.")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            } else {
                LazyVGrid(columns: toolGridColumns, alignment: .leading, spacing: 12) {
                    ForEach(editableAgent.tools) { tool in
                        let details = toolStore.availableTools.first { $0.toolName == tool.toolName }
                        SelectedToolRowView(tool: tool, toolDetails: details) {
                            removeTool(withId: tool.id)
                        }
                    }
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Delete", role: .destructive) { showingDeleteConfirm = true }
            Spacer()
            Button("Revert") { resetState(with: agent) }.disabled(!hasUnsavedChanges)
            Button("Save") { saveChanges() }.buttonStyle(.borderedProminent).disabled(!hasUnsavedChanges || !isAgentDataValid())
        }
        .padding()
    }
    
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top) {
            Text(label).frame(width: 100, alignment: .trailing).padding(.top, 5)
            content()
        }
    }
    
    // MARK: - Functions
    private func removeTool(withId toolId: String) {
        editableAgent.tools.removeAll { $0.id == toolId }
    }
    
    private func checkForChanges() {
        hasUnsavedChanges = (editableAgent != agent)
    }

    private func saveChanges() {
        agent.name = editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.baseURL = editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.role = editableAgent.role.trimmingCharacters(in: .whitespacesAndNewlines)
        agent.linkedIntegrationID = editableAgent.linkedIntegrationID
        agent.tools = editableAgent.tools
        viewModel.agentStore.updateAgent(agent: agent)
        hasUnsavedChanges = false
    }
    
    private func resetState(with newAgent: AgentProfileModel) {
        if editableAgent != newAgent {
            editableAgent = newAgent
            hasUnsavedChanges = false
        }
    }

    private func isAgentDataValid() -> Bool {
        !editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        editableAgent.linkedIntegrationID != nil
    }
}

// MARK: - Supporting Views
private struct LLMIntegrationCardView: View {
    let integration: LLMIntegrationModel
    
    private var modelName: String {
        if integration.providerType == .ollama {
            return integration.ollamaConfig?.modelName ?? "Not Set"
        } else {
            return integration.remoteConfig?.modelName ?? "Not Set"
        }
    }
    
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                .font(.largeTitle).foregroundColor(.accentColor).frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(integration.displayName).font(.headline)
                Text("Model: \(modelName)").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
    }
}

private struct SelectedToolRowView: View {
    let tool: SelectedTool
    let toolDetails: ToolModel?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 30, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.displayName)
                    .fontWeight(.semibold)
                
                if let description = toolDetails?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Remove this tool")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Preview Provider
#if DEBUG
struct AgentDetailView_Previews: PreviewProvider {
    
    // A stateful container to host the AgentDetailView for previewing.
    struct PreviewContainer: View {
        @State private var agent: AgentProfileModel
        @State private var hasUnsavedChanges = false
        
        private let viewModel: MainApplicationViewModel

        init() {
            // 1. Create mock stores
            let llmIntegrationStore = LLMIntegrationStore()
            let agentStore = AgentStore()
            
            // 2. Create a mock LLM integration
            let mockIntegration = LLMIntegrationModel.defaultOllama()
            llmIntegrationStore.integrations = [mockIntegration]
            llmIntegrationStore.selectedIntegrationID = mockIntegration.id

            // 3. Create a mock agent and link it to the integration
            var mockAgent = AgentProfileModel.defaultAgent()
            mockAgent.name = "Multi-Tool Agent"
            mockAgent.linkedIntegrationID = mockIntegration.id
            
            // 4. Create 10 mock tools for the agent
            mockAgent.tools = (1...10).map { i in
                SelectedTool(toolName: "sample_tool_\(i)", displayName: "Sample Tool \(i)")
            }
            
            agentStore.agents = [mockAgent]
            
            // 5. Initialize the main view model with mock data
            self.viewModel = MainApplicationViewModel(
                llmIntegrationStore: llmIntegrationStore,
                agentStore: agentStore
            )
            
            // 6. Initialize the state for the container
            self._agent = State(initialValue: mockAgent)
        }

        var body: some View {
            AgentDetailView(
                agent: $agent,
                hasUnsavedChanges: $hasUnsavedChanges,
                onDelete: { print("Delete action triggered in preview.") }
            )
            .environmentObject(viewModel)
        }
    }

    static var previews: some View {
        PreviewContainer()
            .frame(width: 700, height: 700)
    }
}
#endif
