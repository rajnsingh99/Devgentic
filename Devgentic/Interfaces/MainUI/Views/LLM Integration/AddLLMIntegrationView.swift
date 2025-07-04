//
//  AddLLMIntegrationView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI

// MARK: - Binding Helper Extensions
extension Binding {
    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}

struct AddLLMIntegrationView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @Environment(\.dismiss) var dismiss

    // MARK: - State Management
    @State private var newIntegration = LLMIntegrationModel.new()
    
    enum ValidationState: Equatable {
        case idle
        case checking
        case success(models: [String])
        case failed(error: String)
    }
    @State private var validationState: ValidationState = .idle
    
    private var isChecking: Bool { validationState == .checking }
    
    private var canCheckConnection: Bool {
        if newIntegration.providerType == .ollama {
            return !(newIntegration.ollamaConfig?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } else {
            return !(newIntegration.remoteConfig?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    
    private var canAddIntegration: Bool {
        guard !newIntegration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .success(let models) = validationState, !models.isEmpty {
            return true
        }
        return false
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 15) {
            Text("Add New LLM Integration")
                .font(.title2).fontWeight(.bold)

            Form {
                TextField("Display Name:", text: $newIntegration.displayName)
                
                Picker("Provider Type:", selection: $newIntegration.providerType) {
                    ForEach(ProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                
                Divider()

                if newIntegration.providerType == .ollama {
                    ollamaFields
                } else {
                    remoteFields
                }
                
                validationSection
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add Integration") { addIntegration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddIntegration)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450)
        .onChange(of: newIntegration.providerType) { _, newType in
            // When provider type changes, reset the config models and validation state
            validationState = .idle
            if newType == .ollama {
                newIntegration.remoteConfig = nil
                if newIntegration.ollamaConfig == nil {
                    newIntegration.ollamaConfig = OllamaConfigModel(baseURL: "http://localhost:11434", modelName: "")
                }
            } else {
                newIntegration.ollamaConfig = nil
                if newIntegration.remoteConfig == nil {
                    newIntegration.remoteConfig = RemoteConfigModel(provider: .openAI, apiKey: "", modelName: "")
                }
            }
        }
    }

    // MARK: - Subviews
    private var ollamaFields: some View {
        // Use a binding to the nested config model. Since the view logic ensures
        // ollamaConfig is non-nil when this view is shown, we can safely unwrap.
        BindingView(binding: $newIntegration.ollamaConfig) { $config in
            TextField("Base URL:", text: $config.baseURL, prompt: Text("e.g., http://localhost:11434"))
                .disabled(isChecking)
        }
    }

    private var remoteFields: some View {
        BindingView(binding: $newIntegration.remoteConfig) { $config in
            Picker("Provider:", selection: $config.provider) {
                ForEach(RemoteProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(isChecking)
            
            SecureField("API Key:", text: $config.apiKey, prompt: Text("Enter your API key"))
                .disabled(isChecking)
        }
    }
    
    @ViewBuilder
    private var validationSection: some View {
        VStack {
            Button(action: performValidation) {
                HStack {
                    if isChecking {
                        ProgressView().controlSize(.small)
                        Text("Checking...")
                    } else {
                        Image(systemName: "network")
                        Text("Check Connection & Fetch Models")
                    }
                }
            }
            .disabled(!canCheckConnection || isChecking)
            .frame(maxWidth: .infinity)
            
            switch validationState {
            case .idle, .checking:
                EmptyView()
            case .success(let models):
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Connection successful!").font(.caption)
                }
                modelSelector(models: models)
            case .failed(let error):
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(error).font(.caption).foregroundColor(.red)
                }
            }
        }
        .padding(.top, 5)
    }
    
    @ViewBuilder
    private func modelSelector(models: [String]) -> some View {
        if models.isEmpty {
            Text("No compatible models found for this provider.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 5)
        } else {
            Picker("Default Model:", selection: modelSelectionBinding()) {
                ForEach(models, id: \.self) { modelName in
                    Text(modelName).tag(modelName)
                }
            }
        }
    }
    
    // MARK: - Logic
    private func performValidation() {
        validationState = .checking
        Task {
            do {
                let models: [String]
                if newIntegration.providerType == .ollama, let config = newIntegration.ollamaConfig {
                    models = try await LLMConnectService.validateOllama(config: config)
                } else if newIntegration.providerType == .remote, let config = newIntegration.remoteConfig {
                    models = try await LLMConnectService.validateRemoteAPI(config: config)
                } else {
                    throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey: "Configuration is missing."])
                }
                
                validationState = .success(models: models)
                
                // Set the first model as the default selection
                if let firstModel = models.first {
                    if newIntegration.providerType == .ollama {
                        newIntegration.ollamaConfig?.modelName = firstModel
                    } else {
                        newIntegration.remoteConfig?.modelName = firstModel
                    }
                }
            } catch {
                validationState = .failed(error: error.localizedDescription)
            }
        }
    }
    
    private func addIntegration() {
        // Set default temperature and context size before adding
        if newIntegration.providerType == .ollama {
            newIntegration.ollamaConfig?.temperature = 0.8
            newIntegration.ollamaConfig?.contextWindowSize = 4096
        } else {
            newIntegration.remoteConfig?.temperature = 0.8
            newIntegration.remoteConfig?.contextWindowSize = 4096
        }
        llmIntegrationStore.addIntegration(model: newIntegration)
        dismiss()
    }
    
    private func modelSelectionBinding() -> Binding<String> {
        if newIntegration.providerType == .ollama {
            return $newIntegration.ollamaConfig.toNonOptional(defaultValue: .init(baseURL: "", modelName: "")).modelName
        } else {
            return $newIntegration.remoteConfig.toNonOptional(defaultValue: .init(provider: .openAI, apiKey: "", modelName: "")).modelName
        }
    }
}

/// A helper view to safely unwrap an optional binding for use in a subview.
struct BindingView<T, Content: View>: View {
    @Binding var binding: T?
    @ViewBuilder let content: (Binding<T>) -> Content // Add @ViewBuilder here

    var body: some View {
        if let wrappedValue = binding {
            let b = Binding(
                get: { wrappedValue },
                set: { binding = $0 }
            )
            content(b)
        }
    }
}
