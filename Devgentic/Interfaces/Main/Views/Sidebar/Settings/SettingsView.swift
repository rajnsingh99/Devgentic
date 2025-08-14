//
//  SettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//

import SwiftUI

/// Enum to represent the different settings categories for easier navigation and management.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "General"
    case ollama = "Ollama"
    case theme = "Theme"
    case about = "About"

    var id: String { self.rawValue }

    /// Returns the appropriate icon for each settings category.
    var iconName: String {
        switch self {
        case .general:
            return "gear"
        case .ollama:
            return "cpu"
        case .theme:
            return "paintbrush"
        case .about:
            return "info.circle"
        }
    }
    
    /// Provides the destination view for each category.
    @ViewBuilder
    var destination: some View {
        switch self {
        case .general:
            // Use the new dedicated view for general settings
            GeneralSettingsView()
        case .ollama:
            // Use the new dedicated view for Ollama settings
            OllamaSettingsView()
        case .theme:
            Text("Theme Settings")
                .font(.title2)
                .foregroundColor(.secondary)
        case .about:
            Text("About Devgentic")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }
}

/// A view that provides a dedicated settings window, replacing the old command-centre.
struct SettingsView: View {
    @State private var selectedCategory: SettingsCategory? = .general
    
    // Fetch the MainApplicationViewModel from the environment.
    // This view now requires it to be in its environment, which is appropriate
    // since its child views (like GeneralSettingsView) depend on it.
    @EnvironmentObject var mainApplicationViewModel: MainApplicationViewModel

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                NavigationLink(value: category) {
                    Label(category.rawValue, systemImage: category.iconName)
                }
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            // Display the destination view for the selected category
            if let category = selectedCategory {
                // Explicitly pass the environment object to the destination view.
                // This ensures that any view created by `destination` has access to it.
                category.destination
                    .environmentObject(mainApplicationViewModel)
            } else {
                Text("Select a category")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 700, minHeight: 550)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        // The preview provider already provides the necessary environment object.
        // Now that SettingsView explicitly uses it, this setup is correct and complete.
        SettingsView()
            .environmentObject(MainApplicationViewModel())
    }
}
