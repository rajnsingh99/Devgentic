//
//  AddLLMIntegrationView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI

//// MARK: - Binding Helper Extensions
//extension Binding {
//    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
//        Binding<T>(
//            get: { self.wrappedValue ?? defaultValue },
//            set: { self.wrappedValue = $0 }
//        )
//    }
//}

private let supportedGoogleModels: [String: [GenerationType]] = [
       "gemini-1.5-pro-latest": [.text],
       "gemini-2.5-pro": [.text],
       "gemini-2.5-flash": [.text],
       "gemma-3-27b-it": [.text],
       "gemini-1.5-flash-latest": [.text],
       "gemini-2.5-pro-preview-06-05": [.text],
       "gemini-1.5-pro-002": [.text],
       "gemma-3-12b-it": [.text],
       "gemini-2.0-flash": [.text],
       "gemini-2.5-flash-lite": [.text],
       "imagen-3.0-generate-002": [.imageData, .text],
       "imagen-4.0-generate-preview-06-06": [.imageData, .text],
       "gemini-2.0-flash-preview-image-generation": [.imageData, .text],
       "gemini-2.0-flash-exp-image-generation": [.imageData, .text]
   ]

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
        
        if case .success(let models) = validationState {
            if newIntegration.providerType == .remote, newIntegration.remoteConfig?.provider == .google {
                return !(newIntegration.remoteConfig?.modelName.isEmpty ?? true)
            } else {
                return !models.isEmpty
            }
        }
        return false
    }

    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                Text("Add New LLM Integration")
                    .font(.title2).fontWeight(.bold)
                Text("Configure a new local or remote LLM provider.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Form Content
            Form {
                Section(header: Text("General").font(.headline)) {
                    TextField("Display Name", text: $newIntegration.displayName)
                }

                Section(header: Text("Provider Type").font(.headline)) {
                    Picker("Provider Type", selection: $newIntegration.providerType) {
                        ForEach(ProviderType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(header: Text("Connection Details").font(.headline)) {
                    if newIntegration.providerType == .ollama {
                        ollamaFields
                    } else {
                        remoteFields
                    }
                }
                
                Section(header: Text("Validation").font(.headline)) {
                    validationSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden) // Makes form background transparent
            
            Divider()

            // Footer Buttons
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Add Integration") { addIntegration() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAddIntegration)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .background(.regularMaterial)
        .frame(minWidth: 450, idealWidth: 500, minHeight: 550)
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
        BindingView(binding: $newIntegration.ollamaConfig) { $config in
            TextField("Base URL", text: $config.baseURL, prompt: Text("e.g., http://localhost:11434"))
                .disabled(isChecking)
        }
    }

    private var remoteFields: some View {
        BindingView(binding: $newIntegration.remoteConfig) { $config in
            Picker("Provider", selection: $config.provider) {
                ForEach(RemoteProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(isChecking)
            
            SecureField("API Key", text: $config.apiKey, prompt: Text("Enter your API key"))
                .disabled(isChecking)
        }
    }
    
    @ViewBuilder
    private var validationSection: some View {
        VStack(spacing: 12) {
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
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!canCheckConnection || isChecking)
            
            switch validationState {
            case .idle:
                Text("Check your connection to fetch available models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            case .checking:
                EmptyView()
            case .success(let models):
                VStack {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("Connection Successful!").font(.headline)
                    }
                    modelSelector(models: models)
                }
            case .failed(let error):
                HStack {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }
        }
    }
    
    @ViewBuilder
    private func modelSelector(models: [String]) -> some View {
        if newIntegration.providerType == .remote, newIntegration.remoteConfig?.provider == .google {
            Picker("Default Model:", selection: modelSelectionBinding()) {
                ForEach(Array(supportedGoogleModels.keys).sorted(), id: \.self) { modelName in
                    Text(modelName).tag(modelName)
                }
            }
        } else if models.isEmpty {
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
                
                if newIntegration.providerType == .remote, newIntegration.remoteConfig?.provider == .google {
                    if let firstGoogleModel = supportedGoogleModels.keys.sorted().first {
                        newIntegration.remoteConfig?.modelName = firstGoogleModel
                        newIntegration.remoteConfig?.generationType = supportedGoogleModels[firstGoogleModel]
                    }
                } else if let firstModel = models.first {
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
        if newIntegration.providerType == .ollama {
            newIntegration.ollamaConfig?.temperature = 0.8
            newIntegration.ollamaConfig?.contextWindowSize = 4096
        } else {
            newIntegration.remoteConfig?.temperature = 0.8
            newIntegration.remoteConfig?.contextWindowSize = 4096
            
            if newIntegration.remoteConfig?.provider == .google, let modelName = newIntegration.remoteConfig?.modelName {
                newIntegration.remoteConfig?.generationType = supportedGoogleModels[modelName]
            }
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
    @ViewBuilder let content: (Binding<T>) -> Content

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
