//
//  GeneralSettingsView.swift
//  Devgentic
//
//  Created by Raj Singh on 17/05/25.
//  Updated to Modern UI layout matching Agent/Bot configurations.
//

import SwiftUI

/// A view for managing general application settings.
struct GeneralSettingsView: View {
    // Access the main view model from the environment to bind the setting.
    @EnvironmentObject var viewModel: MainApplicationViewModel
    @Environment(\.appTheme) private var theme

    // Speech settings stored via @AppStorage for direct UserDefaults binding
    @AppStorage(AppSettings.speechModelKey) private var selectedModel: String = "base.en"
    @AppStorage(AppSettings.speechLanguageKey) private var selectedLanguage: String = ""
    @AppStorage(AppSettings.speechAutoStopOnSilenceKey) private var autoStopOnSilence: Bool = true
    @AppStorage(AppSettings.agentViewVariantKey) private var agentViewVariant: AgentViewVariant = .dynamicIsland

    // Available Whisper models (shared catalog)
    private var availableModels: [WhisperModelInfo] { WhisperModelCatalog.availableModels }

    // Common languages (subset of WhisperKit's 99)
    private let availableLanguages: [(code: String, display: String)] = [
        ("", "Auto-detect"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("nl", "Dutch"),
        ("sv", "Swedish"),
        ("pl", "Polish"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
    ]

    private var isEnglishOnlyModel: Bool {
        selectedModel.hasSuffix(".en")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                
                // 1. Language Model Section
                SettingsCard(title: "Language Model", icon: "text.bubble.fill", theme: theme) {
                    SettingsRow(
                        title: "Stream LLM Responses",
                        description: "When enabled, the LLM response will appear word-by-word. Disable this if you prefer to receive the full response at once after it has been generated.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $viewModel.useStreamingResponse)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Divider().background(theme.dividerColor)

                    SettingsRow(
                        title: "Agent Execution View",
                        description: "Select how the agent's thought process and tool usage are displayed during execution.",
                        theme: theme
                    ) {
                        Picker("", selection: $agentViewVariant) {
                            ForEach(AgentViewVariant.allCases) { variant in
                                Text(variant.rawValue).tag(variant)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                // 2. Speech Recognition Section
                SettingsCard(title: "Speech Recognition", icon: "waveform", theme: theme) {
                    
                    // Model Picker
                    SettingsRow(
                        title: "Model",
                        description: "Larger models are more accurate but slower and use more memory. Multilingual models support 99 languages; English-only models (.en) are faster for English.",
                        theme: theme
                    ) {
                        Picker("", selection: $selectedModel) {
                            ForEach(availableModels) { model in
                                Text("\(model.displayName)  \(model.size)")
                                    .tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: selectedModel) { newModel in
                            NotificationCenter.default.post(
                                name: GlobalConstants.speechModelChangedNotification,
                                object: newModel
                            )
                            // Force English when switching to an English-only model
                            if newModel.hasSuffix(".en") && selectedLanguage != "en" && !selectedLanguage.isEmpty {
                                selectedLanguage = "en"
                            }
                        }
                    }

                    Divider().background(theme.dividerColor)

                    // Language Picker
                    SettingsRow(
                        title: "Language",
                        description: isEnglishOnlyModel ? "Language selection is disabled for English-only models. Choose a multilingual model to enable other languages." : "Select a specific language for better accuracy, or use Auto-detect. Auto-detect requires a multilingual model.",
                        isWarning: isEnglishOnlyModel,
                        theme: theme
                    ) {
                        Picker("", selection: $selectedLanguage) {
                            ForEach(availableLanguages, id: \.code) { lang in
                                Text(lang.display).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .disabled(isEnglishOnlyModel)
                        .fixedSize()
                        .onChange(of: selectedLanguage) { newLanguage in
                            NotificationCenter.default.post(
                                name: GlobalConstants.speechLanguageChangedNotification,
                                object: newLanguage
                            )
                        }
                    }

                    Divider().background(theme.dividerColor)

                    // VAD Auto-Stop Toggle
                    SettingsRow(
                        title: "Auto-stop on silence",
                        description: "When enabled, transcription will automatically finalize after detecting silence, allowing hands-free voice input.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $autoStopOnSilence)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                            .onChange(of: autoStopOnSilence) { newValue in
                                NotificationCenter.default.post(
                                    name: GlobalConstants.speechAutoStopChangedNotification,
                                    object: newValue
                                )
                            }
                    }
                }

                // 3. Intelligence Core Section
                SettingsCard(title: "Intelligence Core", icon: "cpu.fill", theme: theme) {
                    SettingsRow(
                        title: "Enable Intelligence Core",
                        description: "An isolated on-device MLX model used for background processing and intelligence tasks. Enabling this will download the model (~1.2GB) if not present.",
                        theme: theme
                    ) {
                        VStack(alignment: .trailing, spacing: 12) {
                            if viewModel.isIntelligenceCoreDownloading {
                                HStack(spacing: 8) {
                                    ProgressView(value: viewModel.intelligenceCoreDownloadProgress)
                                        .progressViewStyle(.linear)
                                        .frame(width: 100)
                                    Text("\(Int(viewModel.intelligenceCoreDownloadProgress * 100))%")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(theme.secondaryText)
                                }
                            }
                            
                            Toggle("", isOn: $viewModel.isIntelligenceCoreEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .tint(theme.accentColor)
                                .disabled(viewModel.isIntelligenceCoreDownloading)
                        }
                    }
                    
                    if let error = viewModel.intelligenceCoreError {
                        Divider().background(theme.dividerColor)
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(theme.warningColor)
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundColor(theme.warningColor)
                            Spacer()
                        }
                        .padding(16)
                    }
                }
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }
}

// MARK: - Reusable Modern UI Components

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let theme: any Theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accentColor)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(theme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.surfaceOverlayStrong, lineWidth: 1)
            )
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let description: String
    var isWarning: Bool = false
    let theme: any Theme
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.primaryText)
                
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(isWarning ? theme.warningColor : theme.secondaryText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer(minLength: 24)
            
            VStack {
                Spacer(minLength: 0)
                control
                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }
}
