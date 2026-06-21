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
    @Environment(MainApplicationViewModel.self) var viewModel
    @Environment(\.appTheme) private var theme

    // Speech settings stored via @AppStorage for direct UserDefaults binding
    @AppStorage(AppSettings.speechModelKey) private var selectedModel: String = "base.en"
    @AppStorage(AppSettings.speechLanguageKey) private var selectedLanguage: String = ""
    @AppStorage(AppSettings.speechAutoStopOnSilenceKey) private var autoStopOnSilence: Bool = true
    @AppStorage(AppSettings.developerModeKey) private var developerMode: Bool = false
    @AppStorage(AppSettings.diagnosticsEnabledKey) private var diagnosticsEnabled: Bool = true
    @AppStorage(AppSettings.agentViewVariantKey) private var agentViewVariant: AgentViewVariant = .dynamicIsland

    // Download/delete confirmation state
    enum SettingsWhisperAlert { case download, delete }
    @State private var activeAlert: SettingsWhisperAlert?
    @State private var showWhisperAlert = false
    @State private var pendingModelId: String?
    /// Tracks the last valid (downloaded) model so the picker can revert on cancel.
    /// Initialized from @AppStorage on first appear (#14).
    @State private var previousModelId: String?

    /// Human-readable footprint of the local trace database, loaded lazily on appear.
    @State private var diagnosticsStorageText: String = "—"

    /// Presents the read-only diagnostic-bundle viewer (maintainer tool).
    @State private var showBundleViewer = false

    // Available Whisper models (shared catalog)
    private var availableModels: [WhisperModelInfo] { WhisperModelCatalog.availableModels }
    private var downloadService: WhisperModelDownloadService { .shared }

    // Common languages (subset of WhisperKit's 99)
    private let availableLanguages: [(code: String, display: String)] = [
        ("", String(localized: "Auto-detect")),
        ("en", String(localized: "English")),
        ("es", String(localized: "Spanish")),
        ("fr", String(localized: "French")),
        ("de", String(localized: "German")),
        ("it", String(localized: "Italian")),
        ("pt", String(localized: "Portuguese")),
        ("ru", String(localized: "Russian")),
        ("ja", String(localized: "Japanese")),
        ("ko", String(localized: "Korean")),
        ("zh", String(localized: "Chinese")),
        ("ar", String(localized: "Arabic")),
        ("hi", String(localized: "Hindi")),
        ("nl", String(localized: "Dutch")),
        ("sv", String(localized: "Swedish")),
        ("pl", String(localized: "Polish")),
        ("tr", String(localized: "Turkish")),
        ("uk", String(localized: "Ukrainian")),
    ]

    private var isEnglishOnlyModel: Bool {
        selectedModel.hasSuffix(".en")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                
                // 1. Developer Mode Section
                SettingsCard(title: "Developer", icon: "hammer.fill", theme: theme) {
                    SettingsRow(
                        title: "Developer Mode",
                        description: "When enabled, the Report button on messages opens a detailed execution trace inspector with span trees, event timelines, and JSON export. When disabled, a simplified feedback view is shown instead.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $developerMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Divider().background(theme.dividerColor)

                    SettingsRow(
                        title: "Store Diagnostic Traces",
                        description: "Records sanitized error and warning diagnostics — logs, error analytics, and crash reports — so problem reports contain enough detail to fix issues. Nothing leaves your Mac unless you export a report. Basic execution traces are always stored locally and purged after 30 days.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $diagnosticsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Divider().background(theme.dividerColor)

                    SettingsRow(
                        title: "Diagnostics Storage",
                        description: "On-disk size of the local trace database (traces, spans, and events powering the Report inspector and problem reports). Entries older than 30 days are purged automatically at launch.",
                        theme: theme
                    ) {
                        Text(diagnosticsStorageText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Divider().background(theme.dividerColor)

                    SettingsRow(
                        title: "Open Diagnostic Bundle…",
                        description: "Inspect a diagnostic bundle (.zip) exported from another Devgentic install — view its trace, spans, and events. Read-only.",
                        theme: theme
                    ) {
                        Button("Open…") { showBundleViewer = true }
                    }
                }
                .task {
                    guard let store = TraceStore.shared else {
                        diagnosticsStorageText = "Unavailable"
                        return
                    }
                    let bytes = store.databaseFileSizeBytes()
                    let count = (try? store.traceCount()) ?? 0
                    diagnosticsStorageText = "\(count) traces · " +
                        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                }
                .sheet(isPresented: $showBundleViewer) { BundleViewerView() }

                // 2. Language Model Section
                SettingsCard(title: "Language Model", icon: "text.bubble.fill", theme: theme) {
                    SettingsRow(
                        title: "Stream LLM Responses",
                        description: "When enabled, the LLM response will appear word-by-word. Disable this if you prefer to receive the full response at once after it has been generated.",
                        theme: theme
                    ) {
                        Toggle("", isOn: Bindable(viewModel).useStreamingResponse)
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
                        HStack(spacing: 8) {
                            Picker("", selection: $selectedModel) {
                                ForEach(availableModels) { model in
                                    HStack(spacing: 4) {
                                        Text("\(model.displayName)  \(model.size)")
                                        if downloadService.downloadedModelIds.contains(model.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .imageScale(.small)
                                        }
                                    }
                                    .tag(model.id)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onAppear { if previousModelId == nil { previousModelId = selectedModel } }
                            .onChange(of: selectedModel) { _, newModel in
                                if downloadService.isModelDownloaded(newModel) {
                                    previousModelId = newModel
                                    NotificationCenter.default.post(
                                        name: GlobalConstants.speechModelChangedNotification,
                                        object: newModel
                                    )
                                } else {
                                    pendingModelId = newModel
                                    selectedModel = previousModelId ?? "base.en"
                                    activeAlert = .download
                                    showWhisperAlert = true
                                }
                                if newModel.hasSuffix(".en") && selectedLanguage != "en" && !selectedLanguage.isEmpty {
                                    selectedLanguage = "en"
                                }
                            }

                            // Shared status chip — shows Installed / Downloading /
                            // Download state for the currently-selected model.
                            // Deletion routes through the existing alert; the
                            // download alert is handled via Picker onChange above.
                            ModelDownloadStatusView(
                                backend: .whisper,
                                modelIdentifier: selectedModel,
                                displayName: selectedModel,
                                isInstalled: downloadService.isModelDownloaded(selectedModel),
                                onDeleteRequested: {
                                    pendingModelId = selectedModel
                                    activeAlert = .delete
                                    showWhisperAlert = true
                                }
                            )
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
                        .onChange(of: selectedLanguage) { _, newLanguage in
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
                            .onChange(of: autoStopOnSilence) { _, newValue in
                                NotificationCenter.default.post(
                                    name: GlobalConstants.speechAutoStopChangedNotification,
                                    object: newValue
                                )
                            }
                    }

                    // Progress UI intentionally omitted — `ModelDownloadStatusView`
                    // above renders inline progress for the selected model,
                    // and the Downloads sidebar surfaces background pulls.
                }
                .alert(settingsAlertTitle, isPresented: $showWhisperAlert) {
                    if activeAlert == .delete {
                        Button("Delete", role: .destructive) { performSettingsAlertAction() }
                    } else {
                        Button("Download") { performSettingsAlertAction() }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingModelId = nil
                        activeAlert = nil
                    }
                } message: {
                    Text(settingsAlertMessage)
                }

                // 3. Intelligence Core — Moved to dedicated settings section
                // Navigate to Settings > Core Intelligence for full configuration.
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(theme.primaryBackground)
    }

    // MARK: - Settings Alert Helpers

    private var settingsAlertTitle: String {
        switch activeAlert {
        case .download: return "Download Required"
        case .delete: return "Delete Model"
        case .none: return ""
        }
    }

    private var settingsAlertMessage: String {
        switch activeAlert {
        case .download:
            if let modelId = pendingModelId,
               let model = availableModels.first(where: { $0.id == modelId }) {
                return "The \(model.displayName) model (\(model.size)) needs to be downloaded before use."
            }
            return "This model needs to be downloaded before use."
        case .delete:
            if let modelId = pendingModelId,
               let model = availableModels.first(where: { $0.id == modelId }) {
                return "Delete the \(model.displayName) model? It will need to be re-downloaded to use again."
            }
            return "Delete this model? It will need to be re-downloaded to use again."
        case .none:
            return ""
        }
    }

    private func performSettingsAlertAction() {
        guard let modelId = pendingModelId else { return }
        pendingModelId = nil

        switch activeAlert {
        case .download:
            // Route through DownloadCoordinator so the history store gets
            // the record + short-circuit semantics match every other entry
            // point (hover button, sidebar re-download, etc.).
            Task { @MainActor in
                _ = await DownloadCoordinator.startWhisperDownloadIfNeeded(modelId: modelId)
            }
        case .delete:
            Task {
                let fallback = await downloadService.deleteModel(modelId)
                if let fallback {
                    selectedModel = fallback
                    previousModelId = fallback
                    NotificationCenter.default.post(
                        name: GlobalConstants.speechModelChangedNotification,
                        object: fallback
                    )
                } else {
                    // Fix #6: No models remain — service will go idle via notification.
                    // Keep picker on whatever is stored; user must download to use voice.
                    NotificationCenter.default.post(
                        name: GlobalConstants.speechModelChangedNotification,
                        object: selectedModel
                    )
                }
            }
        case .none:
            break
        }
        activeAlert = nil
    }
}

// MARK: - Reusable Modern UI Components

struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    let theme: any Theme
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                Text(title)
                    .font(.system(.caption, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
                    .textCase(.uppercase)
            }

            VStack(spacing: 0) {
                content
                    .padding(16)
            }
            .background(theme.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var isWarning: Bool = false
    let theme: any Theme
    @ScaledMetric private var rowPadding: CGFloat = 16
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(theme.fontBody.weight(.medium))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(.system(.caption))
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
        .padding(rowPadding)
    }
}
