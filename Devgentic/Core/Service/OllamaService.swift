// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
// Services/OllamaService.swift
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
        // Use the method form so reasoning-only detection can check against `name`
        // itself — some distilled fine-tunes (e.g. deepseek-r1:14b) report a
        // tool-capable base family (qwen2) but the model name preserves the
        // reasoning-only identity.
        self.cognitiveProfile = response.cognitiveProfile(modelName: name)
        self.supportsThinking = response.supportsThinking
        self.tags = Self.generateTags(from: response, profile: self.cognitiveProfile)
    }

    /// Generates tags from the NAME-AWARE profile (reasoning-only detection needs the
    /// model name — `response.cognitiveCapability` alone misses distilled fine-tunes
    /// like deepseek-r1 whose family reports the tool-capable base architecture).
    /// Vision/Thinking come from the same authoritative detection the pickers bind to.
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

/// Digest-aware local-model refresh shared by `OllamaService` (model manager) and
/// `OllamaModelPickerView` (profile editor). One cheap `/api/tags` + `/api/version`
/// probe decides which models actually need the expensive per-model `/api/show`
/// detection fan-out: unchanged digests reuse the cached `LocalModel`. External
/// `ollama pull`s become visible on the next refresh without re-detecting the whole
/// library, and a daemon upgrade (which can change what `/api/show` reports for the
/// same blob) invalidates the cache wholesale.
enum LocalModelRefresher {

    struct RefreshPlan: Equatable {
        var reusableNames: [String] = []
        var namesToFetch: [String] = []
    }

    /// Pure diff between cached models and a fresh `/api/tags` listing.
    /// - Daemon version change ⇒ everything re-detects.
    /// - Nil digest on either side ⇒ that model re-detects (legacy cache entries and
    ///   failed detail fetches heal on the next pass).
    /// - Cached models absent from `fresh` are dropped (deleted out-of-band).
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

