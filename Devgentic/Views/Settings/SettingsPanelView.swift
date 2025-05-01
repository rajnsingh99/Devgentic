// Views/Settings/SettingsPanelView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "SettingsPanelView")

struct SettingsPanelView: View {
    // Now observing the ViewModel to pass it down to detail views
    @ObservedObject var viewModel: MainApplicationViewModel // <--- ADD THIS

    // State and Bindings passed down (some might become observed properties from ViewModel)
    @Binding var showSettings: Bool // To allow closing the panel
    // @Binding var selectedSettingsSection: SettingsSection // This is now in the ViewModel

    // Bindings for the actual settings values needed by detail views
    // These might also become direct references to viewModel properties
    // @Binding var windowOpacity: Double // This is now in the ViewModel
    // @Binding var llmModelName: String // This is now in the ViewModel
    // @Binding var agentBaseURL: String // This is now in the ViewModel
    // @Binding var agentDelegationStrategy: String // This is now in the ViewModel

    // Action passed up (if needed, e.g., for a global reset button)
    // let onResetSettings: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Background layer to dim and catch taps outside the panel
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    closeSettings() // Close when tapping outside
                }

            // The Settings Panel itself
            HStack(alignment: .top, spacing: 0) {
                // --- Master View (Settings Sidebar) ---
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(SettingsSection.allCases) { section in
                        HStack {
                            Image(systemName: section.iconName)
                                .frame(width: 20, alignment: .center) // Ensure icon alignment
                            Text(section.rawValue)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        // Use viewModel.selectedSettingsSection for highlighting
                        .background(viewModel.selectedSettingsSection == section ? Color.white.opacity(0.2) : Color.clear)
                        .foregroundColor(viewModel.selectedSettingsSection == section ? .white : .white.opacity(0.7))
                        .cornerRadius(6)
                        .contentShape(Rectangle()) // Make entire row tappable
                        .onTapGesture {
                            // Update the ViewModel's selected section
                            viewModel.selectedSettingsSection = section
                        }
                    }
                    Spacer() // Pushes sections to the top
                }
                .padding(10)
                .frame(width: 250) // Fixed width for sidebar
                .background(Color.black.opacity(0.2)) // Sidebar background

                Divider().background(Color.white.opacity(0.2)) // Vertical divider

                // --- Detail View ---
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        // Dynamically display the correct settings view based on selection
                        switch viewModel.selectedSettingsSection { // Use viewModel's selected section
                        case .general:
                            // Pass the relevant binding from the ViewModel
                            GeneralSettingsView(windowOpacity: $viewModel.windowOpacity)
                        case .localAI:
                            // Pass the ViewModel instance
                            LocalAISettingsView(viewModel: viewModel) // <--- PASS VIEWMODEL HERE
                        case .agents:
                            // Pass the relevant bindings from the ViewModel
                            AgentSettingsView(agentBaseURL: $viewModel.agentBaseURL, agentDelegationStrategy: $viewModel.agentDelegationStrategy)
                        case .license:
                            // This view currently doesn't need bindings or ViewModel
                            LicenseSettingsView()
                        }
                        Spacer() // Pushes content to the top if less than scroll view height
                    }
                    .padding(20) // Padding inside the detail area
                }
                .frame(maxWidth: .infinity) // Allow detail view to expand

            } // End Settings HStack
            .background(
                // Use VisualEffectBlur for the main panel background
                 VisualEffectBlur().edgesIgnoringSafeArea(.all)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12)) // Rounded corners for the panel
            .shadow(radius: 10) // Add shadow for depth
            // REMOVE THE FIXED FRAME was here
            .padding(20) // Add padding around the settings content

            // --- Close Button Overlay ---
            .overlay(alignment: .topTrailing) {
                Button(action: closeSettings) { // Use the close action
                    Image(systemName: "xmark.circle.fill")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.gray.opacity(0.8))
                        .padding(5) // Add padding inside the button's hit area
                }
                .buttonStyle(PlainButtonStyle())
                .padding(5) // Add padding outside the button
            }
            // --- End Close Button Overlay ---

        } // End ZStack
        .transition(.scale.combined(with: .opacity)) // Animation for appearing/disappearing
    }

    // Helper function to close settings with animation
    private func closeSettings() {
        withAnimation {
            showSettings = false
        }
    }
}

// Update the Preview Provider for SettingsPanelView to pass a mock ViewModel
struct SettingsPanelView_Previews: PreviewProvider {
    @StateObject static var viewModel = MainApplicationViewModel() // Create a mock ViewModel

    static var previews: some View {
        SettingsPanelView(
            viewModel: viewModel, // Pass the mock ViewModel
            showSettings: .constant(true) // Keep open for preview
            // Bindings like selectedSettingsSection, windowOpacity, etc.
            // are now managed by the ViewModel and accessed directly
            // in the view, so you don't pass them as separate bindings here.
        )
        .previewDisplayName("Settings Panel Preview")
    }
}
