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

    // Speech settings stored via @AppStorage for direct UserDefaults binding
    @AppStorage(AppSettings.speechModelKey) private var selectedModel: String = "base.en"
    @AppStorage(AppSettings.speechLanguageKey) private var selectedLanguage: String = ""
    @AppStorage(AppSettings.speechAutoStopOnSilenceKey) private var autoStopOnSilence: Bool = true

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
            VStack(spacing: 24) {
                
                // 1. Language Model Section
                ModernSection(title: "Language Model", icon: "text.bubble.fill") {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stream LLM Responses")
                                .fontWeight(.medium)
                            
                            Text("When enabled, the LLM response will appear word-by-word. Disable this if you prefer to receive the full response at once after it has been generated.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        Spacer(minLength: 16)
                        
                        Toggle("", isOn: $viewModel.useStreamingResponse)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                // 2. Speech Recognition Section
                ModernSection(title: "Speech Recognition", icon: "waveform") {
                    VStack(alignment: .leading, spacing: 16) {
                        
                        // Model Picker
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Model")
                                    .fontWeight(.medium)
                                
                                Text("Larger models are more accurate but slower and use more memory. Multilingual models support 99 languages; English-only models (.en) are faster for English.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                            Spacer(minLength: 16)
                            
                            Picker("", selection: $selectedModel) {
                                ForEach(availableModels) { model in
                                    Text("\(model.displayName)  \(model.size)")
                                        .tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize() // Let it size naturally to fit its content
                        }
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

                        Divider()

                        // Language Picker
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Language")
                                    .fontWeight(.medium)
                                
                                if isEnglishOnlyModel {
                                    Text("Language selection is disabled for English-only models. Choose a multilingual model to enable other languages.")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Select a specific language for better accuracy, or use Auto-detect. Auto-detect requires a multilingual model.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            
                            Spacer(minLength: 16)
                            
                            Picker("", selection: $selectedLanguage) {
                                ForEach(availableLanguages, id: \.code) { lang in
                                    Text(lang.display).tag(lang.code)
                                }
                            }
                            .labelsHidden()
                            .disabled(isEnglishOnlyModel)
                            .fixedSize() // Let it size naturally to fit its content
                        }
                        .onChange(of: selectedLanguage) { newLanguage in
                            NotificationCenter.default.post(
                                name: GlobalConstants.speechLanguageChangedNotification,
                                object: newLanguage
                            )
                        }

                        Divider()

                        // VAD Auto-Stop Toggle
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Auto-stop on silence")
                                    .fontWeight(.medium)
                                
                                Text("When enabled, transcription will automatically finalize after detecting silence, allowing hands-free voice input.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                            Spacer(minLength: 16)
                            
                            Toggle("", isOn: $autoStopOnSilence)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .onChange(of: autoStopOnSilence) { newValue in
                                    NotificationCenter.default.post(
                                        name: GlobalConstants.speechAutoStopChangedNotification,
                                        object: newValue
                                    )
                                }
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
