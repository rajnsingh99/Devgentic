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
    @EnvironmentObject var viewModel: MainApplicationViewModel

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
            Section() {
                TextField("Name:", text: $integration.displayName)
                HStack {
                    Text("Provider:")
                    Spacer()
                    HStack {
                        Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                        Text(integration.providerType.rawValue)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor)).cornerRadius(6)
                }
            }

            Divider().padding(.vertical, 10)

            modelConfigurationSection

            Spacer()
            
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
        .padding()
        .onAppear(perform: fetchAvailableModels)
        .onChange(of: integration.id) { _, _ in
            isApiKeyVisible = false
            fetchAvailableModels()
        }
        .onChange(of: integration) { _, _ in checkForChanges() }
    }
    
    // MARK: - Model Configuration Section
    @ViewBuilder
    private var modelConfigurationSection: some View {
        Section(header: Text("Configurations: ")) {
            if integration.providerType == .ollama {
                TextField("URL:", text: $integration.ollamaBaseURL.toNonOptionalString).padding()
            } else {
                HStack {
                    Text("Provider:").foregroundColor(.secondary)
                    Text(integration.remoteProvider?.rawValue ?? "Not Set")
                }
                
                HStack {
                    if isApiKeyVisible {
                        TextField("API Key:", text: $integration.apiKey.toNonOptionalString)
                    } else {
                        SecureField("API Key:", text: $integration.apiKey.toNonOptionalString)
                    }
                    
                    Button(action: { isApiKeyVisible.toggle() }) {
                        Image(systemName: isApiKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .help(isApiKeyVisible ? "Hide API Key" : "Show API Key")
                }
                .padding()
            }
            
            // Model Picker
            HStack(alignment: .firstTextBaseline) {
                if isLoadingModels {
                    ProgressView().controlSize(.small)
                    Text("Fetching models...").foregroundColor(.secondary)
                } else if let error = modelError {
                    Text("Error: \(error)").foregroundColor(.red).font(.caption)
                } else {
                    Picker("Model:", selection: modelSelectionBinding()) {
                        ForEach(availableModels, id: \.self) { modelName in
                            Text(modelName).tag(modelName)
                        }
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
            .padding(.bottom)
        }
    }

    // MARK: - Logic
    private func fetchAvailableModels() {
        isLoadingModels = true
        modelError = nil
        
        Task {
            do {
                let models: [String]
                if integration.providerType == .ollama {
                    guard let baseURL = integration.ollamaBaseURL, !baseURL.isEmpty else {
                        throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Ollama Base URL is not set."])
                    }
                    models = try await LLMConnectService.validateOllama(baseURL: baseURL)
                } else {
                    guard let provider = integration.remoteProvider, let apiKey = integration.apiKey, !apiKey.isEmpty else {
                        throw URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: "API Provider or Key is not set."])
                    }
                    models = try await LLMConnectService.validateRemoteAPI(provider: provider, apiKey: apiKey)
                }
                
                self.availableModels = models
                
                let currentModel = (integration.providerType == .ollama) ? integration.ollamaModelName : integration.remoteModelName
                if !models.contains(currentModel ?? "") {
                    if integration.providerType == .ollama {
                        integration.ollamaModelName = models.first
                    } else {
                        integration.remoteModelName = models.first
                    }
                }
                
            } catch {
                self.modelError = error.localizedDescription
                self.availableModels = []
            }
            isLoadingModels = false
        }
    }
    
    private func modelSelectionBinding() -> Binding<String> {
        if integration.providerType == .ollama {
            return $integration.ollamaModelName.toNonOptionalString
        } else {
            return $integration.remoteModelName.toNonOptionalString
        }
    }

    private func checkForChanges() {
        hasUnsavedChanges = (integration != originalIntegration)
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


// MARK: - Preview Provider
struct LLMIntegrationDetailView_Previews: PreviewProvider {
    
    // Helper container to manage state for previews
    struct PreviewContainer: View {
        @State var ollamaIntegration: LLMIntegrationModel
        @State var remoteIntegration: LLMIntegrationModel

        let llmIntegrationStore: LLMIntegrationStore
        let mainViewModel: MainApplicationViewModel

        init() {
            let store = LLMIntegrationStore()
            let ollama = LLMIntegrationModel.defaultOllama()
            let remote = LLMIntegrationModel(
                id: UUID(),
                displayName: "OpenAI API Key",
                providerType: .remote,
                remoteProvider: .openAI,
                apiKey: "sk-1234567890",
                remoteModelName: "gpt-4o"
            )
            store.integrations = [ollama, remote]
            
            self._ollamaIntegration = State(initialValue: ollama)
            self._remoteIntegration = State(initialValue: remote)
            self.llmIntegrationStore = store
            
            // Create a mock view model
            self.mainViewModel = MainApplicationViewModel(llmIntegrationStore: store, agentStore: AgentStore())
        }

        var body: some View {
            VStack(spacing: 30) {
                VStack {
                    Text("Ollama Provider Preview").font(.title3)
                    LLMIntegrationDetailView(integration: $ollamaIntegration)
                        .padding()
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(10)
                }
                
                Divider()
                
                VStack {
                    Text("Remote Provider Preview").font(.title3)
                    LLMIntegrationDetailView(integration: $remoteIntegration)
                        .padding()
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(10)
                }
            }
            .padding()
            .environmentObject(llmIntegrationStore)
            .environmentObject(mainViewModel)
            .frame(width: 600, height: 750)
        }
    }

    static var previews: some View {
        PreviewContainer()
    }
}
