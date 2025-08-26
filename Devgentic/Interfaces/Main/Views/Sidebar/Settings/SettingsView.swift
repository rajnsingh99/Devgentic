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
            OllamaSettingsView_old()
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
            if let category = selectedCategory {
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

