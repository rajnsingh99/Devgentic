//
//  AgentDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 08/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "AgentDetailViewV3")

struct AgentDetailView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    
    @Binding var agent: AgentProfileModel
    @Binding var hasUnsavedChanges: Bool
    
    // Closure to handle the deletion action, provided by the parent
    var onDelete: () -> Void

    @State private var editableAgent: AgentProfileModel
    @State private var showingDeleteConfirm = false

    init(agent: Binding<AgentProfileModel>, hasUnsavedChanges: Binding<Bool>, onDelete: @escaping () -> Void) {
        self._agent = agent
        self._hasUnsavedChanges = hasUnsavedChanges
        self.onDelete = onDelete
        self._editableAgent = State(initialValue: agent.wrappedValue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                // --- Header ---
                Text("Agent Profile Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom, 5)

                Divider()

                // --- Profile Details Section ---
                VStack(alignment: .leading, spacing: 10) {
                    Text("Profile Details")
                        .font(.headline)
                    
                    HStack {
                        Text("Profile Name:")
                            .frame(width: 120, alignment: .leading)
                        TextField("Agent Name", text: $editableAgent.name)
                            .textFieldStyle(.roundedBorder)
                        if editableAgent.name != agent.name {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }
                    
                    HStack {
                        Text("Agent URL:")
                            .frame(width: 120, alignment: .leading)
                        TextField("Agent URL", text: $editableAgent.baseURL)
                            .textFieldStyle(.roundedBorder)
                        if editableAgent.baseURL != agent.baseURL {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }
                    
                    HStack {
                        Text("Role:")
                            .frame(width: 120, alignment: .leading)
                        TextField("Role", text: $editableAgent.role)
                            .textFieldStyle(.roundedBorder)
                        if editableAgent.role != agent.role {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }
                }
                .padding(.vertical, 10)

                Divider()

                // --- LLM Integration Section ---
                VStack(alignment: .leading, spacing: 10) {
                    Text("LLM Integration")
                        .font(.headline)

                    HStack {
                        Text("Ollama Profile:")
                            .frame(width: 120, alignment: .leading)
                        Picker("Ollama Profile", selection: $editableAgent.linkedOllamaProfileID) {
                            ForEach(viewModel.ollamaProfileStore.profiles) { profile in
                                Text(profile.profileName).tag(profile.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        
                        if editableAgent.linkedOllamaProfileID != agent.linkedOllamaProfileID {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }

                    HStack {
                        Text("LLM Model:")
                            .frame(width: 120, alignment: .leading)
                        Text(viewModel.ollamaProfileStore.profiles.first(where: { $0.id == editableAgent.linkedOllamaProfileID })?.llmModelName ?? "No model selected")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 10)

                Divider()
                
                // --- Agent Capabilities Section ---
                VStack(alignment: .leading, spacing: 10) {
                    Text("Agent Capabilities")
                        .font(.headline)

                    HStack {
                        Text("Agent Tools:")
                            .frame(width: 120, alignment: .leading)
                        Picker("Agent Tools", selection: $editableAgent.selectedAgentTool) {
                            Text("None").tag("None")
                            Text("Code Interpreter").tag("Code Interpreter")
                            Text("Web Search").tag("Web Search")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        
                        if editableAgent.selectedAgentTool != agent.selectedAgentTool {
                            Image(systemName: "circle.fill").foregroundColor(.blue).font(.system(size: 8))
                        }
                    }
                }
                .padding(.vertical, 10)
                
                Spacer()
            }
        }
        .padding()
        
        // --- Action Buttons ---
        HStack {
            if viewModel.agentStore.agents.count > 1 {
                Button("Delete Profile") {
                    showingDeleteConfirm = true
                }
                .foregroundColor(.red)
                .buttonStyle(.bordered)
            }
            
            Spacer()
            
            Button("Save") {
                saveChanges()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasUnsavedChanges || !isAgentDataValid())
        }
        .padding([.horizontal, .bottom])

        .onChange(of: editableAgent) { _, _ in checkForChanges() }
        .onChange(of: agent) { _, newAgent in
            resetState(with: newAgent)
        }
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
    
    // --- Helper Functions ---
    private func checkForChanges() {
        let changed = editableAgent != agent
        if changed != hasUnsavedChanges {
            hasUnsavedChanges = changed
        }
    }

    private func saveChanges() {
        var finalAgent = editableAgent
        finalAgent.name = editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        finalAgent.baseURL = editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        finalAgent.role = editableAgent.role.trimmingCharacters(in: .whitespacesAndNewlines)
        
        agent = finalAgent // Update the binding
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
        return !editableAgent.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
               !editableAgent.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
