//
//  LLMIntegrationDetailView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI

struct LLMIntegrationDetailView: View {
    @Binding var integration: LLMIntegrationModel
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore

    @State private var originalIntegration: LLMIntegrationModel
    @State private var hasUnsavedChanges = false
    
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelError: String? = nil
    
    @State private var isApiKeyVisible = false

    init(integration: Binding<LLMIntegrationModel>) {
        self._integration = integration
        self._originalIntegration = State(initialValue: integration.wrappedValue)
    }

    var body: some View {
        Form {
            Section {
                TextField("Display Name:", text: $integration.displayName)
                HStack {
                    Text("Provider Type:")
                    Spacer()
                    Text(integration.providerType.rawValue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                }
            }

            Divider().padding(.vertical, 10)

            modelConfigurationSection

            Spacer()
            
            actionButtons
        }
        .padding()
        .onAppear {
            self.originalIntegration = integration
            fetchAvailableModels()
        }
        .onChange(of: integration.id) { _, newId in
            isApiKeyVisible = false
            if let newIntegration = llmIntegrationStore.integrations.first(where: { $0.id == newId }) {
                self.integration = newIntegration
                self.originalIntegration = newIntegration
                fetchAvailableModels()
            }
        }
        .onChange(of: integration) { _, newIntegration in
            hasUnsavedChanges = (newIntegration != originalIntegration)
        }
    }
    
    @ViewBuilder
    private var modelConfigurationSection: some View {
        Section(header: Text("Configuration")) {
            if integration.providerType == .ollama {
                BindingView(binding: $integration.ollamaConfig) { $config in
                    TextField("Base URL:", text: $config.baseURL)
                    modelPicker(selection: $config.modelName)
                }
            } else {
                // --- FIXED: Added else block to correctly handle the remote provider case ---
                BindingView(binding: $integration.remoteConfig) { $config in
                    Text("Provider: \(config.provider.rawValue)")
                    
                    HStack {
                        if isApiKeyVisible {
                            TextField("API Key:", text: $config.apiKey)
                        } else {
                            SecureField("API Key:", text: $config.apiKey)
                        }
                        Button(action: { isApiKeyVisible.toggle() }) {
                            Image(systemName: isApiKeyVisible ? "eye.slash" : "eye")
                        }.buttonStyle(.plain)
                    }
                    
                    modelPicker(selection: $config.modelName)
                }
            }
        }
    }
    
    private var actionButtons: some View {
        HStack {
            Button("Delete", role: .destructive) {
                llmIntegrationStore.deleteIntegration(id: integration.id)
            }
            .disabled(llmIntegrationStore.integrations.count <= 1)
            
            Spacer()
            
            Button("Revert") { revertChanges() }.disabled(!hasUnsavedChanges)
            
            Button("Save") { saveChanges() }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges)
        }
    }
    
    @ViewBuilder
    private func modelPicker(selection: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if isLoadingModels {
                ProgressView().controlSize(.small)
                Text("Fetching models...").foregroundColor(.secondary)
            } else if let error = modelError {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundColor(.red).font(.caption)
            } else {
                Picker("Model:", selection: selection) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .disabled(availableModels.isEmpty)
            }
            
            Spacer()
            
            Button(action: fetchAvailableModels) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh model list")
            .disabled(isLoadingModels)
        }
    }

    private func fetchAvailableModels() {
        isLoadingModels = true
        modelError = nil
        availableModels = []
        
        Task {
            do {
                let models: [String]
                if integration.providerType == .ollama, let config = integration.ollamaConfig {
                    models = try await LLMConnectService.validateOllama(config: config)
                } else if integration.providerType == .remote, let config = integration.remoteConfig {
                    models = try await LLMConnectService.validateRemoteAPI(config: config)
                } else {
                    models = []
                }
                
                self.availableModels = models
                
                let currentModel: String? = (integration.providerType == .ollama) ? integration.ollamaConfig?.modelName : integration.remoteConfig?.modelName
                if !models.contains(currentModel ?? "") {
                    if integration.providerType == .ollama {
                        integration.ollamaConfig?.modelName = models.first ?? ""
                    } else {
                        integration.remoteConfig?.modelName = models.first ?? ""
                    }
                }
            } catch {
                self.modelError = error.localizedDescription
            }
            isLoadingModels = false
        }
    }

    private func saveChanges() {
        llmIntegrationStore.updateIntegration(model: integration)
        originalIntegration = integration
        hasUnsavedChanges = false
    }

    private func revertChanges() {
        integration = originalIntegration
        hasUnsavedChanges = false
    }
}

// MARK: - Preview Provider (Fixed)
struct LLMIntegrationDetailView_Previews: PreviewProvider {
    
    // Helper container to manage state for previews
    struct PreviewContainer: View {
        @State var ollamaIntegration: LLMIntegrationModel
        @State var remoteIntegration: LLMIntegrationModel

        let llmIntegrationStore: LLMIntegrationStore

        init() {
            let store = LLMIntegrationStore()
            
            // --- FIXED: Correctly initialize models using the new nested structure ---
            let ollama = LLMIntegrationModel.defaultOllama()
            let remote = LLMIntegrationModel(
                id: UUID(),
                displayName: "OpenAI API Key",
                providerType: .remote,
                ollamaConfig: nil,
                remoteConfig: RemoteConfigModel(
                    provider: .openAI,
                    apiKey: "sk-1234567890",
                    modelName: "gpt-4o",
                    temperature: 0.7,
                    contextWindowSize: 8192
                )
            )
            store.integrations = [ollama, remote]
            
            self._ollamaIntegration = State(initialValue: ollama)
            self._remoteIntegration = State(initialValue: remote)
            self.llmIntegrationStore = store
        }

        var body: some View {
            VStack(spacing: 30) {
                VStack {
                    Text("Ollama Provider Preview").font(.title3)
                    LLMIntegrationDetailView(integration: $ollamaIntegration)
                }
                Divider()
                VStack {
                    Text("Remote Provider Preview").font(.title3)
                    LLMIntegrationDetailView(integration: $remoteIntegration)
                }
            }
            .padding()
            .environmentObject(llmIntegrationStore)
            .frame(width: 600, height: 750)
        }
    }

    static var previews: some View {
        PreviewContainer()
    }
}
