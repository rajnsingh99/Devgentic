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

extension Binding where Value == String? {
    var toNonOptionalString: Binding<String> {
        // Now uses the generic helper for consistency.
        self.toNonOptional(defaultValue: "")
    }
}


struct AddLLMIntegrationView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @Environment(\.dismiss) var dismiss

    // MARK: - State Management
    @State private var newIntegration = LLMIntegrationModel.new()
    @State private var selectedProviderType: ProviderType = .ollama
    
    enum ValidationState: Equatable {
        case idle
        case checking
        case success(models: [String])
        case failed(error: String)
    }
    @State private var validationState: ValidationState = .idle
    
    private var isChecking: Bool { validationState == .checking }
    
    private var canCheckConnection: Bool {
        if selectedProviderType == .ollama {
            return !(newIntegration.ollamaBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } else {
            return !(newIntegration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
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
                
                Picker("Provider Type:", selection: $selectedProviderType) {
                    ForEach(ProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                
                Divider()

                if selectedProviderType == .ollama {
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
        .onChange(of: selectedProviderType) { _, newType in
            newIntegration.providerType = newType
            validationState = .idle
        }
    }

    // MARK: - Subviews
    private var ollamaFields: some View {
        Group {
            TextField("Base URL:", text: $newIntegration.ollamaBaseURL.toNonOptionalString, prompt: Text("e.g., http://localhost:11434"))
                .disabled(isChecking)
        }
    }

    private var remoteFields: some View {
        Group {
            Picker("Provider:", selection: $newIntegration.remoteProvider.toNonOptional(defaultValue: .openAI)) {
                ForEach(RemoteProvider.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(isChecking)
            
            SecureField("API Key:", text: $newIntegration.apiKey.toNonOptionalString, prompt: Text("Enter your API key"))
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
                if selectedProviderType == .ollama {
                    let url = newIntegration.ollamaBaseURL ?? ""
                    models = try await LLMConnectService.validateOllama(baseURL: url)
                } else {
                    let provider = newIntegration.remoteProvider ?? .openAI
                    let key = newIntegration.apiKey ?? ""
                    models = try await LLMConnectService.validateRemoteAPI(provider: provider, apiKey: key)
                }
                validationState = .success(models: models)
                
                if let firstModel = models.first {
                    if selectedProviderType == .ollama {
                        newIntegration.ollamaModelName = firstModel
                    } else {
                        newIntegration.remoteModelName = firstModel
                    }
                }
            } catch {
                validationState = .failed(error: error.localizedDescription)
            }
        }
    }
    
    private func addIntegration() {
        llmIntegrationStore.addIntegration(model: newIntegration)
        dismiss()
    }
    
    private func modelSelectionBinding() -> Binding<String> {
        if selectedProviderType == .ollama {
            return $newIntegration.ollamaModelName.toNonOptionalString
        } else {
            return $newIntegration.remoteModelName.toNonOptionalString
        }
    }
}