    /// Fetches the current model list, reusing cached detection where digests match.
    /// A failed `/api/show` degrades to a bare `LocalModel` (visible, untagged, nil
    /// digest so the next refresh retries) — a model is never silently dropped.
    static func refresh(
        baseURL: String,
        cached: [LocalModel],
        cachedDaemonVersion: String?
    ) async throws -> (models: [LocalModel], daemonVersion: String?) {
        let entries = try await OllamaConnect.fetchLocalOllamaModelTags(baseURL: baseURL)
        let daemonVersion = await OllamaConnect.fetchDaemonVersion(baseURL: baseURL)
        let versionChanged = daemonVersion != nil && daemonVersion != cachedDaemonVersion

        let plan = planRefresh(cached: cached, fresh: entries, daemonVersionChanged: versionChanged)

        let cachedByName = Dictionary(uniqueKeysWithValues: cached.map { ($0.name, $0) })
        var models: [LocalModel] = plan.reusableNames.compactMap { cachedByName[$0] }

        let digestsByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.digest) })
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

    /// The pull narration that only changes at a LIFECYCLE boundary — start, success, cancel,
    /// failure — never per progress line.
    ///
    /// ⚠️ EXISTS SO AN OBSERVER CAN TRACK IT SAFELY. `pullStatusMessage` is rewritten once per
    /// NDJSON line for the whole of a multi-GB pull, and Observation's `withMutation` fires on
    /// every assignment regardless of equality — so a view model that tracks it runs its full
    /// re-filter and re-sort per progress line. That is the exact regression `pullProgress` is
    /// excluded from the store observer to avoid; this property is the version that is safe to
    /// mirror. Live progress belongs to `DownloadManager`, which the cards read directly.
    var pullTerminalState: PullTerminalState?

    /// How the most recent pull ended, carried as a VALUE rather than as prose.
    ///
    /// ⚠️ THE OUTCOME AND ITS SENTENCE TRAVEL TOGETHER ON PURPOSE. The first version of this was a
    /// bare `String`, and the banner picked its icon from `isPullingModel` — a PHASE, not an
    /// OUTCOME — so "Download cancelled." and "Failed to pull X." both rendered under a green
    /// success tick the moment the pull stopped being in flight. A free-text status cannot answer
    /// "did this succeed?", and any second property holding the answer can drift from the text it
    /// describes. One value, one answer.
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

        /// ⚠️ `.cancelled` is NOT a success. It is not an error either — the user asked for it —
        /// so it gets neither a green tick nor a red triangle.
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

    /// Forces a server check regardless of cooldown. The `UserAction` parameter
    /// is a proof-of-intent token: this method MUST only be called from explicit
    /// user-interaction sites (refresh button, ⌘R shortcut). See `UserAction`.
    ///
    /// History: previously took no argument, which made it trivially misuseable
    /// from VM `init()` — and was in fact misused, hammering the server on every
    /// view recreation. Requiring a `UserAction` surfaces the intent at the
    /// signature and logs the trigger string for traceability.
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

    /// The refresh itself, WITHOUT the "is anything else in flight?" guard.
    ///
    /// ⚠️ EXISTS BECAUSE `pullModel` MUST REFRESH FROM INSIDE ITS OWN WINDOW. `loadLocalModels`'s
    /// guard is there to stop a view appearance racing a pull or a delete — but a pull's own
    /// completion is the one caller that has to refresh while `isPullingModel` is still true, and
    /// it was calling the GUARDED entry point, which returned immediately having fetched nothing.
    ///
    /// Two things depended on that refresh actually happening:
    ///   · the model the user just pulled never appeared in the store grid — the observer fired on
    ///     the `isPullingModel` transition and re-filtered a STALE `localModels`, so it took a
    ///     manual Refresh or a navigate-away-and-back to show up;
    ///   · `DownloadManager` classifies the terminal state by reading
    ///     `OllamaService.shared.localModels` on that same transition, under a comment asserting
    ///     the list is fresh by then. It was not, so `isInstalledNow` was always false and the
    ///     classification fell through to the `progress >= 0.99` heuristic.
    ///
    /// ⚠️ Do NOT "simplify" the call in `pullModel` back to `loadLocalModels()`, and do not clear
    /// `isPullingModel` early to get past the guard instead: the bridge would then observe the
    /// pull finishing BEFORE the list was refreshed, which is the same race from the other side.
    private func performLocalModelRefresh() async {
        isLoadingModels = true
        modelLoadingError = nil
        
        do {
            // Digest-aware refresh: one cheap /api/tags + /api/version probe; the
            // /api/show detection fan-out runs only for new/changed models, so calling
            // this on every view appearance is safe (and is what keeps external
            // `ollama pull`s visible without a manual refresh).
            let result = try await LocalModelRefresher.refresh(
                baseURL: ollamaBaseURL,
                cached: localModels,
                cachedDaemonVersion: lastDaemonVersion
            )
            self.localModels = result.models
            self.lastDaemonVersion = result.daemonVersion

        } catch {
            let errorMessage = ErrorHandling.generateUserFriendlyMessage(for: error, backendType: .ollama)
            self.localModels = []
            self.modelLoadingError = "Failed to load models: \(errorMessage)"
            if let urlError = error as? URLError,
               (urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost) {
                self.serverStatus = .disconnected
            }
        }
        isLoadingModels = false
    }

    func pullModel(name: String, baseURL: String) async {
        let trimmedModelName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelName.isEmpty else {
            logger.error("[DOWNLOAD] Ollama pull refused — empty model name. CONSEQUENCE: nothing is pulled and the caller has already reported success to the user.")
            return
        }
        // Silent return: the caller (DownloadCoordinator) computes its outcome BEFORE
        // dispatching this, so a refusal here surfaced to the user as "Downloading …"
        // with no pull, no record, no sidebar row and no log line. `DownloadCoordinator`
        // now pre-checks `isPullingModel`, but log it here too — this is reachable from
        // any caller.
        guard !isPullingModel else {
            logger.error("[DOWNLOAD] Ollama pull of '\(trimmedModelName)' REFUSED — '\(self.modelToPull)' is already pulling. CONSEQUENCE: the request is dropped; only one Ollama pull runs at a time.")
            return
        }
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

        // ⚠️ THIS SINGLE MISSING ASSIGNMENT WAS THE WHOLE DEFECT. `DownloadManager.bindOllama`
        // tracks both this and `isPullingModel`, and opens a record only on
        // `isPulling && !modelName.isEmpty`; with no assignment site anywhere in the repo that
        // predicate was permanently false, so an Ollama pull produced no DownloadRecord, no
        // sidebar row, no progress bar, no ETA and no Cancel button. Trimmed, because the trimmed
        // form is what the record's `modelIdentifier` must match in `activeRecordMatches`.
        //
        // ⚠️ THE INVARIANT IS "BEFORE THE NEXT SUSPENSION POINT", NOT "BEFORE `isPullingModel`".
        // `ObservationStream`'s onChange schedules `Task { @MainActor … }`, which cannot run until
        // this synchronous block yields — so the bridge's first observation sees the block's FINAL
        // state and never an intermediate one. Swapping these two lines is observationally
        // identical. What is load-bearing is only that `modelToPull` is non-empty by the time this
        // function next awaits.
        // (An earlier version of this comment claimed the relative order mattered. It does not;
        // do not reintroduce a test that pins it, or a `defer`-based cleanup — which would be
        // strictly better, since it also covers a future early return — fails the build.)
        modelToPull = trimmedModelName
        // ⚠️ These two ARE order-sensitive, unlike the pair above, and for a real reason: the
        // observer task scheduled by this block runs at the NEXT suspension point and reads them.
        // Counters left from the PREVIOUS pull would be baked into the new record's size, giving a
        // wrong percentage and ETA. Nothing else clears them on this path.
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
            // ⚠️ The UNGUARDED refresh, and it must stay that way — see
            // `performLocalModelRefresh`. `isPullingModel` is still true here, which is precisely
            // what `loadLocalModels`'s own guard rejects, so that call fetched nothing.
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
        // ⚠️ MUST BE CLEARED IN THIS SAME SYNCHRONOUS BLOCK, so the bridge's next observation sees
        // a finished pull rather than one whose name has outlived it — `DownloadCoordinator` builds
        // its "already pulling" refusal message from `modelToPull`.
        //
        // The ORDER relative to `isPullingModel = false` does not matter: no suspension point
        // separates them, so the observer task cannot run in between and can never see an
        // intermediate pair. (This comment previously claimed clearing first would close the record
        // as CANCELLED — it would not, and the sentence that followed already said why. The real
        // rule is "same block", not "after".)
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
    
    /// Unloads any currently running models from VRAM by checking /api/ps and sending keep_alive: 0.
    /// This ensures that when we switch conversations or close the app, the GPU is freed immediately.
    func unloadModel() async {
        guard let url = URL(string: "\(ollamaBaseURL)/api/ps") else { return }
        
        do {
            // 1. Fetch running models
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Minimal structure to parse /api/ps response
            struct ProcessResponse: Decodable {
                struct Model: Decodable {
                    let name: String
                }
                let models: [ProcessResponse.Model]
            }
            
            let response = try JSONDecoder().decode(ProcessResponse.self, from: data)
            
            if response.models.isEmpty {
                logger.debug("No running models to unload.")
                return
            }
            
            // 2. Unload each found model
            for model in response.models {
                await unloadSpecificModel(name: model.name)
            }
            
        } catch {
            logger.error("Failed to check/unload models: \(error.localizedDescription)")
        }
    }
    
    /// Helper to unload a specific model by name
    private func unloadSpecificModel(name: String) async {
        guard let url = URL(string: "\(ollamaBaseURL)/api/chat") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "model": name,
            "keep_alive": 0
        ]
        
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            logger.info("Model '\(name)' unloaded successfully.")
        } catch {
            logger.error("Failed to unload model '\(name)': \(error.localizedDescription)")
        }
    }
    
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
