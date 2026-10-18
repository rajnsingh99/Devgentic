// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import SwiftUI
import os

private let logger = DGLogger(category: "OllamaService")

/// Represents a single, styled tag for a model.
struct ModelTag: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let color: Color
    let icon: String?
}

/// Represents a local model with its name, details, and generated tags.
struct LocalModel: Identifiable, Hashable {
    // FIX: Use the model's unique name as the stable identifier.
    // This prevents SwiftUI from getting confused when the list is refreshed.
    var id: String { name }
    let name: String
    /// Blob digest from `/api/tags`. Same digest ⇒ the cached `/api/show` detection
    /// is still valid (see `LocalModelRefresher`). Nil when the entry predates digest
    /// tracking or its detail fetch failed — treated as "changed" so it re-detects.
    let digest: String?
    let details: OllamaModelDetails?
    let tags: [ModelTag]

    /// The full cognitive profile (capability + dialect) as detected from the Ollama response.
    let cognitiveProfile: CognitiveProfile

    /// Whether this model supports Ollama's `think` parameter (detected via Option A).
    let supportsThinking: Bool

    /// Convenience accessor for the capability tier (backward compat).
    var cognitiveCapability: ModelCognitiveCapability { cognitiveProfile.capability }

    /// Convenience accessor for the output dialect.
    var modelDialect: ModelDialect { cognitiveProfile.dialect }

    init(name: String, digest: String? = nil, response: OllamaShowResponse) {
        self.name = name
        self.digest = digest
        self.details = response.details
        // Uses the method form so reasoning-only detection can check `name` itself: distilled fine-tunes (e.g.
        // deepseek-r1:14b) report a tool-capable base family but keep the reasoning-only identity in the name.
        self.cognitiveProfile = response.cognitiveProfile(modelName: name)
        self.supportsThinking = response.supportsThinking
        self.tags = Self.generateTags(from: response, profile: self.cognitiveProfile)
    }

    /// Generates tags from the name-aware profile, since reasoning-only detection needs the model name.
    /// Vision and Thinking come from the same detection the pickers bind to.
    private static func generateTags(from response: OllamaShowResponse, profile: CognitiveProfile) -> [ModelTag] {
        var generatedTags: [ModelTag] = []

        // Add quantization level tag
        if let quant = response.details?.quantizationLevel, !quant.isEmpty {
            generatedTags.append(ModelTag(text: quant, color: .cyan, icon: "dial.medium.fill"))
        }

        if profile.capability != .none {
            // Reasoning-focused models are usable but flagged: server accepts tools,
            // the fine-tune's call reliability is the concern.
            if profile.toolSupportCaveat == .reasoningFocused {
                generatedTags.append(ModelTag(text: "Tools · limited", color: .yellow, icon: "wrench.and.screwdriver.fill"))
            } else {
                generatedTags.append(ModelTag(text: "Tools", color: .orange, icon: "wrench.and.screwdriver.fill"))
            }
        }

        if profile.modalities.contains(.visionInput) {
            generatedTags.append(ModelTag(text: "Vision", color: .purple, icon: "eye.fill"))
        }

        if response.supportsThinking {
            generatedTags.append(ModelTag(text: "Thinking", color: .green, icon: "brain.head.profile"))
        }

        return generatedTags
    }
    
