//
//  LLMIntegrationsSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMIntegrationsSidebarView")

// MARK: - Model Extension for View Logic
// FIX: Add extension to provide unified access to model properties, resolving "no member" errors.
extension LLMIntegrationModel {
    /// Provides a unified way to access the model name/identifier, regardless of provider type.
    var modelIdentifier: String? {
        switch providerType {
        case .ollama:
            return ollamaConfig?.modelName
        case .remote:
            return remoteConfig?.modelName
        }
    }
    
    /// Provides a unified way to access the temperature setting.
    var temperature: Double? {
        switch providerType {
        case .ollama:
            return ollamaConfig?.temperature
        case .remote:
            return remoteConfig?.temperature
        }
    }
    
    /// Provides a unified way to access the context window size.
    var contextWindowSize: Int? {
        switch providerType {
        case .ollama:
            return ollamaConfig?.contextWindowSize
        case .remote:
            return remoteConfig?.contextWindowSize
        }
    }
    
    /// Provides a unified way to access the API key, which is only relevant for remote providers.
    var apiKey: String? {
        guard providerType == .remote else { return nil }
        return remoteConfig?.apiKey
    }
}


// MARK: - Main Sidebar View for LLM Integrations
struct LLMIntegrationsSidebarView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    // Direct access to the store for the list of integrations
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore

    // State to track which integration is selected for viewing/editing in the bottom pane.
    @State private var selectedIntegrationForEditing: LLMIntegrationModel?
    
    // The `sidebarWidth` binding is passed from the parent view but is not directly used here,
    // as the VSplitView manages its own internal dimensions. It's kept for potential future use
    // or to maintain API consistency with the parent view.
    @Binding var sidebarWidth: CGFloat


    var body: some View {
        // VSplitView creates the horizontal top/bottom split, as requested.
        VSplitView {
            // --- Top Pane: List of Integrations ---
            IntegrationsList(
                integrations: llmIntegrationStore.integrations,
                // The list selection is bound to our state variable.
                selectedIntegrationForEditing: $selectedIntegrationForEditing,
                // Pass the active ID to show the checkmark for the chat-active model.
                activeIntegrationID: viewModel.backendConfiguration.selectedIntegrationID,
                llmIntegrationStore: llmIntegrationStore
            )
            .frame(minHeight: 150, idealHeight: 250) // Define initial sizes for the top pane

            // --- Bottom Pane: Advanced Settings for the selected integration ---
            // FIX: Added a VStack to include a title for the settings pane.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Advanced Settings")
                        .font(.headline)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 5)
                
                LLMIntegrationSettingsView(
                    // Pass a binding to the selected integration.
                    integration: $selectedIntegrationForEditing,
                    llmIntegrationStore: llmIntegrationStore,
                    ollamaService: viewModel.ollamaService
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            // For a better user experience, select the first integration in the list by default.
            if selectedIntegrationForEditing == nil {
                selectedIntegrationForEditing = llmIntegrationStore.integrations.first
            }
        }
        .onDisappear {
            viewModel.ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Top Pane: Integrations List
private struct IntegrationsList: View {
    let integrations: [LLMIntegrationModel]
    @Binding var selectedIntegrationForEditing: LLMIntegrationModel?
    let activeIntegrationID: UUID?
    
    // We need the store for the "Add" button action.
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @State private var showingAddIntegrationPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header for the list pane
            HStack {
                Text("LLM Integrations")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddIntegrationPopover = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(PlainButtonStyle())
                .help("Add New LLM Integration")
                .popover(isPresented: $showingAddIntegrationPopover, arrowEdge: .bottom) {
                    // --- FIX: Uncommented the view presentation ---
                    AddLLMIntegrationView()
                         .environmentObject(llmIntegrationStore)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 5)

            // The main list. The 'selection' parameter provides two-way binding.
            List(selection: $selectedIntegrationForEditing) {
                ForEach(integrations) { integration in
                    IntegrationListRow(
                        integration: integration,
                        isActiveForChat: activeIntegrationID == integration.id
                    )
                    .tag(integration) // Each row must be tagged with its corresponding model object.
                }
            }
            .listStyle(.sidebar) // A style that fits well in a sidebar context.
        }
    }
}


// MARK: - Row View for the Integrations List
private struct IntegrationListRow: View {
    let integration: LLMIntegrationModel
    let isActiveForChat: Bool

    var body: some View {
        HStack {
            Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                .foregroundColor(.secondary)
            Text(integration.displayName)
            Spacer()
            if isActiveForChat {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .help("Active for new chats")
            }
        }
    }
}


// MARK: - Bottom Pane: Mocked Advanced Settings
private struct LLMIntegrationSettingsView: View {
    @Binding var integration: LLMIntegrationModel?
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @ObservedObject var ollamaService: OllamaService
    
    // Local state for editing properties before saving.
    @State private var displayName: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var temperature: Double = 0.8
    @State private var contextWindow: Int = 4096

    var body: some View {
        // Show settings only if an integration is selected.
        if let currentIntegration = integration {
            Form {
                Section {
                    TextField("Display Name", text: $displayName)
                }

                // FIX: Use trailing closure syntax for Section header to fix compiler error.
                Section {
                    if currentIntegration.providerType == .remote {
                        SecureField("API Key", text: $apiKey)
                    } else if let ollamaConfig = currentIntegration.ollamaConfig {
                        TextField("Ollama Base URL", text: .constant(ollamaConfig.baseURL))
                            .disabled(true)
                    }
                } header: {
                     Text("Authentication")
                }
                
                // FIX: Use trailing closure syntax for Section header to fix compiler error.
                Section {
                    TextField("Model Name / ID", text: $modelName)
                    
                    Slider(value: $temperature, in: 0...2, step: 0.1) {
                        Text("Temperature")
                    } minimumValueLabel: {
                        Text("0.0")
                    } maximumValueLabel: {
                        Text("2.0")
                    }
                    
                    Stepper("Context Window: \(contextWindow)", value: $contextWindow, step: 1024)
                } header: {
                    Text("Model Configuration")
                }
                
                // Conditionally show the local models section for Ollama integrations.
                if currentIntegration.providerType == .ollama,
                   let ollamaConfig = currentIntegration.ollamaConfig {
                    LocalModelsSection(
                        ollamaService: ollamaService,
                        ollamaBaseURL: ollamaConfig.baseURL
                    )
                }
                
                Spacer()
                
                HStack {
                    Spacer()
                    Button("Revert") {
                        // Reload state from the model object
                        updateLocalState(from: currentIntegration)
                    }.disabled(isUnchanged(from: currentIntegration))
                    
                    Button("Apply") {
                        // Here you would save the changes back to the store.
                        // For now, it's a placeholder action.
                        logger.info("Apply button clicked for \(self.displayName)")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUnchanged(from: currentIntegration))
                }
            }
            .padding()
            .navigationTitle(displayName)
            // When the selection from the list changes, update the local state of this view.
            .onChange(of: integration) { newIntegration in
                if let newIntegration = newIntegration {
                    updateLocalState(from: newIntegration)
                }
            }
            // Also load state when the view first appears.
            .onAppear {
                updateLocalState(from: currentIntegration)
            }
        } else {
            // A placeholder view for when no integration is selected.
            VStack {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Select an Integration")
                    .font(.title)
                    .padding(.top, 10)
                Text("Choose an integration from the list to view its settings.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    /// Helper function to load the view's state from a model object.
    private func updateLocalState(from model: LLMIntegrationModel) {
        // FIX: Use the computed properties from the extension to correctly access nested model data.
        self.displayName = model.displayName
        self.modelName = model.modelIdentifier ?? ""
        self.temperature = model.temperature ?? 0.8
        self.contextWindow = model.contextWindowSize ?? 4096
        self.apiKey = model.apiKey ?? "" // Use empty string for non-remote or missing key
    }
    
    /// Helper to check if local state differs from the model object, for enabling Apply/Revert buttons.
    private func isUnchanged(from model: LLMIntegrationModel) -> Bool {
        // FIX: Use the computed properties from the extension to correctly compare nested model data.
        return displayName == model.displayName &&
               modelName == (model.modelIdentifier ?? "") &&
               temperature == (model.temperature ?? 0.8) &&
               contextWindow == (model.contextWindowSize ?? 4096) &&
               apiKey == (model.apiKey ?? "")
    }
}


// MARK: - Local Models Section (Re-integrated into the settings pane)
private struct LocalModelsSection: View {
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    
    var body: some View {
        // FIX: Use trailing closure syntax for Section header to fix compiler error.
        Section {
            HStack {
                Text("Ollama Server Status:")
                Spacer()
                OllamaStatusView(ollamaService: ollamaService)
            }
            // You would list local models here, e.g., using another ForEach
            Text("(Local model list would appear here)")
                .foregroundColor(.secondary)
        } header: {
            Text("Local LLMs for Active Profile")
        }
    }
}

// MARK: - Ollama Status View (Placeholder)
private struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService
    var body: some View {
        // A more detailed status view can be built out here.
        Text(ollamaService.serverStatus.rawValue.capitalized)
            .foregroundColor(ollamaService.serverStatus == .connected ? .green : .red)
    }
}
