//
//  SelectLLMIntegrationView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI

struct SelectLLMIntegrationView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @Binding var selectedIntegrationID: UUID?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Select an LLM Provider")
                .font(.title2)
                .padding()

            Divider()

            List(selection: $selectedIntegrationID) {
                ForEach(llmIntegrationStore.integrations) { integration in
                    HStack {
                        Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading) {
                            Text(integration.displayName).fontWeight(.semibold)
                            Text(integration.providerType.rawValue).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .tag(integration.id as UUID?)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Spacer()
                Button("Select") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIntegrationID == nil)
            }
            .padding()
        }
        .frame(minWidth: 400, idealWidth: 450, minHeight: 400, idealHeight: 500)
    }
}

struct SelectLLMIntegrationView_Previews: PreviewProvider {
    static var previews: some View {
        let store = LLMIntegrationStore()
        
        store.integrations = [
            .defaultOllama(),
            LLMIntegrationModel(
                id: UUID(),
                displayName: "Anthropic API",
                providerType: .remote,
                ollamaConfig: nil,
                remoteConfig: RemoteConfigModel(
                    provider: .anthropic, apiKey: "sk-abc", modelName: "claude-3-opus", temperature: 0.8, contextWindowSize: 200000
                )
            )
        ]
        
        return SelectLLMIntegrationView(selectedIntegrationID: .constant(store.integrations.first?.id))
            .environmentObject(store)
    }
}
