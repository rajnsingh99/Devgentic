// Views/SettingsPanelView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.AgenticDev", category: "SettingsPanelView")

struct SettingsPanelView: View {
    // State and Bindings passed down
    @Binding var showSettings: Bool // To allow closing the panel
    @Binding var selectedSettingsSection: SettingsSection // To manage selection

    // Bindings for the actual settings values needed by detail views
    @Binding var windowOpacity: Double
    @Binding var llmModelName: String
    @Binding var agentBaseURL: String
    @Binding var agentDelegationStrategy: String

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
                        .background(selectedSettingsSection == section ? Color.white.opacity(0.2) : Color.clear)
                        .foregroundColor(selectedSettingsSection == section ? .white : .white.opacity(0.7))
                        .cornerRadius(6)
                        .contentShape(Rectangle()) // Make entire row tappable
                        .onTapGesture {
                            selectedSettingsSection = section // Update selection
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
                        switch selectedSettingsSection {
                        case .general:
                            // Pass the relevant binding
                            GeneralSettingsView(windowOpacity: $windowOpacity)
                        case .localAI:
                            // Pass the relevant binding
                            LocalAISettingsView(llmModelName: $llmModelName)
                        case .agents:
                            // Pass the relevant bindings
                            AgentSettingsView(agentBaseURL: $agentBaseURL, agentDelegationStrategy: $agentDelegationStrategy)
                        case .license:
                            // This view currently doesn't need bindings
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
                // Or a solid color alternative:
                // Color.black.opacity(0.6).edgesIgnoringSafeArea(.all)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12)) // Rounded corners for the panel
            .shadow(radius: 10) // Add shadow for depth
            .frame(width: 1000, height: 650) // Fixed size for the centered panel

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

// Preview Provider
struct SettingsPanelView_Previews: PreviewProvider {
    @State static var show = true
    @State static var section: SettingsSection = .general
    @State static var opacity = 0.8
    @State static var model = "gemma:2b-preview"
    @State static var url = "http://localhost:8001"
    @State static var strategy = "auto"

    static var previews: some View {
        SettingsPanelView(
            showSettings: $show,
            selectedSettingsSection: $section,
            windowOpacity: $opacity,
            llmModelName: $model,
            agentBaseURL: $url,
            agentDelegationStrategy: $strategy
        )
        .previewDisplayName("General Selected")

        // Preview with a different section selected
        SettingsPanelView(
            showSettings: .constant(true), // Keep open for preview
            selectedSettingsSection: .constant(.agents), // Start on Agents section
            windowOpacity: $opacity,
            llmModelName: $model,
            agentBaseURL: $url,
            agentDelegationStrategy: $strategy
        )
        .previewDisplayName("Agents Selected")
    }
}
