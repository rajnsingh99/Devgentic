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
    @Binding var agent: Agent // Now receives a Binding to the agent

    // State for editable fields
    @State private var editableAgentName: String
    @State private var editableAgentURL: String
    @State private var editableAgentDescription: String
    @State private var selectedOllamaProfileID: UUID? // For Ollama Profile Chooser
    @State private var selectedAgentTool: String // For Agent Tools

    init(agent: Binding<Agent>) {
        _agent = agent // Assign the binding directly
        _editableAgentName = State(initialValue: agent.wrappedValue.name)
        _editableAgentURL = State(initialValue: agent.wrappedValue.baseURL)
        _editableAgentDescription = State(initialValue: agent.wrappedValue.description)
        _selectedOllamaProfileID = State(initialValue: agent.wrappedValue.linkedOllamaProfileID)
        _selectedAgentTool = State(initialValue: agent.wrappedValue.selectedAgentTool)
    }

    var body: some View {
        // Replaced Form with VStack for custom layout control
        VStack(alignment: .leading, spacing: 20) { // Added spacing between sections
            // MARK: - Profile Details Section
            VStack(alignment: .leading, spacing: 10) { // Spacing for elements within the section
                Text("Profile Details")
                    .font(.headline)
                    .padding(.bottom, 5) // Padding below section header

                // HStack for Profile Name
                HStack {
                    Text("Profile Name:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentName)
                        .textFieldStyle(.roundedBorder) // Apply a style to match Form's appearance
                    Button("Update") {
                        agent.name = editableAgentName
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentName == agent.name || editableAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // HStack for Agent URL
                HStack {
                    Text("Agent URL:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentURL)
                        .textFieldStyle(.roundedBorder)
                    Button("Update") {
                        agent.baseURL = editableAgentURL
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentURL == agent.baseURL || editableAgentURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                // HStack for Description
                HStack {
                    Text("Description:")
                        .frame(width: 120, alignment: .leading)
                    TextField("", text: $editableAgentDescription)
                        .textFieldStyle(.roundedBorder)
                    Button("Update") {
                        agent.description = editableAgentDescription
                    }
                    .buttonStyle(.bordered)
                    .disabled(editableAgentDescription == agent.description || editableAgentDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, 10) // Padding for the entire section content
            .padding(.horizontal) // Apply horizontal padding to the section
            .background(Color.secondary.opacity(0.1)) // Optional: Add a subtle background to mimic section grouping
            .cornerRadius(8) // Optional: Rounded corners for the section background

            // MARK: - LLM Integration Section
            VStack(alignment: .leading, spacing: 10) {
                Text("LLM Integration")
                    .font(.headline)
                    .padding(.bottom, 5)

                Picker(selection: $selectedOllamaProfileID) { // Removed inline label for explicit Text
                    Text("None").tag(nil as UUID?)
                    ForEach(viewModel.ollamaProfileStore.profiles) { profile in
                        Text(profile.profileName).tag(profile.id as UUID?)
                    }
                } label: { // Explicit label for Picker
                    Text("Ollama Profile:")
                        .frame(width: 120, alignment: .leading)
                }
                .help("Select an Ollama profile for this agent to use.")
                .pickerStyle(.menu) // Ensure it's a dropdown menu

                // MARK: New: Display selected LLM model name
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

                Picker(selection: $selectedAgentTool) { // Removed inline label for explicit Text
                    Text("None").tag("None")
                    Text("Code Interpreter").tag("Code Interpreter")
                    Text("Web Search").tag("Web Search")
                } label: { // Explicit label for Picker
                    Text("Agent Tools:")
                        .frame(width: 120, alignment: .leading)
                }
                .help("Select tools available to this agent.")
                .pickerStyle(.menu)

                Button("Orchestration Settings (Coming Soon)") {
                    logger.info("Orchestration Settings button tapped for agent: \(agent.name)")
                }
                .disabled(true)
                .buttonStyle(.bordered) // Apply a button style
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            // MARK: - Delete Agent Button (as a separate section or standalone)
            VStack(alignment: .leading) {
                Button("Delete Agent") {
                    logger.info("Delete button tapped for agent: \(agent.name)")
                    viewModel.agentStore.deleteAgent(id: agent.id)
                }
                .foregroundColor(.red)
                .buttonStyle(.bordered) // Apply a button style
            }
            .padding(.vertical, 10)
            .padding(.horizontal)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Spacer() // Pushes content to the top
        }
        .navigationTitle(agent.name)
        .padding(.horizontal) // Apply horizontal padding to the entire view
        .frame(maxWidth: .infinity, alignment: .leading) // Ensure content aligns to leading edge
    }
}

// MARK: - Preview Provider
struct AgentDetailView_Previews: PreviewProvider {
    // Create a mock AgentStore and MainApplicationViewModel for the preview
    static var mockAgentStore: AgentStore = {
        let store = AgentStore()
        if store.agents.isEmpty {
            store.agents.append(Agent.defaultAgent())
            store.agents.append(Agent(id: UUID(), name: "Test Agent", description: "Another agent for testing.", isActive: false, baseURL: "http://test:8000", linkedOllamaProfileID: nil, selectedAgentTool: "Web Search"))
        }
        return store
    }()

    static var mockOllamaProfileStore: OllamaProfileStore = {
        let store = OllamaProfileStore()
        if store.profiles.isEmpty {
            store.profiles.append(OllamaProfile.defaultProfile())
            store.profiles.append(OllamaProfile(id: UUID(), profileName: "Remote Ollama", baseURL: "http://remote:11434", llmModelName: "llama3:8b", temperature: 0.7, topK: 30, topP: 0.8, repeatPenalty: 1.0, contextWindowSize: 2048, gpuLayers: 0, maxInlineChars: 2000, maxAttachedFiles: 2, textFileInclusionStrategy: .preferInlining, imageHandlingStrategy: .includePathWithWarning, binaryFileHandlingStrategy: .includePathWithWarning))
            store.selectedProfileID = store.profiles.first?.id
        }
        return store
    }()

    static var mockMainApplicationViewModel: MainApplicationViewModel = {
        MainApplicationViewModel(
            ollamaService: OllamaService(), // Mock OllamaService
            ollamaProfileStore: mockOllamaProfileStore,
            agentStore: mockAgentStore
        )
    }()

    // Use a @State variable to hold the agent for the preview, as AgentDetailView expects a Binding
    @State static var previewAgent: Agent = mockAgentStore.agents.first ?? Agent.defaultAgent()

    static var previews: some View {
        AgentDetailView(agent: $previewAgent)
            .environmentObject(mockMainApplicationViewModel)
            .previewLayout(.sizeThatFits)
            .padding()
            .frame(width: 500, height: 700)
    }
}
