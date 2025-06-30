//
//  AddLLMIntegrationView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI

struct AddLLMIntegrationView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @Environment(\.dismiss) var dismiss

    @State private var newIntegration = LLMIntegrationModel.new()
    @State private var selectedProviderType: ProviderType = .ollama

    var isFormValid: Bool {
        !newIntegration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Add New LLM Integration")
                .font(.title2)
                .fontWeight(.bold)

            Form {
                TextField("Display Name:", text: $newIntegration.displayName)
                
                Picker("Provider Type:", selection: $selectedProviderType) {
                    ForEach(ProviderType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedProviderType) { _, newType in
                    newIntegration.providerType = newType
                }

                Divider()

                // Show fields based on the selected provider type
                if selectedProviderType == .ollama {
                    ollamaFields
                } else {
                    remoteFields
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add Integration") {
                    // Set default values before adding
                    if newIntegration.providerType == .ollama {
                        newIntegration.ollamaBaseURL = newIntegration.ollamaBaseURL?.isEmpty ?? true ? "http://localhost:11434" : newIntegration.ollamaBaseURL
                        newIntegration.ollamaModelName = newIntegration.ollamaModelName?.isEmpty ?? true ? "llama3" : newIntegration.ollamaModelName
                    }
                    llmIntegrationStore.addIntegration(model: newIntegration)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isFormValid)
            }
        }
        .padding(20)
        .frame(minWidth: 400, idealWidth: 450)
    }

    private var ollamaFields: some View {
        Group {
            TextField("Base URL (optional):", text: Binding(
                get: { newIntegration.ollamaBaseURL ?? "" },
                set: { newIntegration.ollamaBaseURL = $0 }
            ))
            .placeholder(when: newIntegration.ollamaBaseURL?.isEmpty ?? true) {
                Text("e.g., http://localhost:11434").foregroundColor(.gray)
            }
            
            TextField("Default Model (optional):", text: Binding(
                get: { newIntegration.ollamaModelName ?? "" },
                set: { newIntegration.ollamaModelName = $0 }
            ))
            .placeholder(when: newIntegration.ollamaModelName?.isEmpty ?? true) {
                Text("e.g., llama3").foregroundColor(.gray)
            }
        }
    }

    private var remoteFields: some View {
        Group {
            Picker("Provider:", selection: Binding(
                get: { newIntegration.remoteProvider ?? .openAI },
                set: { newIntegration.remoteProvider = $0 }
            )) {
                ForEach(RemoteProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            
            SecureField("API Key:", text: Binding(
                get: { newIntegration.apiKey ?? "" },
                set: { newIntegration.apiKey = $0 }
            ))
            
            TextField("Default Model:", text: Binding(
                get: { newIntegration.remoteModelName ?? "" },
                set: { newIntegration.remoteModelName = $0 }
            ))
        }
    }
}

// Helper for placeholder text in TextFields
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
