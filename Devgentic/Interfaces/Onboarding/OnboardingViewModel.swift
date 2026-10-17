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
        case behavior = 3
        case features = 4
        case permissions = 5
        case privacy = 6
        case themeCustomization = 7
        case ready = 8

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return String(localized: "Welcome")
            case .profileSetup: return String(localized: "Profile")
            case .modelDownload: return String(localized: "Model")
            case .behavior: return String(localized: "Behavior")
            case .features: return String(localized: "Features")
            case .permissions: return String(localized: "Access")
            case .privacy: return String(localized: "Privacy")
            case .themeCustomization: return String(localized: "Theme")
            case .ready: return String(localized: "Ready")
            }
        }

        /// "STEP 2 OF 4" for the four setup steps; nil for the welcome and ready screens.
        var progressLabel: String? {
            let setupSteps: [Step] = [.profileSetup, .modelDownload, .behavior, .features, .permissions, .privacy, .themeCustomization]
            guard let index = setupSteps.firstIndex(of: self) else { return nil }
            return String(localized: "STEP \(index + 1) OF \(setupSteps.count)")
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
            tag: String(localized: "Voice Orb & Assistant"),
            title: String(localized: "Orb Ambient Voice"),
            subtitle: String(localized: "Floating Desktop Orb"),
            description: String(localized: "A floating voice orb with wake-word and push-to-talk activation. Orb uses duplex speech synthesis and speech-to-text to run tasks and narrate agent workflows live."),
            badges: [String(localized: "Whisper Local"), String(localized: "Apple Speech"), String(localized: "Ambient Narration")],
            iconName: "waveform.circle.fill",
            accentGradient: [Color.cyan, Color.indigo]
        ),
        FeatureSlide(
            id: 1,
            tag: String(localized: "Instant Global Panel"),
            title: String(localized: "Quick Access"),
            subtitle: String(localized: "One Shortcut, Any App"),
            description: String(localized: "Open your agent over any app with a global shortcut. Capture part of the screen, ask about what you're looking at, and run quick prompts without switching windows."),
            badges: [String(localized: "Global Hotkey"), String(localized: "Screen Capture"), String(localized: "Floating Panel")],
            iconName: "sparkles.rectangle.stack.fill",
            accentGradient: [Color.orange, Color.pink]
        ),
        FeatureSlide(
            id: 2,
            tag: String(localized: "Multi-Agent Graph"),
            title: String(localized: "Visual Workflow Canvas"),
            subtitle: String(localized: "Node-Based Pipelines"),
            description: String(localized: "Connect multiple agents into DAG node graphs. Route decisions, apply code transforms, and enforce human-in-the-loop security gates with per-node timeout and context management."),
            badges: [String(localized: "Interactive Graph"), String(localized: "HITL Gates"), String(localized: "State Routing")],
            iconName: "point.3.connected.trianglepath.dotted",
            accentGradient: [Color.green, Color.teal]
        ),
        FeatureSlide(
            id: 3,
            tag: String(localized: "Collaboration Bridges"),
            title: String(localized: "ChatOps Remote Bridges"),
            subtitle: String(localized: "Slack, Discord & Telegram"),
            description: String(localized: "Connect your local Devgentic agent directly to your Slack channels, Discord guilds, or Telegram conversations. Execute team commands while keeping execution 100% on your Mac."),
            badges: [String(localized: "Slack Socket Mode"), String(localized: "Discord Gateway"), String(localized: "Telegram Bot")],
            iconName: "network",
            accentGradient: [Color.purple, Color.indigo]
        )
    ]

    // MARK: - Navigation State
    var currentStep: Step = .welcome
    var currentSlideIndex: Int = 0

    // MARK: - Profile Setup State
    /// Required. Starts empty on purpose: a pre-filled "Local Assistant" was saved again on every
    /// re-run of the Setup Assistant, stacking up identically named profiles.
    var profileDisplayName: String = ""

    /// Names of the user's profiles, read fresh from SwiftData (not the in-memory sidebar list,
    /// which can be stale or empty during onboarding). Workflow-node profiles are excluded — the
    /// user never sees those names, so they must not block one.
    var existingProfileNames: [String] = []
    /// Set when the names could not be read. The duplicate check then cannot run, and the profile
    /// step says so instead of silently passing every name.
    private(set) var profileNamesLoadError: String? = nil

    /// Where the names come from. Injectable so tests drive the duplicate check through this model
    /// without reading the test host's store.
    var fetchExistingProfileNames: () throws -> [String] = {
        try BackendProfileStore.shared.fetchSharedProfiles().map(\.displayName)
    }
    private(set) var selectedProfileType: ProfileType = .agent
    private(set) var selectedBackend: ApiProvider = .mlx

    // MARK: - Model State
    /// Unified memory of this Mac. Injectable so the recommendation is testable.
    let physicalMemoryBytes: UInt64

    /// The starter model picked on the model step. Always one of `availableModels`.
    private(set) var selectedModelID: String = ""

    /// What the profile stores as its model name.
    var selectedModelIdentifier: String { selectedModelID }

    var availableModels: [OnboardingStarterModel] {
        OnboardingStarterCatalog.models(for: selectedBackend)
    }

    var selectedModel: OnboardingStarterModel? {
        availableModels.first { $0.id == selectedModelID }
    }

    var recommendedModel: OnboardingStarterModel? {
        OnboardingStarterCatalog.recommended(for: selectedBackend, physicalMemoryBytes: physicalMemoryBytes)
    }

    var physicalMemoryGB: Int { Int(physicalMemoryBytes / 1_073_741_824) }

    var isModelInstalled: Bool = false
    var isCheckingModelStatus: Bool = false

    // MARK: - Download State
    var isDownloading: Bool = false
    var downloadProgress: Double = 0.0
    var downloadSpeedText: String = ""
    var downloadEtaText: String = ""
    var downloadBytesText: String = ""
    var downloadStageText: String = ""
    var downloadErrorMessage: String? = nil
    var activeDownloadRecordID: UUID? = nil

    /// Downloads that FAILED on this step (cancels do not count). Drives retry-then-skip.
    private(set) var failedDownloadAttempts: Int = 0

    /// The user took the skip offered after the retries ran out. The profile is still created,
    /// pointing at the chosen model, and the Ready screen says it is not downloaded yet.
    private(set) var didSkipDownload: Bool = false

    private var pollTimerTask: Task<Void, Never>?

    // MARK: - Behavior State (tools + system prompt)
    var enabledToolNames: Set<String> = Set(OnboardingToolPreset.tools.map(\.id))
    /// Tools set to run without asking. Empty by default: every starter tool asks first.
    var autoApprovedToolNames: Set<String> = []
    var systemPrompt: String = OnboardingPromptDefaults.agent

    // MARK: - System Settings (features, permissions, privacy)
    /// Everything outside onboarding it reads or changes. Injected so tests never raise a macOS
    /// prompt, register a hotkey, or rewrite real settings.
    let systemSettings: OnboardingSystemSettings

    /// Mirrors of the live switches. They apply immediately, as the Settings switches do.
    private(set) var quickAccessEnabled: Bool = true
    private(set) var orbEnabled: Bool = false

    /// The user's update-check answer. Nil until they choose: there is no pre-selected answer,
    /// because PRIVACY.md promises no automatic request without consent.
    var automaticUpdateChecks: Bool? = nil
    var diagnosticsEnabled: Bool = true

    /// Live permission statuses, refreshed when the step appears and after each request.
    private(set) var permissionStatuses: [OnboardingPermission: OnboardingPermissionStatus] = [:]
    private(set) var requestingPermission: OnboardingPermission? = nil

    /// The switches as they were when onboarding opened — what Cancel puts back.
    private var featureSnapshot: (quickAccess: Bool, orb: Bool)?

    // MARK: - Completion State
    var completionErrorMessage: String? = nil

    // MARK: - Ollama State
    /// nil = not checked yet. False shows the "Get Ollama" link on the model step.
    var isOllamaReachable: Bool? = nil

    /// Where to get Ollama when it is not installed.
    static let ollamaDownloadURL = URL(string: "https://ollama.com/download")!

    // MARK: - Theme State
    var selectedThemeID: String = "material"
    var selectedAccentColor: AppAccentColor = .blue
    var selectedSurfaceStyle: SurfaceStyle = .glassmorphic

    // MARK: - Lifecycle / Init
    init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
         checksInstallStatus: Bool = true,
         systemSettings: OnboardingSystemSettings? = nil) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.systemSettings = systemSettings ?? LiveOnboardingSystemSettings()
        selectedModelID = recommendedModel?.id ?? ""
        if checksInstallStatus {
            checkInstalledModelStatus()
        }
    }

    // MARK: - Navigation Actions
    func goToStep(_ step: Step) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            currentStep = step
        }
        if step == .modelDownload && !isDownloading {
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

    // MARK: - Profile Setup Actions
    func selectProfileType(_ type: ProfileType) {
        // Swap the default prompt with the type, but never overwrite one the user has edited.
        if systemPrompt == OnboardingPromptDefaults.prompt(for: selectedProfileType) {
            systemPrompt = OnboardingPromptDefaults.prompt(for: type)
        }
        selectedProfileType = type
    }

    func selectBackend(_ backend: ApiProvider) {
        guard !isDownloading, backend != selectedBackend else { return }
        selectedBackend = backend
        // The two lists mirror each other, so keep the same rung of the ladder when switching.
        let oldIndex = OnboardingStarterCatalog.models(for: backend == .mlx ? .ollama : .mlx)
            .firstIndex { $0.id == selectedModelID }
        if let oldIndex, availableModels.indices.contains(oldIndex) {
            selectedModelID = availableModels[oldIndex].id
        } else {
            selectedModelID = recommendedModel?.id ?? ""
        }
        resetDownloadPresentation()
        checkInstalledModelStatus()
    }

    func selectModel(_ modelID: String) {
        guard !isDownloading, modelID != selectedModelID,
              availableModels.contains(where: { $0.id == modelID }) else { return }
        selectedModelID = modelID
        resetDownloadPresentation()
        checkInstalledModelStatus()
    }

    private func resetDownloadPresentation() {
        isModelInstalled = false
        didSkipDownload = false
        downloadProgress = 0
        downloadErrorMessage = nil
        downloadStageText = ""
        downloadBytesText = ""
        downloadSpeedText = ""
        downloadEtaText = ""
        activeDownloadRecordID = nil
    }

    // MARK: - Profile Name

    var trimmedProfileName: String {
        profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isDuplicateProfileName: Bool {
        let lower = trimmedProfileName.lowercased()
        return !lower.isEmpty && existingProfileNames.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower }
    }

    /// Why the name cannot be used, or nil when it can.
    var profileNameProblem: String? {
        if trimmedProfileName.isEmpty { return String(localized: "Give your profile a name.") }
        if trimmedProfileName.count > ProfileValidationLimits.maxDisplayNameLength {
            return String(localized: "Keep the name to \(ProfileValidationLimits.maxDisplayNameLength) characters or fewer.")
        }
        if isDuplicateProfileName {
            return String(localized: "You already have a profile named '\(trimmedProfileName)'. Choose a different name.")
        }
        return nil
    }

    /// Re-reads the user's profile names from SwiftData.
    func refreshExistingProfileNames() {
        do {
            existingProfileNames = try fetchExistingProfileNames()
            profileNamesLoadError = nil
        } catch {
            profileNamesLoadError = error.localizedDescription
            logger.error("[ONBOARDING] Could not read existing profile names: \(error.localizedDescription). CONSEQUENCE: the duplicate-name check uses the last list it read (\(self.existingProfileNames.count) name(s)).")
        }
    }

    // MARK: - Model Status Check
    func checkInstalledModelStatus() {
        refreshDiskSpace()
        isCheckingModelStatus = true
        let backend = selectedBackend
        let modelId = selectedModelIdentifier

        Task { @MainActor in
            let installed: Bool
            switch backend {
            case .mlx:
                await MLXModelService.shared.ensureLoaded()
                installed = MLXModelService.shared.isInstalled(repoId: modelId)
            case .ollama:
                // Refresh first: `localModels` is empty until something has asked the server.
                await OllamaService.shared.checkServerStatusAndUpdateModels()
                installed = OllamaService.shared.localModels.contains { $0.name == modelId }
                self.isOllamaReachable = OllamaService.shared.serverStatus == .connected
            default:
                installed = false
            }
            // The user may have picked another model while this ran — a late answer for the old
            // one must not mark the new one installed.
            guard backend == self.selectedBackend, modelId == self.selectedModelIdentifier else { return }
            self.isModelInstalled = installed
            if installed {
                self.downloadProgress = 1.0
                self.downloadStageText = String(localized: "Already downloaded.")
            }
            self.isCheckingModelStatus = false
        }
    }

    // MARK: - Profile Setup Flow Step Completion
    func proceedFromProfileSetup() {
        // Re-read right before leaving: a profile may have been created since the step appeared.
        refreshExistingProfileNames()
        if let problem = profileNameProblem {
            logger.notice("[ONBOARDING] Profile step held: \(problem)")
            return
        }
        goToStep(.modelDownload)
    }

    // MARK: - Disk Space

    /// Free space on the volume the selected engine downloads to. Nil = could not be read, which
    /// never blocks a download (a guess must not strand the user).
    private(set) var availableDiskBytes: Int64? = nil

    func refreshDiskSpace() {
        availableDiskBytes = systemSettings.availableDiskBytes(for: selectedBackend)
    }

    /// What a download needs: its size plus headroom (the larger of 1 GB or 10%), so it does not
    /// fill the disk to the last byte and leave macOS — and the app's own writes — with nothing.
    nonisolated static func requiredDiskBytes(for model: OnboardingStarterModel) -> Int64 {
        model.downloadBytes + max(1_073_741_824, model.downloadBytes / 10)
    }

    func fitsOnDisk(_ model: OnboardingStarterModel) -> Bool {
        guard let free = availableDiskBytes else { return true }
        return free >= Self.requiredDiskBytes(for: model)
    }

    /// Already downloaded needs no space; otherwise the selected model must fit.
    var selectedModelFitsOnDisk: Bool {
        isModelInstalled || (selectedModel.map(fitsOnDisk) ?? true)
    }

    /// Not even the smallest model fits. The download is mandatory, so skipping is then the only
    /// way forward — otherwise the user would be stuck on this step.
    var noModelFitsOnDisk: Bool {
        guard availableDiskBytes != nil else { return false }
        return !availableModels.contains(where: fitsOnDisk)
    }

    // MARK: - Retry, then skip

    /// Retries allowed after the first failed download before skipping is offered.
    nonisolated static let maxDownloadRetries = 2

    enum DownloadRecovery: Equatable {
        /// Nothing has failed.
        case none
        /// A download failed; this many retries remain.
        case retry(remaining: Int)
        /// The retries are used up. Only skipping is offered.
        case skipOnly
    }

    /// What the model step offers after `failedAttempts` failed downloads. Pure, so the policy is
    /// testable: the first attempt plus `maxDownloadRetries` retries, then skip and nothing else.
    nonisolated static func downloadRecovery(failedAttempts: Int) -> DownloadRecovery {
        guard failedAttempts > 0 else { return .none }
        let retriesUsed = failedAttempts - 1
        return retriesUsed < maxDownloadRetries ? .retry(remaining: maxDownloadRetries - retriesUsed) : .skipOnly
    }

    var downloadRecovery: DownloadRecovery {
        Self.downloadRecovery(failedAttempts: failedDownloadAttempts)
    }

    /// The model step's Continue: the model must be on disk, unless skipping was earned.
    var canContinueFromModelStep: Bool {
        !isDownloading && (isModelInstalled || didSkipDownload)
    }

    /// Internal, not private, so tests can drive the retry → skip path through the real model.
    func recordDownloadFailure(_ message: String) {
        failedDownloadAttempts += 1
        downloadErrorMessage = message
        isDownloading = false
        downloadStageText = String(localized: "Download failed.")
        let recovery = downloadRecovery
        logger.error("[ONBOARDING] Download of '\(self.selectedModelIdentifier)' failed (attempt \(self.failedDownloadAttempts)): \(message). CONSEQUENCE: \(recovery == .skipOnly ? "retries used up — only Skip is offered" : "the user is offered a retry").")
    }

    /// Skip is earned by using up the retries, or offered when no starter model fits on the disk.
    var canSkipDownload: Bool {
        !isDownloading && !isModelInstalled && (downloadRecovery == .skipOnly || noModelFitsOnDisk)
    }

    func skipModelDownload() {
        guard canSkipDownload else {
            logger.error("[ONBOARDING] Skip refused for '\(self.selectedModelIdentifier)' — \(self.failedDownloadAttempts) failed attempt(s), downloading: \(self.isDownloading). CONSEQUENCE: the user stays on the model step.")
            return
        }
        didSkipDownload = true
        let reason = noModelFitsOnDisk
            ? "no starter model fits in the \(self.availableDiskBytes ?? 0) bytes free"
            : "\(self.failedDownloadAttempts) failed attempts"
        logger.notice("[ONBOARDING] Model download skipped — \(reason). The profile will point at '\(self.selectedModelIdentifier)', which is NOT downloaded.")
        goToStep(.behavior)
    }

    // MARK: - Download Execution
    func startModelDownload() {
        guard !isDownloading, downloadRecovery != .skipOnly else { return }
        // Fail before a byte is fetched, not 15 GB in. Not counted as a failed attempt: nothing was
        // tried, and the model step already says why Download is unavailable.
        refreshDiskSpace()
        guard selectedModelFitsOnDisk else {
            let needed = selectedModel.map(Self.requiredDiskBytes(for:)) ?? 0
            logger.error("[ONBOARDING] Download of '\(self.selectedModelIdentifier)' refused: needs \(needed) bytes, \(self.availableDiskBytes ?? -1) free. CONSEQUENCE: nothing is downloaded; the model step shows the shortfall.")
            return
        }
        isDownloading = true
        downloadProgress = 0.02
        downloadErrorMessage = nil
        downloadStageText = String(localized: "Connecting to repository...")
        downloadBytesText = String(localized: "Preparing...")
        downloadSpeedText = String(localized: "-- MB/s")
        downloadEtaText = String(localized: "Calculating...")

        let modelId = selectedModelIdentifier
        let backend = selectedBackend

        Task { @MainActor in
            let outcome: DownloadStartOutcome
            switch backend {
            case .mlx:
                outcome = await DownloadCoordinator.startMLXDownloadIfNeeded(repoId: modelId)
            case .ollama:
                // Ollama downloads through its own server. Probe it NOW, ignoring the cooldown: a
                // user who just started Ollama must not fail on a "disconnected" from before.
                await OllamaService.shared.forceCheckServerStatus(triggeredBy: .onboardingDownloadButton)
                self.isOllamaReachable = OllamaService.shared.serverStatus == .connected
                if OllamaService.shared.serverStatus != .connected {
                    outcome = .failed(String(localized: "Ollama isn't running. Install it from ollama.com or open the Ollama app, then retry."))
                } else {
                    outcome = await DownloadCoordinator.startOllamaDownloadIfNeeded(modelName: modelId)
                }
            default:
                outcome = .failed(String(localized: "Unsupported backend for local onboarding."))
            }

            switch outcome {
            case .alreadyInstalled:
                self.downloadProgress = 1.0
                self.isDownloading = false
                self.isModelInstalled = true
                self.downloadStageText = String(localized: "Already downloaded.")
                return
            case .alreadyInProgress(let recordID):
                self.activeDownloadRecordID = recordID
            case .startedFresh, .resumedFromHistory:
                // Let DownloadManager register activeRecord
                break
            case .failed(let reason):
                self.recordDownloadFailure(reason)
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
            var lastRecordSeenAt = Date()

            while !Task.isCancelled && isDownloading {
                try? await Task.sleep(nanoseconds: 250_000_000) // 250ms polling

                // ⚠️ D-24: a finished download LEAVES the active map in the same turn it fails or is
                // cancelled, so reading only `activeRecord` meant the failed/cancelled arms below
                // could never run — the poll spun every 250 ms forever with a stale "Streaming model
                // weights..." stage. The stored record, by id, still carries the real outcome.
                let active = DownloadManager.shared.activeRecord(backend: backendType, modelIdentifier: modelId)
                let record = active ?? self.activeDownloadRecordID.flatMap { DownloadHistoryStore.shared.fetch(id: $0) }
                if record != nil { lastRecordSeenAt = Date() }

                if let record, active != nil {
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
                            self.downloadSpeedText = String(localized: "\(speedStr)/s")
                        }
                        if let eta = speedSnapshot.etaSeconds, eta > 0 {
                            let mins = Int(eta) / 60
                            let secs = Int(eta) % 60
                            self.downloadEtaText = mins > 0 ? String(localized: "\(mins)m \(secs)s left") : String(localized: "\(secs)s left")
                        }
                    }

                    // Check stage
                    if record.progress < 0.1 {
                        self.downloadStageText = String(localized: "Fetching manifest & tokenizer...")
                    } else if record.progress < 0.95 {
                        self.downloadStageText = String(localized: "Streaming model weights...")
                    } else {
                        self.downloadStageText = String(localized: "Verifying tensor integrity...")
                    }
                }

                let installed = selectedBackend == .mlx && MLXModelService.shared.isInstalled(repoId: modelId)
                switch Self.pollVerdict(status: record?.status, progress: record?.progress ?? 0,
                                        errorMessage: record?.errorMessage, installed: installed,
                                        secondsWithoutRecord: Date().timeIntervalSince(lastRecordSeenAt)) {
                case .keepPolling:
                    continue
                case .completed:
                    self.downloadProgress = 1.0
                    self.isDownloading = false
                    self.isModelInstalled = true
                    self.downloadStageText = String(localized: "Model weights downloaded and ready!")
                    self.refreshDiskSpace()
                    self.downloadEtaText = String(localized: "Completed")
                    logger.info("[ONBOARDING] Model '\(modelId)' downloaded.")
                case .failed(let message):
                    self.recordDownloadFailure(message)
                case .cancelled:
                    self.isDownloading = false
                    self.downloadProgress = 0
                    self.downloadStageText = String(localized: "Download cancelled.")
                }
                break
            }
        }
    }

    enum PollVerdict: Equatable {
        case keepPolling
        case completed
        case failed(String)
        case cancelled
    }

    /// How long the poll waits for a download record to appear (or reappear) before reporting that
    /// the download never started. Without it a start that registered nothing polled forever.
    nonisolated static let recordAppearanceGrace: TimeInterval = 30

    /// What the onboarding poll does next. Pure, so the terminal rules are testable (D-24).
    nonisolated static func pollVerdict(status: DownloadRecordStatus?, progress: Double, errorMessage: String?,
                            installed: Bool, secondsWithoutRecord: TimeInterval) -> PollVerdict {
        switch status {
        case .completed?:
            return .completed
        case .failed?:
            return .failed(errorMessage ?? String(localized: "Download failed."))
        case .interrupted?:
            return .failed(errorMessage ?? String(localized: "The download was interrupted. Try again."))
        case .cancelled?:
            return .cancelled
        case .queued?, .downloading?, .paused?:
            return progress >= 1.0 ? .completed : .keepPolling
        case nil:
            if installed { return .completed }
            return secondsWithoutRecord > recordAppearanceGrace
                ? .failed(String(localized: "The download did not start. Check your connection and try again."))
                : .keepPolling
        }
    }

    /// Cancelling is not a failure: it does not use up a retry.
    func cancelDownload() {
        pollTimerTask?.cancel()
        isDownloading = false
        downloadProgress = 0
        downloadStageText = String(localized: "Download cancelled.")
        let backendType: ModelBackendType = selectedBackend == .mlx ? .mlx : .ollama
        // The record id is only known once the poll has seen the record; a cancel in the first
        // 250 ms used to find nothing and leave the download running.
        let record = activeDownloadRecordID.flatMap { DownloadHistoryStore.shared.fetch(id: $0) }
            ?? DownloadManager.shared.activeRecord(backend: backendType, modelIdentifier: selectedModelIdentifier)
        if let record {
            DownloadManager.shared.cancelDownload(record)
        } else {
            logger.error("[ONBOARDING] Cancel found no download record for '\(self.selectedModelIdentifier)'. CONSEQUENCE: if the download had started it keeps running in the Downloads list.")
        }
    }

    // MARK: - Features (opt-in switches)

    /// Start from the user's current switches and answers, not first-run defaults (a re-run).
    func adoptCurrentSettings() {
        quickAccessEnabled = systemSettings.quickAccessEnabled
        orbEnabled = systemSettings.orbEnabled
        automaticUpdateChecks = systemSettings.automaticUpdateChecks
        diagnosticsEnabled = systemSettings.diagnosticsEnabled
        featureSnapshot = (quickAccessEnabled, orbEnabled)
    }

    func setQuickAccessEnabled(_ enabled: Bool) {
        quickAccessEnabled = enabled
        systemSettings.quickAccessEnabled = enabled
    }

    func setOrbEnabled(_ enabled: Bool) {
        orbEnabled = enabled
        systemSettings.orbEnabled = enabled
    }

    // MARK: - Permissions

    /// Only what the user's choices need, in a fixed order. Microphone is always offered (voice
    /// input in chat uses it too); the rest follow the tools and features switched on.
    var relevantPermissions: [OnboardingPermission] {
        var list: [OnboardingPermission] = [.microphone]
        if selectedProfileType == .agent {
            if enabledToolNames.contains("manage_calendar") { list.append(.calendar) }
            if enabledToolNames.contains("manage_reminders") { list.append(.reminders) }
        }
        if quickAccessEnabled { list.append(.screenRecording) }
        return list
    }

    /// Why this permission is on the list, in terms of what the user picked.
    func reason(for permission: OnboardingPermission) -> String {
        switch permission {
        case .microphone:
            return orbEnabled
                ? String(localized: "The Orb listens through it. Also used for voice input in chat.")
                : String(localized: "Voice input in chat, and the Orb if you turn it on later.")
        case .calendar:
            return String(localized: "Your agent's Calendar tool reads and adds events.")
        case .reminders:
            return String(localized: "Your agent's Reminders tool reads and adds reminders.")
        case .screenRecording:
            return String(localized: "Quick Access captures part of your screen to ask about it. Takes effect after you reopen Devgentic.")
        }
    }

    func refreshPermissionStatuses() {
        for permission in OnboardingPermission.allCases {
            // A refused Screen Recording request reads back as "not asked" (macOS reports only
            // granted-or-not), so keep a denial this setup already saw.
            if permissionStatuses[permission] == .denied,
               systemSettings.status(of: permission) == .notAsked { continue }
            permissionStatuses[permission] = systemSettings.status(of: permission)
        }
    }

    func status(of permission: OnboardingPermission) -> OnboardingPermissionStatus {
        permissionStatuses[permission] ?? .notAsked
    }

    func requestPermission(_ permission: OnboardingPermission) async {
        guard requestingPermission == nil else { return }
        requestingPermission = permission
        let result = await systemSettings.request(permission)
        permissionStatuses[permission] = result
        requestingPermission = nil
    }

    // MARK: - Privacy

    /// Privacy's Continue: the update question must be answered, either way.
    var canContinueFromPrivacy: Bool { automaticUpdateChecks != nil }

    // MARK: - Theme Adoption

    /// Start the theme step from what the user has now, not from the first-run defaults. Without
    /// this a re-run of the Setup Assistant re-applied Material Darker / blue / glass on Launch,
    /// silently undoing whatever the user had chosen in Settings since.
    func adoptCurrentTheme(from themeManager: ThemeManager) {
        selectedThemeID = themeManager.baseTheme.id
        selectedAccentColor = themeManager.selectedAccentColor
        selectedSurfaceStyle = themeManager.surfaceStyle
        themeSnapshot = ThemeSnapshot(themeID: selectedThemeID, accent: selectedAccentColor, surface: selectedSurfaceStyle)
    }

    /// The theme the user had when onboarding opened. The theme step applies picks live, so this is
    /// what Cancel puts back.
    private struct ThemeSnapshot {
        let themeID: String
        let accent: AppAccentColor
        let surface: SurfaceStyle
    }
    private var themeSnapshot: ThemeSnapshot?

    /// Applies a theme live, and swaps a light/dark-only accent for its mirror so it stays readable.
    func selectTheme(_ themeID: String, themeManager: ThemeManager) {
        guard let matching = themeManager.availableThemes.first(where: { $0.id == themeID }) else {
            logger.error("[ONBOARDING] Theme '\(themeID)' is not in ThemeManager.availableThemes. CONSEQUENCE: the theme is unchanged.")
            return
        }
        selectedThemeID = themeID
        themeManager.applyTheme(matching)
        let adjusted = Self.accentAdjusted(selectedAccentColor, isDarkTheme: matching.isDark)
        if adjusted != selectedAccentColor {
            selectedAccentColor = adjusted
            themeManager.applyAccentColor(adjusted)
        }
    }

    /// The accents offered. The last slot mirrors the theme: Pure White reads only on dark themes
    /// (on a light one, white text and white highlights vanish), Onyx Black only on light ones.
    nonisolated static func accentPalette(isDarkTheme: Bool) -> [AppAccentColor] {
        [.blue, .green, .spotify, .purple, .modernSpotify, .orange, .pink, isDarkTheme ? .white : .black]
    }

    nonisolated static func accentAdjusted(_ accent: AppAccentColor, isDarkTheme: Bool) -> AppAccentColor {
        switch accent {
        case .white where !isDarkTheme: return .black
        case .black where isDarkTheme: return .white
        default: return accent
        }
    }

    // MARK: - Cancel (re-runs only)

    /// Only someone who already has a profile may leave without creating one. A first run must end
    /// with a profile, so it has no way out but through.
    var canCancelSetup: Bool { !existingProfileNames.isEmpty }

    /// Leaves a re-run without creating a profile: stops any download and puts the theme back.
    func cancelSetup(themeManager: ThemeManager, onComplete: @escaping (_ createdProfileID: UUID?) -> Void) {
        guard canCancelSetup else {
            logger.error("[ONBOARDING] Cancel refused — no existing profiles. CONSEQUENCE: setup stays open; a first run must create a profile.")
            return
        }
        if isDownloading {
            cancelDownload()
        }
        if let features = featureSnapshot {
            if systemSettings.quickAccessEnabled != features.quickAccess { systemSettings.quickAccessEnabled = features.quickAccess }
            if systemSettings.orbEnabled != features.orb { systemSettings.orbEnabled = features.orb }
        }
        if let snapshot = themeSnapshot {
            if let theme = themeManager.availableThemes.first(where: { $0.id == snapshot.themeID }) {
                themeManager.applyTheme(theme)
            }
            themeManager.applyAccentColor(snapshot.accent)
            themeManager.applySurfaceStyle(snapshot.surface)
        } else {
            logger.error("[ONBOARDING] Cancel found no theme snapshot. CONSEQUENCE: theme picks made during setup are kept.")
        }
        logger.notice("[ONBOARDING] Setup Assistant cancelled with \(self.existingProfileNames.count) existing profile(s). No profile created.")
        TestHost.defaults.set(true, forKey: GlobalConstants.isOnboardingComplete)
        onComplete(nil)
    }

    // MARK: - Behavior Actions
    func toggleTool(_ name: String) {
        if enabledToolNames.contains(name) {
            enabledToolNames.remove(name)
        } else {
            enabledToolNames.insert(name)
        }
    }

    func setAutoApprove(_ autoApprove: Bool, for name: String) {
        if autoApprove {
            autoApprovedToolNames.insert(name)
        } else {
            autoApprovedToolNames.remove(name)
        }
    }

    func resetSystemPrompt() {
        systemPrompt = OnboardingPromptDefaults.prompt(for: selectedProfileType)
    }

    // MARK: - Profile Assembly

    /// Everything the Setup Assistant collected, as the profile it saves: model, tools with their
    /// approval settings, and system prompt. The user lands on a profile that is ready to run.
    func makeProfileDetails() -> ProfileDetails {
        let bareLLMConfig = ProviderConfig(
            apiProvider: selectedBackend,
            modelName: selectedModelIdentifier
        )
        // ⚠️ Apply detection to what is stored. This used to save the bare config — capability
        // "Text Only", no context window — so the profile read as unable to call tools (and the
        // validator said so) until someone opened its editor and saved. Runs detect live regardless
        // (`LiveModelDetection`); this keeps the STORED copy and every display of it honest. Cache-
        // only: if the model is not in memory yet, the bare config is kept and runs still resolve.
        let llmConfig = LiveModelDetection.detectedFromCache(bareLLMConfig) ?? bareLLMConfig

        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = trimmedPrompt.isEmpty ? nil : trimmedPrompt

        switch selectedProfileType {
        case .agent:
            let tools = OnboardingToolPreset.makeTools(enabled: enabledToolNames, autoApproved: autoApprovedToolNames)
            return .agent(AgentConfig(llmConfig: llmConfig, tools: tools, instructions: instructions))
        default:
            return .bot(BotConfig(llmConfig: llmConfig, instructions: instructions))
        }
    }

    // MARK: - Finalize Onboarding & Save
    func completeOnboarding(themeManager: ThemeManager, onComplete: @escaping (_ createdProfileID: UUID?) -> Void) {
        completionErrorMessage = nil

        // 0. The name is checked again against SwiftData: the profile step's check may be minutes old.
        refreshExistingProfileNames()
        if let problem = profileNameProblem {
            completionErrorMessage = problem
            logger.error("[ONBOARDING] Completion refused: \(problem). CONSEQUENCE: onboarding stays open; go back to the Profile step to rename.")
            return
        }

        // 1. Apply user theme choices
        if let matchingTheme = themeManager.availableThemes.first(where: { $0.id == selectedThemeID }) {
            themeManager.applyTheme(matchingTheme)
        }
        themeManager.applyAccentColor(selectedAccentColor)
        themeManager.applySurfaceStyle(selectedSurfaceStyle)

        // 2. Build and persist the profile. ⚠️ A failed save must NOT finish onboarding: it used to
        // log and carry on, landing the user in the app with no profile and no explanation.
        let finalName = trimmedProfileName
        let newProfile = BackendProfileModel(displayName: finalName, details: makeProfileDetails())
        do {
            try BackendProfileStore.shared.saveProfile(
                newProfile,
                callerFile: #file,
                callerFunction: #function,
                callerLine: #line
            )
            let enabledTools = selectedProfileType == .agent ? enabledToolNames.count : 0
            logger.info("[ONBOARDING] Created initial profile '\(finalName)' (\(self.selectedProfileType.rawValue)) — model '\(self.selectedModelIdentifier)' (\(self.isModelInstalled ? "downloaded" : "NOT downloaded, skipped")), \(enabledTools) tool(s) enabled, \(self.autoApprovedToolNames.count) auto-approved.")
        } catch {
            completionErrorMessage = String(localized: "Couldn't save your profile: \(error.localizedDescription)")
            logger.error("[ONBOARDING] Failed to save onboarding profile '\(finalName)': \(error.localizedDescription). CONSEQUENCE: onboarding stays open on the Ready step so the user can retry.")
            return
        }

        // 3. Privacy answers. Applied only now, so a cancelled or failed setup changes neither.
        if let automaticUpdateChecks {
            systemSettings.setAutomaticUpdateChecks(automaticUpdateChecks)
        } else {
            logger.error("[ONBOARDING] Completed without an update-check answer. CONSEQUENCE: Sparkle asks on the next launch instead.")
        }
        systemSettings.diagnosticsEnabled = diagnosticsEnabled

        // 4. Set UserDefaults completion flag
        TestHost.defaults.set(true, forKey: GlobalConstants.isOnboardingComplete)

        // 5. Fire completion callback to dismiss/transition, naming the profile so the app can show
        //    and select it (see `OnboardingCompletion`).
        onComplete(newProfile.id)
    }
}
