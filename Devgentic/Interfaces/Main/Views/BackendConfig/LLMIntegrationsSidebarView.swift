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
extension LLMIntegrationModel {
    var modelIdentifier: String? {
        switch providerType {
        case .ollama: return ollamaConfig?.modelName
        case .remote: return remoteConfig?.modelName
        }
    }
    
    var temperature: Double? {
        switch providerType {
        case .ollama: return ollamaConfig?.temperature
        case .remote: return remoteConfig?.temperature
        }
    }
    
    var contextWindowSize: Int? {
        switch providerType {
        case .ollama: return ollamaConfig?.contextWindowSize
        case .remote: return remoteConfig?.contextWindowSize
        }
    }
    
    var apiKey: String? {
        guard providerType == .remote else { return nil }
        return remoteConfig?.apiKey
    }
}


// MARK: - Main Sidebar View for LLM Integrations
struct LLMIntegrationsSidebarView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore

    @State private var selectedIntegrationForEditing: LLMIntegrationModel?
    @Binding var sidebarWidth: CGFloat

    var body: some View {
        // The VSplitView is now the top-level component, with headers handled by the parent view.
        VSplitView {
            // --- Top Pane: List of Integrations (No header here) ---
//            IntegrationsList(
//                integrations: llmIntegrationStore.integrations,
//                selectedIntegrationForEditing: $selectedIntegrationForEditing,
//                activeIntegrationID: viewModel.backendConfiguration.selectedIntegrationID
//            )
//            .frame(minHeight: 150, idealHeight: 250)

            // --- Bottom Pane: Settings (No header here) ---
            LLMIntegrationSettingsView(
                integration: $selectedIntegrationForEditing,
                llmIntegrationStore: llmIntegrationStore,
                ollamaService: viewModel.ollamaService
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedIntegrationForEditing == nil {
                selectedIntegrationForEditing = llmIntegrationStore.integrations.first
            }
        }
        .onDisappear {
            viewModel.ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Top Pane: Integrations List (Simplified)
private struct IntegrationsList: View {
    let integrations: [LLMIntegrationModel]
    @Binding var selectedIntegrationForEditing: LLMIntegrationModel?
    let activeIntegrationID: UUID?

    var body: some View {
        // The view is now just the List, as the header and buttons are moved.
        List(selection: $selectedIntegrationForEditing) {
            ForEach(integrations) { integration in
                IntegrationListRow(
                    integration: integration,
                    isActiveForChat: activeIntegrationID == integration.id
                )
                .tag(integration)
            }
        }
        .listStyle(.sidebar)
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


// MARK: - Bottom Pane: Advanced Settings
private struct LLMIntegrationSettingsView: View {
    @Binding var integration: LLMIntegrationModel?
    @ObservedObject var llmIntegrationStore: LLMIntegrationStore
    @ObservedObject var ollamaService: OllamaService
    
    @State private var displayName: String = ""
    @State private var apiKey: String = ""
    @State private var modelName: String = ""
    @State private var temperature: Double = 0.8
    @State private var contextWindow: Int = 4096

    var body: some View {
        if let currentIntegration = integration {
            // The Form is now the top-level view here.
            Form {
                // The title "Advanced Settings" has been removed from here.
                Section {
                    TextField("Display Name", text: $displayName)
                }

                Section("Authentication") {
                    if currentIntegration.providerType == .remote {
                        SecureField("API Key", text: $apiKey)
                    } else if let ollamaConfig = currentIntegration.ollamaConfig {
                        TextField("Ollama Base URL", text: .constant(ollamaConfig.baseURL))
                            .disabled(true)
                    }
                }
                
                Section("Model Configuration") {
                    TextField("Model Name / ID", text: $modelName)
                    
                    Slider(value: $temperature, in: 0...2, step: 0.1) {
                        Text("Temperature")
                    } minimumValueLabel: {
                        Text("0.0")
                    } maximumValueLabel: {
                        Text("2.0")
                    }
                    
                    Stepper("Context Window: \(contextWindow)", value: $contextWindow, step: 1024)
                }
                
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
                        updateLocalState(from: currentIntegration)
                    }.disabled(isUnchanged(from: currentIntegration))
                    
                    Button("Apply") {
                        logger.info("Apply button clicked for \(self.displayName)")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUnchanged(from: currentIntegration))
                }
            }
            .padding()
            .navigationTitle(displayName)
            .onChange(of: integration) { newIntegration in
                if let newIntegration = newIntegration {
                    updateLocalState(from: newIntegration)
                }
            }
            .onAppear {
                updateLocalState(from: currentIntegration)
            }
        } else {
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
    
    private func updateLocalState(from model: LLMIntegrationModel) {
        self.displayName = model.displayName
        self.modelName = model.modelIdentifier ?? ""
        self.temperature = model.temperature ?? 0.8
        self.contextWindow = model.contextWindowSize ?? 4096
        self.apiKey = model.apiKey ?? ""
    }
    
    private func isUnchanged(from model: LLMIntegrationModel) -> Bool {
        return displayName == model.displayName &&
               modelName == (model.modelIdentifier ?? "") &&
               temperature == (model.temperature ?? 0.8) &&
               contextWindow == (model.contextWindowSize ?? 4096) &&
               apiKey == (model.apiKey ?? "")
    }
}


// MARK: - Local Models Section
private struct LocalModelsSection: View {
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    
    var body: some View {
        Section("Local LLMs for Active Profile") {
            HStack {
                Text("Ollama Server Status:")
                Spacer()
                OllamaStatusView(ollamaService: ollamaService)
            }
            Text("(Local model list would appear here)")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Ollama Status View
private struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService
    var body: some View {
        Text(ollamaService.serverStatus.rawValue.capitalized)
            .foregroundColor(ollamaService.serverStatus == .connected ? .green : .red)
    }
}
