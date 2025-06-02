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
            // The NavigationView will place the selected destination here.
            // If no selection, it might show a default view or the first item's view
            // depending on the OS version and exact NavigationView behavior.
            // We provide a placeholder for when selectedSectionForNavigation is nil.
            if selectedSectionForNavigation == nil {
                VStack {
                    Text("Select a category")
                        .font(.title)
                    Text("Choose a section from the sidebar to configure settings.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // This EmptyView acts as a placeholder for the NavigationLink's destination content.
                // The actual content is determined by detailView(for: selectedSectionForNavigation!)
                // when a selection is made.
                EmptyView()
            }
        }
        .onAppear {
            // Initialize local selection state from the viewModel on appear
            // This also helps in ensuring a detail view is loaded if one was previously selected.
            if selectedSectionForNavigation != viewModel.selectedSettingsSection {
                 selectedSectionForNavigation = viewModel.selectedSettingsSection
            }
            // If no section is selected in the view model, and none locally, select the first one.
            if selectedSectionForNavigation == nil {
                selectedSectionForNavigation = SettingsSection.allCases.first
            }
            logger.info("CommandCentreView appeared. Initial selected section for navigation: \(selectedSectionForNavigation?.rawValue ?? "nil")")
        }
        // Sync viewModel's selection when local navigation selection changes
        .onChange(of: selectedSectionForNavigation) { newValue in
            if let newSelectedSection = newValue {
                if viewModel.selectedSettingsSection != newSelectedSection {
                    viewModel.selectedSettingsSection = newSelectedSection
                    logger.debug("CommandCentre local selection changed to: \(newSelectedSection.rawValue), updating viewModel.")
                }
            }
        }
        // Sync local navigation selection if viewModel's selection changes from elsewhere
        .onChange(of: viewModel.selectedSettingsSection) { newViewModelSection in
            if selectedSectionForNavigation != newViewModelSection {
                selectedSectionForNavigation = newViewModelSection
                logger.debug("ViewModel selectedSettingsSection changed to: \(newViewModelSection.rawValue), updating CommandCentre local selection.")
            }
        }
    }

    // Helper to provide the correct detail view based on selection
    @ViewBuilder
    private func detailView(for section: SettingsSection) -> some View {
        // Wrap the entire content of the detail section in a ScrollView
        // This ensures that if the content of any settings page is too tall,
        // it becomes scrollable without distorting the NavigationView's layout.
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                switch section {
                case .general:
                    GeneralSettingsView(windowOpacity: $viewModel.windowOpacity)
                        .environmentObject(viewModel)
                // MARK: - Removed .localAI case as per enhancement plan
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
                // Removed Spacer from here; ScrollView content will align top by default.
                // If VStack content is shorter than ScrollView, it will stay at the top.
            }
            .padding(20) // Apply padding to the content within the ScrollView
            .frame(maxWidth: .infinity, alignment: .topLeading) // VStack takes full width; height is intrinsic to content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity) // ScrollView itself fills the available detail area
    }
}

// Preview Provider for CommandCentreView
struct CommandCentreView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock OllamaService instances for previews
        let mockOllamaService: OllamaService = {
            let service = OllamaService()
            service.localModels = ["llama3:8b", "mistral:7b", "gemma:2b"]
            service.llmModelName = "mistral:7b"
            service.serverStatus = .connected
            return service
        }()

        // Create a mock OllamaProfileStore for previews
        let mockOllamaProfileStore: OllamaProfileStore = {
            let store = OllamaProfileStore()
            store.profiles = [OllamaProfile.defaultProfile()]
            store.selectedProfileID = store.profiles.first?.id
            return store
        }()

        let mockViewModel = MainApplicationViewModel(
            ollamaService: mockOllamaService,
            ollamaProfileStore: mockOllamaProfileStore
        )

        CommandCentreView()
            .environmentObject(mockViewModel)
            .frame(width: 800, height: 500)
            .previewDisplayName("Command Centre Preview")
    }
}
