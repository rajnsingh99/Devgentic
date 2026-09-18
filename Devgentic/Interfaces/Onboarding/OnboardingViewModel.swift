// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OnboardingViewModel.swift
//  Devgentic
//
//  Created by Raj Singh on 17/09/26.
//

import SwiftUI
import SwiftData
import os

private let logger = DGLogger(category: "OnboardingViewModel")

@Observable @MainActor
final class OnboardingViewModel {

    // MARK: - Onboarding Flow Steps
    enum Step: Int, CaseIterable, Identifiable {
        case welcome = 0
        case profileSetup = 1
        case modelDownload = 2
        case themeCustomization = 3
        case ready = 4

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .profileSetup: return "Profile Setup"
            case .modelDownload: return "Model Download"
            case .themeCustomization: return "Theme"
            case .ready: return "Ready"
            }
        }
    }

    // MARK: - Slideshow Item
    struct FeatureSlide: Identifiable {
        let id: Int
        let tag: String
        let title: String
        let subtitle: String
        let description: String
        let badges: [String]
        let iconName: String
        let accentGradient: [Color]
    }

    let featureSlides: [FeatureSlide] = [
        FeatureSlide(
            id: 0,
            tag: "Voice Orb & Assistant",
            title: "Orb Ambient Voice",
            subtitle: "Floating Desktop Orb",
            description: "A floating voice orb with wake-word and push-to-talk activation. Orb uses duplex speech synthesis and speech-to-text to run tasks and narrate agent workflows live.",
            badges: ["Whisper Local", "Apple Speech", "Ambient Narration"],
            iconName: "waveform.circle.fill",
            accentGradient: [Color.cyan, Color.indigo]
        ),
        FeatureSlide(
            id: 1,
            tag: "Instant Global HUD",
            title: "QuickOverlay & Hotkey HUD",
            subtitle: "Spotlight-Style Panel",
            description: "Invoke your agent instantly over any workspace with a global shortcut. Seamlessly capture screen regions, inspect code, and trigger quick prompt tasks without leaving your current app.",
            badges: ["Global Hotkey", "Screen Capture OCR", "Floating HUD"],
            iconName: "sparkles.rectangle.stack.fill",
            accentGradient: [Color.orange, Color.pink]
        ),
        FeatureSlide(
            id: 2,
            tag: "Multi-Agent Graph",
            title: "Visual Workflow Canvas",
            subtitle: "Node-Based Pipelines",
            description: "Connect multiple agents into DAG node graphs. Route decisions, apply code transforms, and enforce human-in-the-loop security gates with per-node timeout and context management.",
            badges: ["Interactive Graph", "HITL Gates", "State Routing"],
            iconName: "point.3.connected.trianglepath.dotted",
            accentGradient: [Color.green, Color.teal]
        ),
        FeatureSlide(
            id: 3,
            tag: "Collaboration Bridges",
            title: "ChatOps Remote Bridges",
            subtitle: "Slack, Discord & Telegram",
            description: "Connect your local Devgentic agent directly to your Slack channels, Discord guilds, or Telegram conversations. Execute team commands while keeping execution 100% on your Mac.",
            badges: ["Slack Socket Mode", "Discord Gateway", "Telegram Bot"],
            iconName: "network",
            accentGradient: [Color.purple, Color.indigo]
        )
    ]

    // MARK: - Navigation State
    var currentStep: Step = .welcome
    var currentSlideIndex: Int = 0

    // MARK: - Profile Setup State
    var profileDisplayName: String = "Local Assistant"
    var selectedProfileType: ProfileType = .bot
    var selectedBackend: ApiProvider = .mlx

    // Starter models
    static let defaultMLXModel = "mlx-community/Llama-3.2-3B-Instruct-4bit"
    static let defaultOllamaModel = "llama3.2:3b"

    var selectedModelIdentifier: String {
        switch selectedBackend {
        case .mlx: return Self.defaultMLXModel
        case .ollama: return Self.defaultOllamaModel
        default: return Self.defaultMLXModel
        }
    }

    var isModelInstalled: Bool = false
    var isCheckingModelStatus: Bool = false

    // MARK: - Download State
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var downloadSpeedText: String = ""
    var downloadEtaText: String = ""
    var downloadBytesText: String = ""
    var downloadStageText: String = "Initializing download..."
    var downloadErrorMessage: String? = nil
    var activeDownloadRecordID: UUID? = nil

    private var pollTimerTask: Task<Void, Never>?

    // MARK: - Theme State
    var selectedThemeID: String = "material"
    var selectedAccentColor: AppAccentColor = .blue
    var selectedSurfaceStyle: SurfaceStyle = .glassmorphic

    // MARK: - Lifecycle / Init
    init() {
        checkInstalledModelStatus()
    }

    // MARK: - Navigation Actions
    func goToStep(_ step: Step) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentStep = step
        }
        if step == .profileSetup {
            checkInstalledModelStatus()
        }
    }

    func nextStep() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        goToStep(next)
    }

    func previousStep() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        goToStep(prev)
    }

    // MARK: - Model Status Check
    func checkInstalledModelStatus() {
        isCheckingModelStatus = true
        let backend = selectedBackend
        let modelId = selectedModelIdentifier

        Task { @MainActor in
            switch backend {
            case .mlx:
                await MLXModelService.shared.ensureLoaded()
                let installed = MLXModelService.shared.isInstalled(repoId: modelId)
                self.isModelInstalled = installed
            case .ollama:
                let localModels = OllamaService.shared.localModels
                let installed = localModels.contains { $0.name == modelId || $0.name.hasPrefix(modelId) }
                self.isModelInstalled = installed
            default:
                self.isModelInstalled = false
            }
            self.isCheckingModelStatus = false
        }
    }

    // MARK: - Profile Setup Flow Step Completion
    func proceedFromProfileSetup() {
        if isModelInstalled {
            // Model already on disk: skip download directly to theme customization
            goToStep(.themeCustomization)
        } else {
            // Needs download: navigate to download view and start
            goToStep(.modelDownload)
            startModelDownload()
        }
    }

    // MARK: - Download Execution
    func startModelDownload() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0.02
        downloadErrorMessage = nil
        downloadStageText = "Connecting to repository..."
        downloadBytesText = "Preparing..."
        downloadSpeedText = "-- MB/s"
        downloadEtaText = "Calculating..."

        let modelId = selectedModelIdentifier
        let backend = selectedBackend

        Task { @MainActor in
            let outcome: DownloadStartOutcome
            switch backend {
            case .mlx:
                outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(repoId: modelId)
            case .ollama:
                outcome = await DownloadCoordinator.startOllamaDownloadIfNeeded(modelName: modelId)
            default:
                outcome = .failed("Unsupported backend for local onboarding.")
            }

            switch outcome {
            case .alreadyInstalled:
                self.downloadProgress = 1.0
                self.isDownloading = false
                self.isModelInstalled = true
                self.downloadStageText = "Model verified and installed!"
                return
            case .alreadyInProgress(let recordID):
                self.activeDownloadRecordID = recordID
            case .startedFresh, .resumedFromHistory:
                // Let DownloadManager register activeRecord
                break
            case .failed(let reason):
                self.downloadErrorMessage = reason
                self.isDownloading = false
                self.downloadStageText = "Download failed."
                return
            }

            self.startProgressMonitoring()
        }
    }

    private func startProgressMonitoring() {
        pollTimerTask?.cancel()
        pollTimerTask = Task { @MainActor in
            let backendType: ModelBackendType = selectedBackend == .mlx ? .mlx : .ollama
            let modelId = selectedModelIdentifier

            while !Task.isCancelled && isDownloading {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms polling

                // Check active record from DownloadManager
                if let record = DownloadManager.shared.activeRecord(backend: backendType, modelIdentifier: modelId) {
                    self.activeDownloadRecordID = record.id
                    self.downloadProgress = max(self.downloadProgress, record.progress)

                    // Format live bytes
                    if let fileSizeBytes = record.fileSizeBytes, fileSizeBytes > 0 {
                        let downloaded = Int64(Double(fileSizeBytes) * record.progress)
                        let downloadedStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                        let totalStr = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
                        self.downloadBytesText = "\(downloadedStr) / \(totalStr)"
                    }

                    // Format live speed & ETA
                    if let speedSnapshot = DownloadManager.shared.activeSpeeds[record.id] {
                        if speedSnapshot.bytesPerSecond > 0 {
                            let speedStr = ByteCountFormatter.string(fromByteCount: Int64(speedSnapshot.bytesPerSecond), countStyle: .file)
                            self.downloadSpeedText = "\(speedStr)/s"
                        }
                        if let eta = speedSnapshot.etaSeconds, eta > 0 {
                            let mins = Int(eta) / 60
                            let secs = Int(eta) % 60
                            self.downloadEtaText = mins > 0 ? "\(mins)m \(secs)s left" : "\(secs)s left"
                        }
                    }

                    // Check stage
                    if record.progress < 0.1 {
                        self.downloadStageText = "Fetching manifest & tokenizer..."
                    } else if record.progress < 0.95 {
                        self.downloadStageText = "Streaming model weights..."
                    } else {
                        self.downloadStageText = "Verifying tensor integrity..."
                    }

                    // Terminal state check
                    if record.status == .completed || record.progress >= 1.0 {
                        self.downloadProgress = 1.0
                        self.isDownloading = false
                        self.isModelInstalled = true
                        self.downloadStageText = "Model weights downloaded and ready!"
                        self.downloadEtaText = "Completed"
                        break
                    } else if record.status == .failed {
                        self.downloadErrorMessage = record.errorMessage ?? "Download failed."
                        self.isDownloading = false
                        self.downloadStageText = "Download failed."
                        break
                    } else if record.status == .cancelled {
                        self.isDownloading = false
                        self.downloadStageText = "Download cancelled."
                        break
                    }
                } else {
                    // If no active record exists, check if model is installed now
                    if selectedBackend == .mlx && MLXModelService.shared.isInstalled(repoId: modelId) {
                        self.downloadProgress = 1.0
                        self.isDownloading = false
                        self.isModelInstalled = true
                        self.downloadStageText = "Model verified and ready!"
                        break
                    }
                }
            }
        }
    }

    func cancelDownload() {
        pollTimerTask?.cancel()
        isDownloading = false
        downloadStageText = "Download cancelled."
        if let recordID = activeDownloadRecordID,
           let record = DownloadHistoryStore.shared.fetch(id: recordID) {
            DownloadManager.shared.cancelDownload(record)
        }
    }

    // MARK: - Finalize Onboarding & Save
    func completeOnboarding(themeManager: ThemeManager, onComplete: @escaping () -> Void) {
        // 1. Apply user theme choices
        if let matchingTheme = themeManager.availableThemes.first(where: { $0.id == selectedThemeID }) {
            themeManager.applyTheme(matchingTheme)
        }
        themeManager.applyAccentColor(selectedAccentColor)
        themeManager.applySurfaceStyle(selectedSurfaceStyle)

        // 2. Build Backend Profile
        let trimmedName = profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Local Assistant" : trimmedName

        let defaultLLMConfig = ProviderConfig(
            apiProvider: selectedBackend,
            modelName: selectedModelIdentifier
        )

        let details: ProfileDetails
        switch selectedProfileType {
        case .bot:
            details = .bot(BotConfig(llmConfig: defaultLLMConfig))
        case .agent:
            details = .agent(AgentConfig(llmConfig: defaultLLMConfig, tools: []))
        default:
            details = .bot(BotConfig(llmConfig: defaultLLMConfig))
        }

        let newProfile = BackendProfileModel(displayName: finalName, details: details)

        // 3. Persist Profile in SwiftData
        do {
            try BackendProfileStore.shared.saveProfile(
                newProfile,
                callerFile: #file,
                callerFunction: #function,
                callerLine: #line
            )
            logger.info("[ONBOARDING] Successfully created initial profile '\(finalName)' (\(self.selectedProfileType.rawValue)).")
        } catch {
            logger.error("[ONBOARDING] Failed to save onboarding profile: \(error.localizedDescription)")
        }

        // 4. Set UserDefaults completion flag
        UserDefaults.standard.set(true, forKey: GlobalConstants.isOnboardingComplete)

        // 5. Fire completion callback to dismiss/transition
        onComplete()
    }
}