    // Conformance to Hashable and Equatable
    static func == (lhs: LocalModel, rhs: LocalModel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Digest-Aware Model Refresh

/// Digest-aware local-model refresh shared by `OllamaService` and `ModelCatalogService`.
/// One `/api/tags` plus `/api/version` probe decides which models need the expensive `/api/show`
/// detection; unchanged digests reuse the cache and a daemon version change invalidates it wholesale.
enum LocalModelRefresher {

    struct RefreshPlan: Equatable {
        var reusableNames: [String] = []
        var namesToFetch: [String] = []
    }

    /// Pure diff between cached models and a fresh `/api/tags` listing.
    /// A version change re-detects everything; a nil digest on either side re-detects that model; cached
    /// models absent from `fresh` are dropped.
    static func planRefresh(
        cached: [LocalModel],
        fresh: [OllamaConnect.OllamaTagEntry],
        daemonVersionChanged: Bool
    ) -> RefreshPlan {
        guard !daemonVersionChanged else {
            return RefreshPlan(reusableNames: [], namesToFetch: fresh.map(\.name))
        }
        var cachedDigests: [String: String] = [:]
        for model in cached {
            if let digest = model.digest { cachedDigests[model.name] = digest }
        }
        var plan = RefreshPlan()
        for entry in fresh {
            if let freshDigest = entry.digest, cachedDigests[entry.name] == freshDigest {
                plan.reusableNames.append(entry.name)
            } else {
                plan.namesToFetch.append(entry.name)
            }
        }
        return plan
    }

    /// `/api/tags` entries with each name once, first occurrence kept.
    /// Keyed without `Dictionary(uniqueKeysWithValues:)`, which traps when a proxy lists a model twice.
    static func uniqueByName(_ entries: [OllamaConnect.OllamaTagEntry]) -> [OllamaConnect.OllamaTagEntry] {
        var seen = Set<String>()
        let unique = entries.filter { seen.insert($0.name).inserted }
        if unique.count < entries.count {
            logger.warning("[OLLAMA] /api/tags listed \(entries.count - unique.count) model name(s) more than once. CONSEQUENCE: each is kept once (the first entry); a proxy in front of Ollama is the usual cause.")
        }
        return unique
    }

    /// Fetches the current model list, reusing cached detection where digests match.
    /// A failed `/api/show` degrades to a bare `LocalModel` (visible, untagged, nil
    /// digest so the next refresh retries) — a model is never silently dropped.
    static func refresh(
        baseURL: String,
        cached: [LocalModel],
        cachedDaemonVersion: String?
    ) async throws -> (models: [LocalModel], daemonVersion: String?) {
        let entries = uniqueByName(try await OllamaConnect.fetchLocalOllamaModelTags(baseURL: baseURL))
        let daemonVersion = await OllamaConnect.fetchDaemonVersion(baseURL: baseURL)
        let versionChanged = daemonVersion != nil && daemonVersion != cachedDaemonVersion

        let plan = planRefresh(cached: cached, fresh: entries, daemonVersionChanged: versionChanged)

        let cachedByName = Dictionary(cached.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var models: [LocalModel] = plan.reusableNames.compactMap { cachedByName[$0] }

        let digestsByName = Dictionary(entries.map { ($0.name, $0.digest) }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: LocalModel.self) { group in
            for name in plan.namesToFetch {
                group.addTask {
                    do {
                        let response = try await OllamaConnect.fetchModelDetails(name: name, baseURL: baseURL)
                        return LocalModel(name: name, digest: digestsByName[name] ?? nil, response: response)
                    } catch {
                        logger.error("Failed to fetch details for model \(name): \(error.localizedDescription)")
                        let emptyResponse = OllamaShowResponse(license: nil, modelfile: nil, parameters: nil, template: nil, details: nil, capabilities: nil, modelInfo: nil)
                        return LocalModel(name: name, digest: nil, response: emptyResponse)
                    }
                }
            }
            for await model in group {
                models.append(model)
            }
        }

        // A nil version (endpoint missing / transient failure) keeps the previous one
        // so a single failed probe doesn't force a full re-detect next time.
        return (models.sorted { $0.name < $1.name }, daemonVersion ?? cachedDaemonVersion)
    }
}


@MainActor // Ensure the entire class runs on the MainActor by default
@Observable
class OllamaService {

    // MARK: - Singleton Pattern
    /// The shared singleton instance of the OllamaService.
    static let shared = OllamaService()

    // MARK: - Published Properties (for Ollama State)
    var serverStatus: OllamaServerStatus = .unknown
    var localModels: [LocalModel] = []
    var isLoadingModels: Bool = false
    var modelLoadingError: String? = nil

    var modelToPull: String = "" // For UI binding
    var isPullingModel: Bool = false
    var pullStatusMessage: String = ""

    /// The pull narration that changes only at a lifecycle boundary (start, success, cancel, failure),
    /// never per progress line. Safe for an observer to track; `pullStatusMessage` is rewritten per NDJSON
    /// line and Observation fires on every assignment.
    var pullTerminalState: PullTerminalState?

    /// How the most recent pull ended, carried as a value so the outcome and its sentence cannot drift
    /// apart. A phase (`isPullingModel`) cannot tell success from cancel or failure.
    enum PullTerminalState: Equatable {
        case started(model: String)
        case succeeded(model: String)
        case cancelled
        case failed(model: String)

        var message: String {
            switch self {
            case .started(let model):   return "Starting pull for \(model)…"
            case .succeeded(let model): return "Successfully pulled \(model)."
            case .cancelled:            return "Download cancelled."
            case .failed(let model):    return "Failed to pull \(model)."
            }
        }

        /// True once the pull has stopped — the banner uses this, never `isPullingModel`.
        var isTerminal: Bool {
            if case .started = self { return false }
            return true
        }

        /// `.cancelled` is not a success and not an error either (the user asked for it), so it gets neither
        /// tick nor triangle.
        var isSuccess: Bool {
            if case .succeeded = self { return true }
            return false
        }
    }
    var modelPullError: String? = nil
    var pullProgress: Double = 0.0
    var pullStage: String = "" // e.g., "downloading", "verifying"
    var pullTotalBytes: Int64? = nil
    var pullCompletedBytes: Int64? = nil
    var pullErrorRequiresUpdate: Bool = false

    var isRemovingModel: Bool = false
    var removingModelName: String? = nil // To indicate which model is being removed
    var modelRemoveError: String? = nil
    
    // MARK: - Task Management
    private var pullTask: Task<Void, Error>?

    // MARK: - Probe Caching
    /// Tracks when the last failed server check occurred to prevent rapid-fire socket errors.
    private var lastFailedCheckTime: Date? = nil
    private let failedCheckCooldown: TimeInterval = 30

    /// Daemon version seen at the last successful model load. A version change
    /// invalidates digest-based detection reuse in `LocalModelRefresher` — an
    /// upgraded daemon can report different capabilities for the same model blob.
    private var lastDaemonVersion: String? = nil

    // MARK: - Configuration Properties
    /// These properties are now set by a central authority (like MainApplicationViewModel) based on the active profile.
    var llmModelName: String = "gemma:2b" // Default, but will be overridden by profile
    var ollamaBaseURL: String = ProviderDefaults.ollamaBaseURL.absoluteString // Default, but will be overridden by profile

    /// The initializer is private to enforce the use of the `shared` singleton instance.
    private init() {
        logger.info("OllamaService singleton initialized.")
    }

    // MARK: - Public Methods for Ollama Management

    func checkServerStatusAndUpdateModels() async {
        guard serverStatus != .checking else { return }

        // Skip re-probing if the last failure was recent and status is still disconnected.
        // This prevents socket error spam when Ollama is not running.
        if serverStatus == .disconnected,
           let lastFailed = lastFailedCheckTime,
           Date().timeIntervalSince(lastFailed) < failedCheckCooldown {
            logger.debug("Skipping Ollama probe — last failure was \(Int(Date().timeIntervalSince(lastFailed)))s ago (cooldown: \(Int(self.failedCheckCooldown))s).")
            return
        }

        serverStatus = .checking
        isLoadingModels = true
        modelLoadingError = nil

        let isConnected = await OllamaConnect.checkOllamaServerStatus(baseURL: ollamaBaseURL)

        if isConnected {
            serverStatus = .connected
            lastFailedCheckTime = nil
            await loadLocalModels()
        } else {
            serverStatus = .disconnected
            lastFailedCheckTime = Date()
            localModels = []
            modelLoadingError = "Cannot connect to Ollama server at \(ollamaBaseURL)."
            isLoadingModels = false
        }
    }

    /// Forces a server check regardless of cooldown.
    /// The `UserAction` parameter is a proof-of-intent token: call only from explicit user-interaction
    /// sites (refresh button, Cmd-R). The trigger string is logged for traceability.
    func forceCheckServerStatus(triggeredBy action: UserAction) async {
        logger.info("forceCheckServerStatus triggered by \(action)")
        lastFailedCheckTime = nil
        await checkServerStatusAndUpdateModels()
    }

    func loadLocalModels() async {
        guard serverStatus == .connected, !isPullingModel, !isRemovingModel else {
            return
        }
        await performLocalModelRefresh()
    }

    // Why: calling the guarded `loadLocalModels()` there fetches nothing and leaves a stale list for the
    // observer and `DownloadManager`.
    /// The refresh itself, without the "is anything else in flight?" guard.
    /// `pullModel` must refresh from inside its own window, where `isPullingModel` is still true.
    private func performLocalModelRefresh() async {
        isLoadingModels = true
        modelLoadingError = nil
        
        do {
            // Digest-aware refresh: the `/api/show` fan-out runs only for new or changed models,
            // so calling this on every view appearance is safe.
            let result = try await LocalModelRefresher.refresh(
                baseURL: ollamaBaseURL,
                cached: localModels,
                cachedDaemonVersion: lastDaemonVersion
            )
            self.localModels = result.models
            self.lastDaemonVersion = result.daemonVersion

        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.modelLoadingError = "Failed to load models: \(errorMessage)"
            // The list is cleared only when the server is actually gone; otherwise the last good list stands,
            // so one timeout does not make every installed model look missing.
            if Self.refreshErrorMeansServerGone(error) {
                self.localModels = []
                self.serverStatus = .disconnected
                logger.warning("[OLLAMA] Model refresh failed — the server is unreachable (\(error.localizedDescription)). CONSEQUENCE: status is disconnected and the model list is empty until it is back.")
            } else {
                logger.warning("[OLLAMA] Model refresh failed while the server is reachable (\(error.localizedDescription)). CONSEQUENCE: the last good list of \(self.localModels.count) model(s) is kept, so installed models are not reported missing; the next refresh retries.")
            }
        }
        isLoadingModels = false
    }

    // MARK: - Pull reservation

    /// The pull that has claimed the one Ollama pull slot but may not have started yet.
    /// Claimed synchronously before any await, so two quick clicks cannot both start a pull.
    private(set) var pullReservation: UUID?

    /// Whether the pull slot is taken — pulling, or claimed by a pull about to start.
    var isPullSlotTaken: Bool { isPullingModel || pullReservation != nil }

    /// Claims the pull slot. Nil when it is taken. Pass the token to `pullModel`, or give it back
    /// with `releasePullReservation` if the pull will not start.
    func reservePull() -> UUID? {
        guard !isPullSlotTaken else { return nil }
        let token = UUID()
        pullReservation = token
        return token
    }

    func releasePullReservation(_ token: UUID) {
        if pullReservation == token { pullReservation = nil }
    }

    /// Whether a refresh error means the server is not there (rather than one failed request).
    static func refreshErrorMeansServerGone(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost
    }

    func pullModel(name: String, baseURL: String, reservation: UUID? = nil) async {
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            logger.error("[DOWNLOAD] Ollama pull refused — empty model name. CONSEQUENCE: nothing is pulled and the caller has already reported success to the user.")
            if let reservation { releasePullReservation(reservation) }
            return
        }
        // Refusal is logged here, since this is reachable from any caller and a silent return would show
        // "Downloading" with no pull.
        guard !isPullingModel, pullReservation == nil || pullReservation == reservation else {
            logger.error("[DOWNLOAD] Ollama pull of '\(trimmedModelName)' REFUSED — \(self.isPullingModel ? "'\(self.modelToPull)' is already pulling" : "another pull has claimed the slot and is starting"). CONSEQUENCE: the request is dropped; only one Ollama pull runs at a time.")
            if let reservation { releasePullReservation(reservation) }
            return
        }
        // Claimed before the first await below; released when this call ends, however it ends.
        let slot = reservation ?? UUID()
        pullReservation = slot
        defer { releasePullReservation(slot) }
        guard !isRemovingModel else {
            self.modelPullError = "Cannot pull model while another is being removed."
            return
        }
        guard await OllamaConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelPullError = "Ollama server at \(baseURL) is not connected."
            self.serverStatus = .disconnected
            return
        }
        self.ollamaBaseURL = baseURL

        // Set trimmed and non-empty before the next await: `DownloadManager.bindOllama` opens a record from it
        // at the next suspension point and matches it against `modelIdentifier`.
        modelToPull = trimmedModelName
        // Order-sensitive: the observer runs at the next suspension point, and counters left from the previous
        // pull would be baked into the new record's size, giving a wrong percentage and ETA.
        pullTotalBytes = nil
        pullCompletedBytes = nil
        isPullingModel = true
        pullStatusMessage = "Starting pull for \(trimmedModelName)..."
        pullTerminalState = .started(model: trimmedModelName)
        modelPullError = nil
        pullProgress = 0.0
        pullStage = "Starting..."
        pullErrorRequiresUpdate = false
        
        pullTask = OllamaConnect.pullOllamaModel(name: trimmedModelName, baseURL: baseURL) { progressUpdate in
            DispatchQueue.main.async {
                self.pullStage = progressUpdate.status
                self.pullTotalBytes = progressUpdate.total
                self.pullCompletedBytes = progressUpdate.completed
                self.pullProgress = progressUpdate.percentage ?? self.pullProgress
                
                if let percentage = progressUpdate.percentage {
                    self.pullStatusMessage = "\(progressUpdate.status.capitalized): \(String(format: "%.0f%%", percentage * 100))"
                } else {
                    self.pullStatusMessage = progressUpdate.status.capitalized
                }

                if let streamedError = progressUpdate.error {
                    self.modelPullError = "Stream Error: \(streamedError)"
                }
            }
        }

        do {
            try await pullTask?.value
            pullStatusMessage = "Successfully pulled \(trimmedModelName)."
            pullTerminalState = .succeeded(model: trimmedModelName)
            // The unguarded refresh, which must stay so: `isPullingModel` is still true here, and
            // `loadLocalModels`'s guard would fetch nothing.
            await performLocalModelRefresh()
        } catch is CancellationError {
            pullStatusMessage = "Download cancelled."
            pullTerminalState = .cancelled
            modelPullError = nil
        } catch {
            let rawErrorMessage = error.localizedDescription
            if rawErrorMessage.contains("requires a newer version of Ollama") {
                self.pullErrorRequiresUpdate = true
                self.modelPullError = "This model requires a newer version of Ollama."
            } else {
                self.modelPullError = "Pull failed: \(ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama))"
            }
            pullStatusMessage = "Failed to pull \(trimmedModelName)."
            pullTerminalState = .failed(model: trimmedModelName)
        }
        
        isPullingModel = false
        // Cleared in this same synchronous block so the bridge's next observation sees a finished pull;
        // `DownloadCoordinator` builds its "already pulling" message from `modelToPull`.
        modelToPull = ""
        pullTask = nil
    }

    func cancelPullModel() {
        pullTask?.cancel()
    }

    func removeModel(name: String, baseURL: String) async {
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            self.modelRemoveError = "Model name cannot be empty for removal."
            return
        }
        guard trimmedModelName != self.llmModelName else {
            self.modelRemoveError = "Cannot remove the currently active model. Please select a different model."
            return
        }
        guard self.localModels.contains(where: { $0.name == trimmedModelName }) else {
            self.modelRemoveError = "Model '\(trimmedModelName)' not found in local list."
            return
        }
        guard !isRemovingModel else {
            logger.warning("Already removing a model. Request to remove '\(trimmedModelName)' ignored.")
            return
        }
        guard !isPullingModel else {
            self.modelRemoveError = "Cannot remove model: Another model is currently being pulled."
            return
        }
        guard await OllamaConnect.checkOllamaServerStatus(baseURL: baseURL) else {
            self.modelRemoveError = "Cannot remove model: Ollama server at \(baseURL) is not connected."
            logger.warning("Remove model attempt failed: \(self.modelRemoveError!)")
            self.serverStatus = .disconnected
            return
        }
        self.ollamaBaseURL = baseURL

        isRemovingModel = true
        removingModelName = trimmedModelName
        modelRemoveError = nil
        logger.info("Attempting to remove model: \(trimmedModelName) from \(baseURL).")

        do {
            try await OllamaConnect.removeOllamaModel(name: trimmedModelName, baseURL: baseURL)
            logger.info("Model \(trimmedModelName) removed successfully.")
            
            // FIX: Directly remove the model from the local array to ensure the UI updates instantly.
            // This is more efficient and reliable than reloading all models from the server.
            localModels.removeAll { $0.name == trimmedModelName }
            
            self.removingModelName = nil
        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.modelRemoveError = "Removal of '\(trimmedModelName)' failed: \(errorMessage)"
            logger.error("Failed to remove model \(trimmedModelName): \(error.localizedDescription)")
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost || urlError.code == .networkConnectionLost) {
                self.serverStatus = .disconnected
            }
        }
        isRemovingModel = false
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if modelRemoveError == nil {
             clearRemoveActionStatus()
        }
    }
    
    // MARK: - Resource Management
    // Models are unloaded by name, only those this app used (`unloadOllamaModelsWeUsed()`);
    // unloading all of `/api/ps` would evict another app's models.

    func clearPullActionStatus() {
        pullStatusMessage = ""
        pullTerminalState = nil
        modelPullError = nil
        pullProgress = 0.0
        pullStage = ""
        pullTotalBytes = nil
        pullCompletedBytes = nil
    }

    func clearRemoveActionStatus() {
        modelRemoveError = nil
        removingModelName = nil
    }
    
    func clearAllModelActionStatuses() {
        clearPullActionStatus()
        clearRemoveActionStatus()
    }
}
