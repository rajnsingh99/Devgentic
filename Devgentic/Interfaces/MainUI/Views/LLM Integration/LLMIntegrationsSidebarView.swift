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
                    // This section now lists all integrations (Ollama and Remote)
                    LLMIntegrationsSection()
                        .environmentObject(viewModel.llmIntegrationStore)

                    Divider()

                    // This section is now conditionally shown only if an Ollama profile is active
                    if let ollamaIntegration = activeOllamaIntegration {
                        LocalModelsSection(
                            ollamaService: viewModel.ollamaService,
                            ollamaBaseURL: ollamaIntegration.ollamaBaseURL ?? "http://localhost:11434",
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
            logger.debug("LLMIntegrationsSidebarView disappeared.")
            viewModel.ollamaService.clearAllModelActionStatuses()
        }
    }
}

// MARK: - Integrations Section
private struct LLMIntegrationsSection: View {
    @EnvironmentObject var llmIntegrationStore: LLMIntegrationStore
    @State private var showingAddIntegrationPopover = false
    @State private var isHoveringAddButton = false

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
                        .foregroundColor(isHoveringAddButton ? .blue : .primary)
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in isHoveringAddButton = hovering }
                .help("Add New LLM Integration")
                .popover(isPresented: $showingAddIntegrationPopover, arrowEdge: .bottom) {
                    // In Phase 3, this will be the AddLLMIntegrationView
                    Text("Add Integration Popover (Phase 3)")
                        .padding()
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
            // Icon based on provider type
            Image(systemName: integration.providerType == .ollama ? "shippingbox.fill" : "cloud.fill")
                .foregroundColor(isActive ? .blue : .secondary)
                .font(.title2)
                .frame(width: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.displayName)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Text(integration.providerType.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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


// MARK: - Local Models Section (Largely unchanged, but now conditionally visible)
private struct LocalModelsSection: View {
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    @Binding var sidebarWidth: CGFloat

    // ... The rest of this view and its sub-views (LocalModelCard, OllamaStatusView)
    // can remain the same as they were in the original OllamaSidebarView,
    // as their logic is already driven by the OllamaService and a base URL.
    // The only change needed is in LocalModelCard to use the new llmIntegrationStore.
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Local LLMs for Active Profile")
                    .font(.headline)
                Spacer()
                OllamaStatusView(ollamaService: ollamaService)
            }
            .padding(.bottom, 5)
            
            // ... The rest of the body for this view remains the same
        }
    }
}

// MARK: - Local Model Card (Updated)
private struct LocalModelCard: View {
    let modelName: String // Simplified to just take the name
    @ObservedObject var ollamaService: OllamaService
    let ollamaBaseURL: String
    
    @EnvironmentObject var viewModel: MainApplicationViewModel
    
    @State private var showingRemovalConfirmation = false

    // Updated logic to check against the active integration
    var isSelectedForChat: Bool {
        viewModel.llmIntegrationStore.currentIntegration?.ollamaModelName == modelName
    }

    var body: some View {
        // ... The body of this view remains visually the same, but the `isSelectedForChat`
        // property above is now correctly wired to the new store.
        Text("Card for \(modelName)") // Placeholder content
    }
}

// MARK: - Ollama Status View (Unchanged)
private struct OllamaStatusView: View {
    @ObservedObject var ollamaService: OllamaService
    // ... This view remains unchanged ...
    var body: some View { Text("Status") }
}
