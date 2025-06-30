//
//  LLMIntegrationsView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMIntegrationsView")

struct LLMIntegrationsView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    // Add viewModel to pass it down to the detail view
    @EnvironmentObject var viewModel: MainApplicationViewModel
    
    @State private var showingAddIntegrationPopover = false

    var body: some View {
        NavigationSplitView {
            // Sidebar with a list of all integrations
            VStack(alignment: .leading) {
                HStack {
                    Text("Providers")
                        .font(.headline)
                        .padding([.leading, .top])
                    Spacer()
                    Button {
                        showingAddIntegrationPopover = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add New LLM Integration")
                    .padding([.trailing, .top])
                    .popover(isPresented: $showingAddIntegrationPopover, arrowEdge: .bottom) {
                        AddLLMIntegrationView()
                            .environmentObject(llmIntegrationStore)
                    }
                }
                List(selection: $llmIntegrationStore.selectedIntegrationID) {
                    ForEach(llmIntegrationStore.integrations) { integration in
                        IntegrationRowView(integration: integration)
                            .tag(integration.id)
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            // --- MODIFIED: Safely unwrap the binding to the detail view ---
            if let selectedID = llmIntegrationStore.selectedIntegrationID,
               let index = llmIntegrationStore.integrations.firstIndex(where: { $0.id == selectedID }) {
                
                // By finding the index, we can create a direct, non-optional binding.
                LLMIntegrationDetailView(integration: $llmIntegrationStore.integrations[index])
                    .environmentObject(viewModel) // Pass the viewModel down
                    .environmentObject(llmIntegrationStore)

            } else {
                Text("Select an integration to configure it, or add a new one.")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if llmIntegrationStore.selectedIntegrationID == nil {
                llmIntegrationStore.selectedIntegrationID = llmIntegrationStore.integrations.first?.id
            }
        }
    }
}

// MARK: - Integration Row View
private struct IntegrationRowView: View {
    let integration: LLMIntegrationModel

    var body: some View {
        HStack {
            Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                .font(.title3)
                .frame(width: 25, alignment: .center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading) {
                Text(integration.displayName)
                    .fontWeight(.medium)
                Text(integration.providerType.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}


// MARK: - Preview Provider
struct LLMIntegrationsView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock stores for the preview
        let integrationStore = LLMIntegrationStore()
        let agentStore = AgentStore()
        
        integrationStore.integrations = [
            .defaultOllama(),
            LLMIntegrationModel(id: UUID(), displayName: "OpenAI API", providerType: .remote, remoteProvider: .openAI, remoteModelName: "gpt-4o")
        ]
        integrationStore.selectedIntegrationID = integrationStore.integrations.first?.id
        
        // Create a mock viewModel to satisfy the environment dependency
        let mockViewModel = MainApplicationViewModel(
            llmIntegrationStore: integrationStore,
            agentStore: agentStore
        )
        
        return LLMIntegrationsView()
            .environmentObject(integrationStore)
            .environmentObject(mockViewModel)
            .frame(width: 800, height: 600)
    }
}
