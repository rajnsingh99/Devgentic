// Views/Settings/SettingsPanelView.swift
import SwiftUI
import os

// Logger (Optional)
// private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "SettingsPanelView")

struct SettingsPanelView: View {
    // Observe MainApplicationViewModel to access its properties and its OllamaService instance
    @ObservedObject var viewModel: MainApplicationViewModel

    @Binding var showSettings: Bool // To allow closing the panel

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    closeSettings()
                }

            HStack(alignment: .top, spacing: 0) {
                // --- Master View (Settings Sidebar) ---
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(SettingsSection.allCases) { section in
                        HStack {
                            Image(systemName: section.iconName)
                                .frame(width: 20, alignment: .center)
                            Text(section.rawValue)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(viewModel.selectedSettingsSection == section ? Color.white.opacity(0.2) : Color.clear)
                        .foregroundColor(viewModel.selectedSettingsSection == section ? .white : .white.opacity(0.7))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedSettingsSection = section
                        }
                    }
                    Spacer()
                }
                .padding(10)
                .frame(width: 250)
                .background(Color.black.opacity(0.2))

                Divider().background(Color.white.opacity(0.2))

                // --- Detail View ---
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        switch viewModel.selectedSettingsSection {
                        case .general:
                            // Bind directly to @AppStorage property in viewModel
                            GeneralSettingsView(windowOpacity: $viewModel.windowOpacity)
                        case .localAI:
                            // Pass the OllamaService instance from viewModel and viewModel itself
                            LocalAISettingsView(
                                ollamaService: viewModel.ollamaService,
                                mainViewModel: viewModel
                            )
                        case .agents:
                            // Bind directly to @AppStorage properties in viewModel
                            AgentSettingsView(
                                agentBaseURL: $viewModel.agentBaseURL,
                                agentDelegationStrategy: $viewModel.agentDelegationStrategy
                            )
                        case .license:
                            LicenseSettingsView()
                        }
                        Spacer()
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity)

            }
            .background(VisualEffectBlur().edgesIgnoringSafeArea(.all))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 10)
            .padding(20)

            .overlay(alignment: .topTrailing) {
                Button(action: closeSettings) {
                    Image(systemName: "xmark.circle.fill")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.gray.opacity(0.8))
                        .padding(5)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(5)
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func closeSettings() {
        withAnimation {
            showSettings = false
        }
    }
}

// Update the Preview Provider for SettingsPanelView
struct SettingsPanelView_Previews: PreviewProvider {
    // Create a mock MainApplicationViewModel for the preview.
    // Its convenience init() will create a default OllamaService.
    @StateObject static var mockViewModel = MainApplicationViewModel()

    static var previews: some View {
        // Simulate one of the sections being active for preview if desired
        // mockViewModel.selectedSettingsSection = .localAI

        SettingsPanelView(
            viewModel: mockViewModel,
            showSettings: .constant(true)
        )
        .onAppear {
            // Configure mockViewModel or its ollamaService for specific preview states if needed
            // For example, to show some models in LocalAISettingsView preview:
            if mockViewModel.selectedSettingsSection == .localAI {
                mockViewModel.ollamaService.localModels = ["preview-model-1", "preview-model-2"]
                mockViewModel.ollamaService.serverStatus = .connected
                // Note: llmModelName is @AppStorage in OllamaService, so direct assignment here
                // might not reflect in previews unless the service itself is modified for preview.
                // For robust previews of @AppStorage, it's often easier to set defaults
                // or use a separate preview-specific service instance.
            }
        }
        .previewDisplayName("Settings Panel Preview")
    }
}
