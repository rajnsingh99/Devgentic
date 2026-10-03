// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
    @AppStorage(AppSettings.showTimelineThoughtsKey) private var showTimelineThoughts: Bool = false
    @AppStorage(AppSettings.showRemoteModelsKey) private var showRemoteModels: Bool = false
    @AppStorage(GlobalConstants.isOnboardingComplete) private var isOnboardingComplete: Bool = true
    @ObservedObject private var softwareUpdater = SoftwareUpdater.shared

    // Download/delete confirmation state
    enum SettingsWhisperAlert { case download, delete }
    @State private var activeAlert: SettingsWhisperAlert?
    @State private var showWhisperAlert = false
    @State private var pendingModelId: String?

    /// Human-readable footprint of the local trace database, loaded lazily on appear.
    @State private var diagnosticsStorageText: String = "—"

    /// Presents the read-only diagnostic-bundle viewer (maintainer tool).
    @State private var showBundleViewer = false

    /// The picker's tag for "no usable model".
    private static let noModelTag = ""

    /// The picker shows the stored model only when it is ON DISK; otherwise "No model".
    ///
    /// ⚠️ The stored key defaults to "base.en" and outlives its files, so binding the picker to it
    /// directly presented an undownloaded model as the active one. Picking an undownloaded model
    /// asks to download it and leaves the stored choice untouched — the getter keeps showing the
    /// current state, so there is nothing to revert on Cancel.
    private var modelPickerSelection: Binding<String> {
        Binding(
            get: { downloadService.isModelDownloaded(selectedModel) ? selectedModel : Self.noModelTag },
            set: { newModel in
                guard newModel != Self.noModelTag else { return }
                if downloadService.isModelDownloaded(newModel) {
                    selectedModel = newModel
                    NotificationCenter.default.post(
                        name: GlobalConstants.speechModelChangedNotification,
                        object: newModel
                    )
                } else {
                    pendingModelId = newModel
                    activeAlert = .download
                    showWhisperAlert = true
                }
            }
        )
    }

    /// The model the status chip describes: a running download, else the selection if usable.
    private var statusChipModelId: String? {
        if let downloading = downloadService.downloadingModelId { return downloading }
        return downloadService.isModelDownloaded(selectedModel) ? selectedModel : nil
    }

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
            VStack(spacing: 24) {

                // 1. Speech Recognition Section
                SettingsCard(title: "Speech Recognition", icon: "waveform", theme: theme) {

                    // Model Picker
                    SettingsRow(
                        title: "Model",
                        description: "Larger models are more accurate but slower and use more memory. Multilingual models support 99 languages; English-only models (.en) are faster for English.",
                        theme: theme
                    ) {
                        HStack(spacing: 8) {
                            Picker("", selection: modelPickerSelection) {
                                if !downloadService.isModelDownloaded(selectedModel) {
                                    Text("No model").tag(Self.noModelTag)
                                }
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
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .tint(theme.primaryText)
                            .fixedSize()
                            .onChange(of: selectedModel) { _, newModel in
                                // Also fires when a download finishes and the service stores
                                // the new model, so the language follows that path too.
                                if newModel.hasSuffix(".en") && selectedLanguage != "en" && !selectedLanguage.isEmpty {
                                    selectedLanguage = "en"
                                }
                            }

                            // Shared status chip — shows Installed / Downloading /
                            // Download state for the currently-selected model.
                            // Deletion routes through the existing alert; the
                            // download alert is handled via Picker onChange above.
                            // The chip follows a running pull first — with "No model" showing,
                            // it is the only place the download's progress appears here.
                            if let chipModelId = statusChipModelId {
                                ModelDownloadStatusView(
                                    backend: .whisper,
                                    modelIdentifier: chipModelId,
                                    displayName: chipModelId,
                                    isInstalled: downloadService.isModelDownloaded(chipModelId),
                                    onDeleteRequested: {
                                        pendingModelId = chipModelId
                                        activeAlert = .delete
                                        showWhisperAlert = true
                                    }
                                )
                            }
                        }
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    // Microphone Picker
                    MicrophoneSettingsRow(theme: theme)

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

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
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(isEnglishOnlyModel)
                        .tint(theme.primaryText)
                        .fixedSize()
                        .onChange(of: selectedLanguage) { _, newLanguage in
                            NotificationCenter.default.post(
                                name: GlobalConstants.speechLanguageChangedNotification,
                                object: newLanguage
                            )
                        }
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

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

                // 2. Notifications Section
                NotificationSettingsSection()

                // 3. Language Model Section
                SettingsCard(title: "Language Model", icon: "text.bubble.fill", theme: theme) {
                    SettingsRow(
                        title: "Show Remote Models",
                        description: "Reveals Gemini, OpenAI, and Anthropic across all provider pickers. Experimental — not yet tested.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $showRemoteModels)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

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

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    SettingsRow(
                        title: "Show Reasoning & Thoughts",
                        description: "Display internal reasoning steps between tool invocations in the execution timeline by default. Can also be toggled directly from any message's timeline header.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $showTimelineThoughts)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    SettingsRow(
                        title: "Setup Assistant (Onboarding)",
                        description: "Revisit the initial welcome slideshow, feature overview, and profile setup assistant.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Launch Setup Assistant",
                            icon: "sparkles",
                            variant: .secondary,
                            size: .compact
                        ) {
                            isOnboardingComplete = false
                        }
                    }
                }

                // Updates (Sparkle). The toggle is the user's standing answer to the question Sparkle
                // asks on second launch — PRIVACY.md promises it can be changed here.
                SettingsCard(title: "Updates", icon: "arrow.triangle.2.circlepath", theme: theme) {
                    SettingsRow(
                        title: "Check for Updates Automatically",
                        description: "About once a day, download the public update feed from GitHub Pages. No information about your Mac is sent. Updates are verified against a signing key built into the app before installing.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $softwareUpdater.automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    SettingsRow(
                        title: "Check Now",
                        description: "Look for a newer version right away. Also available from the Devgentic menu.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Check for Updates",
                            icon: "arrow.triangle.2.circlepath",
                            variant: .secondary,
                            size: .compact,
                            isDisabled: !softwareUpdater.canCheckForUpdates
                        ) {
                            softwareUpdater.checkForUpdates()
                        }
                    }
                }

                // 4. Observability Section (formerly Developer)
                SettingsCard(title: "Observability", icon: "chart.xyaxis.line", theme: theme) {
                    SettingsRow(
                        title: "Developer Mode",
                        description: "When enabled, the console logs the full prompt sent to the model, including the file contents and personal context it carries. This is live-console only — it is never written to disk or included in an exported diagnostic bundle. Developer Mode does not change what is stored: which logs are kept on disk is decided solely by Store Diagnostic Traces below.",
                        theme: theme
                    ) {
                        Toggle("", isOn: $developerMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .tint(theme.accentColor)
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

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

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    SettingsRow(
                        title: "Diagnostics Storage",
                        description: "On-disk size of the local trace database (traces, spans, and events powering the Report inspector and problem reports). Entries older than 30 days are purged automatically at launch.",
                        theme: theme
                    ) {
                        Text(diagnosticsStorageText)
                            .font(theme.fontCodeCaption)
                            .foregroundColor(theme.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(theme.accentColor.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(theme.accentColor.opacity(0.2), lineWidth: 0.5)
                            )
                    }

                    Rectangle().fill(theme.dividerColor.opacity(0.3)).frame(height: 0.5)

                    SettingsRow(
                        title: "Open Diagnostic Bundle",
                        description: "Inspect a diagnostic bundle (.zip) exported from another Devgentic install — view its trace, spans, and events. Read-only.",
                        theme: theme
                    ) {
                        TactileButton(
                            title: "Open",
                            icon: "folder.badge.plus",
                            variant: .secondary,
                            size: .compact
                        ) {
                            showBundleViewer = true
                        }
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

                // 5. MLX Models & HuggingFace Section
                ModelSettingsSection()
            }
            .padding(24)
            .padding(.bottom, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(theme.fontCaption2.weight(.bold))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(theme.fontCodeCaption.weight(.bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.8)
                    .textCase(.uppercase)
            }
            .padding(.leading, 4)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.secondaryBackground.opacity(0.65))
                    .background(theme.surfaceOverlay.opacity(0.35))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.dividerColor.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: theme.shadowColor.opacity(0.05), radius: 6, x: 0, y: 3)
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var isWarning: Bool = false
    let theme: any Theme
    @ViewBuilder let control: Control

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(theme.fontFootnote.weight(.semibold))
                    .foregroundColor(theme.primaryText)

                Text(description)
                    .font(theme.fontCaption2)
                    .foregroundColor(isWarning ? theme.warningColor : theme.secondaryText)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            VStack {
                Spacer(minLength: 0)
                control
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isHovered ? theme.accentColor.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

/// Settings → Speech Recognition → Microphone. The same choice as the mic button's right-click
/// menu (`MicrophoneSelection`).
private struct MicrophoneSettingsRow: View {
    let theme: any Theme
    @State private var selection = MicrophoneSelection.shared

    private var description: String {
        if case .unavailable(_, let name) = selection.resolution {
            return MicrophoneMenu.unavailableLabel(name: name, fallback: selection.systemDefault) + "."
        }
        return "The input dictation records from. Orb keeps the system default while echo cancellation is on, so barge-in keeps working."
    }

    var body: some View {
        SettingsRow(title: "Microphone", description: LocalizedStringKey(description),
                    isWarning: { if case .unavailable = selection.resolution { return true }; return false }(),
                    theme: theme) {
            Picker("", selection: Binding(
                get: { selection.selectedUID ?? "" },
                set: { uid in selection.select(selection.devices.first { $0.uid == uid }) }
            )) {
                Text(MicrophoneMenu.systemDefaultLabel(selection.systemDefault)).tag("")
                ForEach(selection.devices) { device in
                    Text(device.name).tag(device.uid)
                }
                // Keep a disconnected choice selectable-as-shown rather than snapping to default.
                if case .unavailable(let uid, let name) = selection.resolution {
                    Text("\(name ?? "Chosen microphone") (not connected)").tag(uid)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(theme.primaryText)
            .fixedSize()
        }
        .onAppear { selection.refresh() }
    }
}
