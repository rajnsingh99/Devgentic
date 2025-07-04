//
//  LLMIntegrationsSidebarView.swift
//  Devgentic
//
//  Created by Raj Singh on 30/06/25.
//

import SwiftUI
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMIntegrationsSidebarView")

// MARK: - Main Sidebar View for LLM Integrations
struct LLMIntegrationsSidebarView: View {
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Binding var sidebarWidth: CGFloat

    // Computed property to find the currently selected Ollama integration
    private var activeOllamaIntegration: LLMIntegrationModel? {
        guard let selectedID = viewModel.llmIntegrationStore.selectedIntegrationID else { return nil }
        let integration = viewModel.llmIntegrationStore.integrations.first { $0.id == selectedID }
        return integration?.providerType == .ollama ? integration : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LLMIntegrationsSection()
                        .environmentObject(viewModel.llmIntegrationStore)

                    Divider()

                    // --- FIXED: Access baseURL from the nested ollamaConfig model ---
                    if let ollamaIntegration = activeOllamaIntegration {
                        LocalModelsSection(
                            ollamaService: viewModel.ollamaService,
                            ollamaBaseURL: ollamaIntegration.ollamaConfig?.baseURL ?? "",
                            sidebarWidth: $sidebarWidth
                        )
                    } else {
                        Text("Select an Ollama integration to view and manage local models.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .padding(.horizontal)
                .padding(.top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear {
            viewModel.ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Integrations Section
private struct LLMIntegrationsSection: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @State private var showingAddIntegrationPopover = false

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("LLM Integrations")
                    .font(.headline)
                Spacer()
                Button {
                    showingAddIntegrationPopover = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(PlainButtonStyle())
                .help("Add New LLM Integration")
                .popover(isPresented: $showingAddIntegrationPopover, arrowEdge: .bottom) {
                    AddLLMIntegrationView()
                         .environmentObject(llmIntegrationStore)
                }
            }
            .padding(.bottom, 5)

            LazyVStack(spacing: 8) {
                ForEach(llmIntegrationStore.integrations) { integration in
                    IntegrationRowView(integration: integration)
                }
            }
        }
    }
}

// MARK: - Integration Row (Card Style)
private struct IntegrationRowView: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    let integration: LLMIntegrationModel
    @State private var showingDeleteConfirmation = false

    var isActive: Bool {
        llmIntegrationStore.selectedIntegrationID == integration.id
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                .foregroundColor(isActive ? .blue : .secondary)
                .font(.title2)
                .frame(width: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.displayName)
                    .fontWeight(.semibold)
                Text(integration.providerType.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(NSColor.controlAlternatingRowBackgroundColors.first ?? .clear))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? .blue : Color.gray.opacity(0.2), lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                llmIntegrationStore.selectedIntegrationID = integration.id
            }
        }
        .contextMenu {
            Button("Set as Active") {
                llmIntegrationStore.selectedIntegrationID = integration.id
            }.disabled(isActive)

            Button("Delete Integration", role: .destructive) {
                showingDeleteConfirmation = true
            }.disabled(llmIntegrationStore.integrations.count <= 1)
        }
        .confirmationDialog("Delete '\(integration.displayName)'?",
                            isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete Integration", role: .destructive) {
                llmIntegrationStore.deleteIntegration(id: integration.id)
            }
        }
    }
}


// MARK: - Local Models Section
private struct LocalModelsSection: View {
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    @Binding var sidebarWidth: CGFloat
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Local LLMs for Active Profile")
                    .font(.headline)
                Spacer()
                OllamaStatusView(ollamaService: ollamaService)
            }
            .padding(.bottom, 5)
        }
    }
}

// MARK: - Local Model Card
private struct LocalModelCard: View {
    let modelName: String
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    
    @State private var showingRemovalConfirmation = false

    // --- FIXED: Access modelName from the nested ollamaConfig model ---
    var isSelectedForChat: Bool {
        viewModel.llmIntegrationStore.currentIntegration?.ollamaConfig?.modelName == modelName
    }

    var body: some View {
        Text("Card for \(modelName)")
    }
}

// MARK: - Ollama Status View
private struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService
    var body: some View { Text("Status") }
}
