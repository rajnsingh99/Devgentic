//
//  CommandCentreView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI
import os

// Logger (Optional)
private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CommandCentreView")

struct CommandCentreView: View {
    // Access to the shared ViewModel.
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.openWindow) var openWindow // To open the new Ollama Profiles window
    
    // Local optional state for NavigationLink selection, to match its expected binding type.
    @State private var selectedSectionForNavigation: SettingsSection?

    var body: some View {
        NavigationView {
            // --- Master View (Settings Sidebar) ---
            List {
                ForEach(SettingsSection.allCases) { section in
                    NavigationLink(
                        destination: detailView(for: section)
                            .navigationTitle(section.rawValue), // Set title for the detail view
                        tag: section,
                        selection: $selectedSectionForNavigation
                    ) {
                        HStack {
                            Image(systemName: section.iconName)
                                .frame(width: 20, alignment: .center)
                            Text(section.rawValue)
                        }
                    }
                }
            }
            .listStyle(SidebarListStyle())
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 250) // Keep sidebar width constrained

            // --- Detail View Area ---
            VStack {
                if selectedSectionForNavigation == nil {
                    Text("Select a category")
                        .font(.title)
                    Text("Choose a section from the sidebar to configure settings.")
                        .foregroundColor(.secondary)
                } else {
                    // This EmptyView acts as a placeholder for the NavigationLink's destination content.
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selectedSectionForNavigation != viewModel.selectedSettingsSection {
                 selectedSectionForNavigation = viewModel.selectedSettingsSection
            }
            if selectedSectionForNavigation == nil {
                selectedSectionForNavigation = SettingsSection.allCases.first
            }
            logger.info("CommandCentreView appeared. Initial selected section: \(selectedSectionForNavigation?.rawValue ?? "nil")")
        }
        .onChange(of: selectedSectionForNavigation) { newValue in
            if let newSelectedSection = newValue, viewModel.selectedSettingsSection != newSelectedSection {
                viewModel.selectedSettingsSection = newSelectedSection
            }
        }
        .onChange(of: viewModel.selectedSettingsSection) { newViewModelSection in
            if selectedSectionForNavigation != newViewModelSection {
                selectedSectionForNavigation = newViewModelSection
            }
        }
    }

    // Helper to provide the correct detail view based on selection
    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                switch section {
                case .general:
                    GeneralSettingsView(windowOpacity: $viewModel.windowOpacity)
                        .environmentObject(viewModel)
                case .agents:
                    AgentSettingsView(
                        agentBaseURL: $viewModel.agentBaseURL,
                        agentDelegationStrategy: $viewModel.agentDelegationStrategy
                    )
                    .environmentObject(viewModel)
                case .license:
                    LicenseSettingsView()
                        .environmentObject(viewModel)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview Provider (Corrected)
struct CommandCentreView_Previews: PreviewProvider {
    static var previews: some View {
        // Create a mock OllamaProfileStore for previews
        let mockOllamaProfileStore: OllamaProfileStore = {
            let store = OllamaProfileStore()
            store.profiles = [OllamaProfile.defaultProfile()]
            store.selectedProfileID = store.profiles.first?.id
            return store
        }()

        // MARK: - Corrected: Initialize the view model without the OllamaService argument
        let mockViewModel = MainApplicationViewModel(
            ollamaProfileStore: mockOllamaProfileStore
        )

        CommandCentreView()
            .environmentObject(mockViewModel)
            .frame(width: 800, height: 500)
            .previewDisplayName("Command Centre Preview")
            .onAppear {
                // MARK: - Corrected: Configure the SHARED OllamaService instance for this preview
                let service = OllamaService.shared
                service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
                service.llmModelName = "mistral:7b"
                service.serverStatus = .connected
            }
    }
}
