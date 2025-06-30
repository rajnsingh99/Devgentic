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
    
    // To show local models if it's an Ollama profile
    @EnvironmentObject var viewModel: MainApplicationViewModel

    @State private var originalIntegration: LLMIntegrationModel
    @State private var hasUnsavedChanges = false

    init(integration: Binding<LLMIntegrationModel>) {
        self._integration = integration
        self._originalIntegration = State(initialValue: integration.wrappedValue)
    }

    var body: some View {
        Form {
            Section(header: Text("Integration Details").font(.headline)) {
                TextField("Display Name:", text: $integration.displayName)
                
                Picker("Provider Type:", selection: $integration.providerType) {
                    ForEach(ProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            Divider().padding(.vertical, 10)

            if integration.providerType == .ollama {
                Section(header: Text("Ollama Configuration")) {
                    TextField("Base URL:", text: $integration.ollamaBaseURL.toNonOptionalString)
                    TextField("Default Model:", text: $integration.ollamaModelName.toNonOptionalString)
                }
                
            } else {
                Section(header: Text("Remote API Configuration")) {
                    // This Picker is now fixed using the corrected binding helper
                    Picker("Provider:", selection: $integration.remoteProvider.toNonOptional(defaultValue: .openAI)) {
                        ForEach(RemoteProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    
                    SecureField("API Key:", text: $integration.apiKey.toNonOptionalString)
                    TextField("Default Model:", text: $integration.remoteModelName.toNonOptionalString)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Delete", role: .destructive) {
                    llmIntegrationStore.deleteIntegration(id: integration.id)
                }
                .disabled(llmIntegrationStore.integrations.count <= 1)
                
                Spacer()
                
                Button("Revert") {
                    revertChanges()
                }
                .disabled(!hasUnsavedChanges)
                
                Button("Save") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges)
            }
        }
        .padding()
        .onChange(of: integration) { _, _ in
            checkForChanges()
        }
    }

    private func checkForChanges() {
        hasUnsavedChanges = (integration != originalIntegration)
    }

    private func saveChanges() {
        llmIntegrationStore.updateIntegration(model: integration)
        originalIntegration = integration // Update the original state
        hasUnsavedChanges = false
    }

    private func revertChanges() {
        integration = originalIntegration
        hasUnsavedChanges = false
    }
}

// MARK: - Binding Helpers (Corrected)

/// A generic helper that converts a `Binding<T?>` to a non-optional `Binding<T>`.
/// This is useful for UI controls like Pickers that require a non-optional binding.
extension Binding {
    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}

/// A specific helper that converts a `Binding<String?>` to a `Binding<String>`,
/// correctly handling the case where an empty string should be stored as `nil`.
extension Binding where Value == String? {
    var toNonOptionalString: Binding<String> {
        Binding<String>(
            get: { self.wrappedValue ?? "" },
            set: { self.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }
}
