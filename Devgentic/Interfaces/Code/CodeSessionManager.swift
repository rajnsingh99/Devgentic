// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeSessionManager.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "CodeSessionManager")

/// Manages the Code interface's singleton profile persisted in SwiftData: model, project selection and project folder.
/// Per-project settings live in `CodeQuickSettingsStore`; the row holds only the current project's copy, never deleted.
/// Project knowledge (`AGENTS.md`, memory) is read per run; this type only caches a copy for the Context gauge.
@Observable @MainActor
final class CodeSessionManager {

    // MARK: - Persisted Profile Handle

    /// UUID of the singleton code profile in SwiftData.
    /// Persisted to UserDefaults so we can find it across launches.
    private(set) var codeProfileID: UUID?

    // MARK: - Local Caches (for fast UI reads without fetching from store)

    private(set) var provider: ApiProvider = .ollama
    private(set) var modelName: String = ""
    private(set) var apiKey: String? = nil
    private(set) var baseURL: String? = nil
    /// The model's detected metadata — its trained window is what "Context size" is offered up to.
    private(set) var modelMetadata: ModelMetadata? = nil

    /// The selected model as a config value, for callers that ask model questions (e.g. its window).
    var currentProviderConfig: ProviderConfig {
        ProviderConfig(apiProvider: provider, modelName: modelName, modelMetadata: modelMetadata)
    }
    private(set) var projectPath: URL? = nil

    /// Most-recently-used project folders. Persisted across launches so the folder
    /// selector can suggest them without re-running NSOpenPanel.
    private(set) var recentProjectPaths: [URL] = []

    /// Max entries kept in `recentProjectPaths`. Older entries drop off the tail.
    private static let maxRecentPaths = 8

    /// Providers that support agentic tool use in Code mode.
    static let supportedProviders: [ApiProvider] = [.ollama, .mlx, .anthropic, .openAI, .google]

    // MARK: - Computed

    /// Whether the Code interface has enough configuration to send messages.
    var isConfigured: Bool {
        !modelName.isEmpty && projectPath != nil
    }

    /// Display string for the project path (truncated for toolbar).
    var projectDisplayName: String {
        guard let path = projectPath else { return "Project" }
        return "~/\(path.lastPathComponent)"
    }

    /// Display string for the model selector button.
    var modelDisplayName: String {
        if modelName.isEmpty { return "Select Model" }
        let providerPrefix: String
        switch provider {
        case .ollama:           providerPrefix = "Ollama"
        case .mlx:              providerPrefix = "MLX"
        case .anthropic:        providerPrefix = "Anthropic"
        case .openAI:           providerPrefix = "OpenAI"
        case .google:           providerPrefix = "Google"
        case .openRouter:       providerPrefix = "OpenRouter"
        case .openAICompatible: providerPrefix = "Custom"
        }
        return "\(providerPrefix) \u{00B7} \(modelName)"
    }

    // MARK: - Picker State (shared with UI)

    /// Drives the model picker popover from both the button and send-intercept.
    var showModelPicker: Bool = false

    /// Drives the quick-settings popover — from its toolbar button, and from the context gauge's
    /// "Raise context size" when the prompt and tools fill most of the window.
    var showQuickSettings: Bool = false

    // MARK: - Project knowledge (cached for display)

    /// What the next run will append to the prompt for this project (`AGENTS.md` and the memory listing), or nil if none.
    /// A display copy for the Context gauge and inspector; runs read the disk themselves.
    var projectKnowledgeContent: String?

    /// How many memory entries the open project has, for the inspector button.
    var projectMemoryEntryCount: Int = 0

    @ObservationIgnored private var memoryObserver: NSObjectProtocol?

    // MARK: - Private

    private static let profileIDKey = "devgentic.codeProfileID"
    /// Per-project settings live in their OWN UserDefaults key: the one profile row can only hold
    /// the current project's copy — see `CodeQuickSettingsStore`.
    private static let quickSettingsKey = CodeQuickSettingsStore.defaultsKey
    private static let recentPathsKey = "devgentic.codeRecentProjectPaths"

    // Why: an explicit flag, not `modelName.isEmpty`: `resetSession()` empties the caches on purpose and must not be undone.
    /// Set when `init()` kept the stored handle but could not read the row because the store threw.
    /// The first `ensureCodeProfile()` that can read it fills the caches.
    @ObservationIgnored private var needsHydrationFromStore = false

    // Why: tests must not clear `UserDefaults.standard`: under the test host it is the shipping app's domain.
    /// Where the profile handle and recent-paths cache live; injectable so a test can clear the handle.
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Restore cached recent project paths
        loadRecentProjectPaths()

        // Restore profile ID
        if let uuidString = self.defaults.string(forKey: Self.profileIDKey),
           let uuid = UUID(uuidString: uuidString) {
            // A thrown fetch is not a deleted row: only a genuine nil may clear the key, otherwise a transient store error
            // orphans the row and the next `ensureCodeProfile()` creates a duplicate profile.
            do {
                if let profile = try BackendProfileStore.shared.fetchProfile(byId: uuid) {
                    self.codeProfileID = uuid
                    hydrateFromProfile(profile)
                    logger.info("[CODE_PROFILE] Restored profile \(uuid.uuidString) — provider: \(self.provider.rawValue), model: \(self.modelName)")
                    // Reconcile even after a successful restore: adoption only collapses duplicates when the handle was lost.
                    // Once per launch, not per action; the rows cannot multiply mid-session.
                    collapseDuplicateCodeProfiles(keeping: uuid, from: sharedCodeProfilesOnDisk())
                } else {
                    // Genuinely absent — deleted out from under us. Clearing is correct here.
                    self.defaults.removeObject(forKey: Self.profileIDKey)
                    logger.warning("[CODE_PROFILE] Stale profile ID \(uuid.uuidString) — row not found, handle cleared. CONSEQUENCE: the next Code-mode action adopts a surviving code row if one is on disk, and only creates a new profile when there is none.")
                }
            } catch {
                self.codeProfileID = uuid
                self.needsHydrationFromStore = true
                logger.error("[CODE_PROFILE] Could not read profile \(uuid.uuidString): \(error.localizedDescription). CONSEQUENCE: the handle is KEPT rather than cleared, so the row is not orphaned; the model and project caches stay empty until the first Code-mode action re-reads them, so the toolbar reads 'Select Model' until then.")
            }
        } else {
            logger.info("[CODE_PROFILE] Initialized with no stored handle — an existing code profile is adopted on first use if one is on disk.")
        }

        // If a project path was restored, load its knowledge and ensure it's in recents
        // (covers first launch after this feature ships for existing users).
        if let restored = projectPath {
            rememberRecentPath(restored)
            refreshProjectKnowledge()
            // Restored across launches — publish it too, or the roots list would only be
            // populated by an explicit folder change during the session.
            Task { await MCPRootsProvider.setCodeProjectRoot(restored) }
        }

        // A `remember`/`forget` (or an Undo) changes what the next run is told; refresh the
        // display copy now rather than at the next send, so the gauge and inspector are current.
        memoryObserver = NotificationCenter.default.addObserver(
            forName: .projectMemoryDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let changedPath = note.object as? String
            MainActor.assumeIsolated {
                guard let self, let open = self.projectPath?.standardizedFileURL.path else { return }
                guard changedPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.path == open }) ?? true else { return }
                self.refreshProjectKnowledge()
            }
        }
    }

    // MARK: - Profile Lifecycle

    // Why: a lost handle must adopt, never create: a duplicate profile has no removal path and splits tool enablement.
    /// Returns the singleton code profile's ID, adopting the one already on disk before creating a new one.
    /// The store is authoritative; the UserDefaults handle is only a cache, so a lost handle self-heals.
    @discardableResult
    func ensureCodeProfile() -> UUID {
        // 1. Fast path: the handle still resolves to a row.
        if let id = codeProfileID {
            do {
                if let profile = try BackendProfileStore.shared.fetchProfile(byId: id) {
                    if needsHydrationFromStore {
                        hydrateFromProfile(profile)
                        needsHydrationFromStore = false
                        logger.info("[CODE_PROFILE] Hydrated \(id.uuidString) on first use after an unreadable launch read — model: '\(self.modelName.isEmpty ? "(none)" : self.modelName)'.")
                    }
                    return id
                }
            } catch {
                // Return, do not fall through to create: on an unreadable store the adopt scan fails too,
                // and a rival row would be written the moment the store recovered.
                logger.error("[CODE_PROFILE] Could not verify profile \(id.uuidString): \(error.localizedDescription). CONSEQUENCE: the existing handle is returned unverified instead of creating a second 'Code Session'; a save against it fails loudly if the row really is gone.")
                return id
            }
        }

        // 2. Adopt path: the handle is missing or stale, but the store may still hold the
        //    singleton. Claim it rather than minting a rival.
        let existingCodeProfiles = sharedCodeProfilesOnDisk()

        if let adopted = existingCodeProfiles.sorted(by: Self.adoptionPreference).first {
            codeProfileID = adopted.id
            self.defaults.set(adopted.id.uuidString, forKey: Self.profileIDKey)
            hydrateFromProfile(adopted)
            needsHydrationFromStore = false
            logger.info("[CODE_PROFILE] Adopted existing code profile \(adopted.id.uuidString) — model: '\(self.modelName.isEmpty ? "(none)" : self.modelName)'. CONSEQUENCE: the lost handle is restored in place of creating a duplicate 'Code Session'.")
            collapseDuplicateCodeProfiles(keeping: adopted.id, from: existingCodeProfiles)
            return adopted.id
        }

        // 3. Create a skeleton code profile with empty model (lenient validation allows this)
        let providerConfig = ProviderConfig(
            apiProvider: provider,
            modelName: ""
        )

        let agentConfig = AgentConfig(
            llmConfig: providerConfig,
            tools: CodeToolPreset.defaultTools,
            maxIterations: Self.presetMaxIterations,
            executionTimeout: Self.presetExecutionTimeout,
            retryPolicy: RetryPolicy(maxRetries: 3, backoffStrategy: .exponential),
            errorRecovery: ErrorRecovery(
                onToolFailure: .fallbackPrompt,
                onIterationExhaustion: .synthesizeBestEffort
            ),
            capabilities: AgentCapabilities(),
            historyStrategy: .pointer
        )

        let snapshot = BackendProfileSnapshot(
            displayName: "Code Session",
            details: .code(agentConfig),
            fileContextStrategy: .stateless
        )

        do {
            try BackendProfileStore.shared.saveProfile(snapshot)
            codeProfileID = snapshot.id
            self.defaults.set(snapshot.id.uuidString, forKey: Self.profileIDKey)
            logger.info("[CODE_PROFILE] Created code profile \(snapshot.id.uuidString) — no existing code row was on disk to adopt.")
            return snapshot.id
        } catch {
            logger.error("[CODE_PROFILE] Failed to create code profile: \(error.localizedDescription). CONSEQUENCE: an unbacked ID is returned, so this Code session cannot persist a model or project folder until a later action succeeds.")
            return UUID() // Should not happen — lenient validation for inserts
        }
    }

    // MARK: - Config Updates

    // MARK: - Quick Settings (per project)

    // Why: reads through to UserDefaults on every access: a cache would go stale on project switch.
    /// Execution overrides for the current project folder, or the preset defaults when it has none or no folder is open.
    var quickSettings: CodeQuickSettings {
        CodeQuickSettingsStore.settings(for: projectPath?.path, defaults: defaults)
    }

    /// Persists quick settings for the current project and pushes them onto the live profile.
    /// The profile write applies a change made between sends; the per-send refresh re-applies them anyway.
    func updateQuickSettings(_ settings: CodeQuickSettings) {
        guard let path = projectPath?.path else {
            logger.warning("[CODE_SETTINGS] Quick settings changed with no project selected. CONSEQUENCE: the change is dropped — settings are scoped per project and there is nothing to attach them to.")
            return
        }

        // The popover commits on appear and again on dismiss, so most calls carry values already stored; skip those writes.
        guard settings != CodeQuickSettingsStore.settings(for: path, defaults: defaults) else {
            logger.debug("[CODE_SETTINGS] Quick settings for '\(URL(fileURLWithPath: path).lastPathComponent)' unchanged — nothing saved.")
            return
        }

        CodeQuickSettingsStore.save(settings, for: path, defaults: defaults, now: Date())
        logger.info("[CODE_SETTINGS] Saved quick settings for '\(URL(fileURLWithPath: path).lastPathComponent)' — maxIterations: \(settings.maxIterations.map(String.init) ?? "no cap"), timeout: \(settings.executionTimeout.map { String(Int($0)) } ?? "default")s, thinking: \(settings.thinkingEnabled.map(String.init) ?? "default"), memory suggestions: \(settings.suggestMemories == true ? "on" : "off").")

        applyQuickSettingsToProfile(settings)
    }

    // Why: tool confirmations go through `mergePresetTools`: a direct write could resurrect a tool the preset dropped.
    /// Writes the execution-shaped fields of `settings` onto the persisted `.code` profile.
    private func applyQuickSettingsToProfile(_ settings: CodeQuickSettings) {
        guard let profileID = codeProfileID,
              var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
              case .code(var agentConfig) = profile.details else { return }

        let before = profile.details
        Self.apply(settings, to: &agentConfig)
        profile.details = .code(agentConfig)
        guard profile.details != before else { return }

        do {
            try BackendProfileStore.shared.saveProfile(profile)
        } catch {
            logger.error("[CODE_SETTINGS] Failed to push quick settings onto profile \(profileID.uuidString): \(error.localizedDescription). CONSEQUENCE: they remain saved in UserDefaults and are re-applied on the next send, so the loss is one send at most.")
        }
    }

    // Why: the circuit breaker does not stop a Code run: `.fallbackPrompt` downgrades every trigger to a warning and a nudge.
    /// The preset iteration cap an untouched project runs with: none (`AgentExecutionDefaults.uncapped`).
    /// The cap is opt-in per project; a run without one is still bounded by `presetExecutionTimeout`.
    static let presetMaxIterations = AgentExecutionDefaults.uncapped

    /// The range the quick settings accept for a typed iteration cap; a stored value outside it is clamped at `apply`.
    static let iterationCapRange = 10...1000

    // Why: keep above `BatchCommandTool.maxTimeoutSeconds` (1800): else the turn aborts before the tool returns partial output.
    /// Bounds the compute of a whole turn: every iteration and tool call, excluding time parked awaiting a human.
    /// With no iteration cap by default, this is the only automatic stop for a Code run.
    static let presetExecutionTimeout: TimeInterval = 3600

    // Why: the agent preset's 8,192 is too small for Code's prompt plus tools; Ollama silently drops the start of the prompt.
    /// Code's default context window: the model's own, capped here.
    /// KV-cache memory grows with the window, so the cap stops a 128K-trained model claiming many GB by default;
    /// the per-project Context size can exceed it.
    static let presetContextCap = 32_768

    /// The window a Code run on `llm` should use — nil leaves Ollama's usual ladder in charge.
    static func contextTokens(_ settings: CodeQuickSettings, for llm: ProviderConfig) -> Int? {
        guard llm.apiProvider == .ollama else { return nil }
        if let chosen = settings.contextTokens, chosen > 0 { return chosen }
        return EffectiveContextWindow.trainedWindow(for: llm).map { min($0, presetContextCap) }
    }

    /// Writes a `CodeQuickSettings` onto an `AgentConfig`: the one place quick settings become config fields.
    static func apply(_ settings: CodeQuickSettings, to agentConfig: inout AgentConfig) {
        // Always assign, never skip when nil: an unset override must restore the preset, not leave the last value in place,
        // or Remove followed by Reset to defaults could never bring the preset back.
        agentConfig.maxIterations = settings.maxIterations.map {
            min(max($0, iterationCapRange.lowerBound), iterationCapRange.upperBound)
        } ?? presetMaxIterations

        // Tri-state, and the three states are genuinely different: nil = inherit the preset,
        // 0 = the user explicitly chose "No limit", anything else = that budget.
        switch settings.executionTimeout {
        case .none:            agentConfig.executionTimeout = presetExecutionTimeout
        case .some(let t) where t > 0: agentConfig.executionTimeout = t
        case .some:            agentConfig.executionTimeout = nil   // explicit "No limit"
        }

        agentConfig.llmConfig.thinkingEnabled = settings.thinkingEnabled ?? false
        agentConfig.llmConfig.numCtxOverride = contextTokens(settings, for: agentConfig.llmConfig)
        agentConfig.tools = mergePresetTools(
            preset: CodeToolPreset.defaultTools,
            existing: agentConfig.tools
        )
    }

    /// Updates the provider selection. Lightweight — only clears local model cache.
    /// The profile is not written until a model is actually selected.
    func updateProvider(_ provider: ApiProvider) {
        self.provider = provider
        self.modelName = ""
        self.modelMetadata = nil
        self.apiKey = nil
        logger.info("Provider updated to \(provider.rawValue)")
    }

    /// Updates the model on the persisted code profile with full cognitive data.
    func updateModel(
        _ modelName: String,
        provider: ApiProvider,
        cognitiveProfile: CognitiveProfile,
        apiKey: String?,
        baseURL: String?,
        thinkingEnabled: Bool = false
    ) {
        let profileID = ensureCodeProfile()

        guard var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
              case .code(var agentConfig) = profile.details else {
            logger.error("updateModel: failed to fetch code profile")
            return
        }

        let detailsBefore = profile.details

        // Build ProviderConfig with full cognitive data
        agentConfig.llmConfig = ProviderConfig(
            apiProvider: provider,
            modelName: modelName,
            apiKey: apiKey,
            baseURL: baseURL,
            cognitiveCapability: cognitiveProfile.capability,
            modelDialect: cognitiveProfile.dialect,
            modelMetadata: cognitiveProfile.metadata,
            chatTemplateSource: cognitiveProfile.chatTemplateSource,
            stopSequences: cognitiveProfile.stopSequences,
            thinkingEnabled: thinkingEnabled
        )
        // A new model means a new trained window — the Code default follows it now, not at the
        // next send, so the gauge prices the model the user just picked.
        agentConfig.llmConfig.numCtxOverride = Self.contextTokens(quickSettings, for: agentConfig.llmConfig)

        // The key goes to the provider's Keychain slot so another project's model on this provider finds it again.
        // Saved before the profile: a shared-key provider's profile keeps the shared key, so the new key must already be there.
        CodeProviderKeys.remember(apiKey, for: provider)

        profile.details = .code(agentConfig)

        do {
            if profile.details == detailsBefore {
                logger.debug("[CODE_PROFILE] Model '\(modelName)' re-picked unchanged — no profile write.")
            } else {
                try BackendProfileStore.shared.saveProfile(profile)
            }
            // Update local caches
            self.provider = provider
            self.modelName = modelName
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.modelMetadata = cognitiveProfile.metadata
            logger.info("Model updated to \(modelName) (provider: \(provider.rawValue), capability: \(cognitiveProfile.capability.rawValue), dialect: \(cognitiveProfile.dialect.rawValue), thinking: \(thinkingEnabled))")
            if let path = projectPath?.path {
                captureProject(path, from: agentConfig, reason: "model picked")
            } else {
                logger.info("[CODE_PROJECT] Model '\(modelName)' picked with no project selected. CONSEQUENCE: it is the last-used model every project without its own starts with; the first folder opened remembers it.")
            }
        } catch {
            logger.error("Failed to save model update: \(error.localizedDescription)")
        }
    }

    /// Opens `url` as the current project: the project's own model, tools and limits are loaded
    /// onto the profile, after the project being left has its copy captured.
    func updateProjectPath(_ url: URL) {
        let previous = projectPath
        let isSwitch = previous.map { !$0.sameLocation(as: url) } ?? false
        self.projectPath = url
        logger.info("[CODE_PROJECT] Open '\(url.lastPathComponent)' (\(url.path)) — from: \(previous.map { "'\($0.lastPathComponent)'" } ?? "no folder"), \(isSwitch ? "switching projects" : (previous == nil ? "no folder was open" : "same folder re-opened")).")

        // Publishes the folder as an MCP root so filesystem-style servers get a workspace boundary; connected servers are
        // notified immediately, so switching project re-scopes them without a reconnect.
        Task { await MCPRootsProvider.setCodeProjectRoot(url) }

        let profileID = ensureCodeProfile()
        if var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
           case .code(var agentConfig) = profile.details {
            let before = profile.details
            if isSwitch, let previous { captureProject(previous.path, from: agentConfig, reason: "switching to '\(url.lastPathComponent)'") }
            loadProject(url.path, into: &agentConfig, leavingAnotherProject: isSwitch)
            agentConfig.projectPath = url.path
            profile.details = .code(agentConfig)
            do {
                if profile.details == before {
                    logger.debug("[CODE_PROFILE] '\(url.lastPathComponent)' already on the profile — no write.")
                } else {
                    try BackendProfileStore.shared.saveProfile(profile)
                }
            } catch {
                // Store validation refuses a row with no model — the state before a first model is
                // ever picked. The caches below still switch, and the next send re-applies it all.
                logger.warning("[CODE_PROFILE] Could not write project '\(url.lastPathComponent)' onto the profile: \(error.localizedDescription). CONSEQUENCE: the profile row keeps its previous folder until the next successful write (a model pick or a send); the session already uses the new folder.")
            }
            hydrateModelCaches(from: agentConfig.llmConfig)
            logger.info("[CODE_PROJECT] '\(url.lastPathComponent)' now runs with model: \(self.modelName.isEmpty ? "(none selected)" : "\(self.provider.rawValue)/\(self.modelName)"), \(agentConfig.tools.count) tool(s), maxIterations: \(agentConfig.maxIterations.map(String.init) ?? "unbounded").")
        } else {
            logger.error("[CODE_PROFILE] Could not read Code profile \(profileID.uuidString) while opening '\(url.lastPathComponent)'. CONSEQUENCE: the folder is open but its remembered model and tools were NOT loaded, and \(previous.map { "'\($0.lastPathComponent)'" } ?? "the previous state") was not captured; the next send applies this project's limits, but tools and model stay whatever the row held.")
        }

        rememberRecentPath(url)
        refreshProjectKnowledge()
    }

    // Why: without the restore, a session would read and write whichever project folder happens to be open.
    /// The result of putting a Code conversation's own folder back when it is selected.
    enum ConversationProjectOutcome: Equatable {
        case restored, alreadyOpen, noRecordedFolder, folderMissing
    }

    @discardableResult
    func openProject(forConversationPath path: String?) -> ConversationProjectOutcome {
        guard let path, !path.isEmpty else {
            logger.info("[CODE_PROJECT] Selected conversation has no recorded folder (from before folders were recorded, or never sent). CONSEQUENCE: \(self.projectPath.map { "'\($0.lastPathComponent)'" } ?? "no folder") stays open, and the conversation is bound to whatever folder its next send runs in.")
            return .noRecordedFolder
        }
        let url = URL(fileURLWithPath: path)
        if let current = projectPath, current.sameLocation(as: url) {
            logger.debug("[CODE_PROJECT] Selected conversation's folder '\(url.lastPathComponent)' is already open.")
            return .alreadyOpen
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.warning("[CODE_PROJECT] The selected conversation's folder '\(path)' no longer exists. CONSEQUENCE: the current folder stays open; the conversation can be read, but sending from it is refused rather than run against another project's files.")
            return .folderMissing
        }
        updateProjectPath(url)
        logger.info("[CODE_PROJECT] Reopened '\(url.lastPathComponent)' for the selected conversation.")
        return .restored
    }

    // MARK: - Per-Project State

    /// Loads `path`'s remembered model, tools and limits onto `agentConfig`.
    /// A never-captured project gets the preset tools when another project is being left, so it inherits none of its tools.
    /// With no project open it adopts what is on the row, so tools enabled before picking a folder are kept.
    private func loadProject(_ path: String, into agentConfig: inout AgentConfig, leavingAnotherProject: Bool) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let state = CodeQuickSettingsStore.projectState(for: path, defaults: defaults) {
            Self.restore(state, into: &agentConfig)
            logger.info("[CODE_PROJECT] Loaded '\(name)' — model: \(state.model.map { "\($0.apiProvider.rawValue)/\($0.modelName)" } ?? "(none remembered — last used carries over)"), extra tools: [\(state.extraTools.map(\.name).joined(separator: ", "))], preset overrides: [\(state.presetToolOverrides.keys.sorted().joined(separator: ", "))].")
        } else if leavingAnotherProject {
            agentConfig.tools = CodeToolPreset.defaultTools
            logger.info("[CODE_PROJECT] '\(name)' opened for the first time — preset tools and limits; the last-used model carries over.")
        } else {
            logger.info("[CODE_PROJECT] '\(name)' has nothing remembered yet and no other project was left — adopting the tools already on the profile (enabled on the welcome screen, or this folder's own).")
        }
        Self.apply(CodeQuickSettingsStore.settings(for: path, defaults: defaults), to: &agentConfig)
    }

    /// A remembered project's tools and model, onto `agentConfig`.
    static func restore(_ state: CodeProjectState, into agentConfig: inout AgentConfig) {
        agentConfig.tools = tools(restoring: state)
        if let model = state.model {
            agentConfig.llmConfig = restoredModel(model, replacing: agentConfig.llmConfig)
        }
    }

    // MARK: - A run in a conversation's own project

    /// The prompt a Code run in `projectPath` is stored with. The project's own knowledge is NOT
    /// part of it: `AgentConnect` appends `AGENTS.md` and the memory listing when the run starts.
    static func instructions(forProject projectPath: String, apiProvider: ApiProvider, tier: ModelTier?) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // CodeSystemPrompt picks the XML or markdown variant by provider (Claude → XML, others →
        // markdown).
        return CodeSystemPrompt.production(
            projectPath: projectPath,
            projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            currentDate: dateFormatter.string(from: Date()),
            apiProvider: apiProvider,
            wording: CodeSystemPrompt.Wording.forTier(tier)
        )
    }

    // Why: one profile holds the open project; a wake, scheduled run or resume for another conversation needs its own.
    /// The Code profile as a run in `conversationProjectPath` must see it, built in memory without touching the row.
    /// Returns `profile` unchanged when it is not Code, the conversation has no folder, or its folder is already on the row.
    static func profile(_ profile: BackendProfileSnapshot, forConversationProject conversationProjectPath: String?,
                        defaults: UserDefaults = .standard) -> BackendProfileSnapshot {
        guard case .code(let base) = profile.details,
              let target = CodeQuickSettingsStore.normalizedKey(conversationProjectPath) else { return profile }
        let open = CodeQuickSettingsStore.normalizedKey(base.projectPath)
        guard open != target else { return profile }

        var config = base
        if let state = CodeQuickSettingsStore.projectState(for: target, defaults: defaults) {
            restore(state, into: &config)
        } else {
            config.tools = CodeToolPreset.defaultTools
        }
        apply(CodeQuickSettingsStore.settings(for: target, defaults: defaults), to: &config)
        config.instructions = instructions(forProject: target, apiProvider: config.llmConfig.apiProvider,
                                           tier: config.llmConfig.modelMetadata?.tier)
        config.projectPath = target

        let name = URL(fileURLWithPath: target).lastPathComponent
        if FileManager.default.fileExists(atPath: target) {
            logger.info("[CODE_PROJECT] Run bound to '\(name)' while \(open.map { "'\(URL(fileURLWithPath: $0).lastPathComponent)'" } ?? "no folder") is open — using '\(name)''s own folder, prompt, tools (\(config.tools.count)) and limits (maxIterations: \(config.maxIterations.map(String.init) ?? "unbounded")), model \(config.llmConfig.modelName). CONSEQUENCE: the open project is not touched.")
        } else {
            logger.warning("[CODE_PROJECT] Run bound to '\(name)', whose folder no longer exists at \(target). CONSEQUENCE: it stays confined to that path rather than running in the open project; tools that touch files will fail.")
        }

        var rebound = profile
        rebound.details = .code(config)
        return rebound
    }

    /// Records what `agentConfig` runs with as `path`'s project state. `reason` is for the log.
    private func captureProject(_ path: String, from agentConfig: AgentConfig, reason: String) {
        let state = Self.projectState(capturing: agentConfig)
        logger.debug("[CODE_PROJECT] Capturing '\(URL(fileURLWithPath: path).lastPathComponent)' (\(reason)) — model: \(state.model?.modelName ?? "(none)"), \(state.extraTools.count) extra tool(s), \(state.presetToolOverrides.count) preset override(s).")
        CodeQuickSettingsStore.saveProjectState(state, for: path, defaults: defaults, now: Date())
    }

    /// The row's tools and model as a delta against the preset.
    static func projectState(capturing agentConfig: AgentConfig) -> CodeProjectState {
        let presetByKey = Dictionary(CodeToolPreset.defaultTools.map { (toolKey($0), $0) },
                                     uniquingKeysWith: { first, _ in first })
        var state = CodeProjectState()
        for tool in agentConfig.tools {
            if let preset = presetByKey[toolKey(tool)] {
                if let override = CodeToolOverride(preset: preset, current: tool) {
                    state.presetToolOverrides[tool.name] = override
                }
            } else {
                state.extraTools.append(tool)
            }
        }
        var model = agentConfig.llmConfig
        model.apiKey = nil
        state.model = model.modelName.isEmpty ? nil : model
        return state
    }

    /// The tool list a captured project runs with — the inverse of `projectState(capturing:)`.
    static func tools(restoring state: CodeProjectState) -> [Tool] {
        CodeToolPreset.defaultTools.map { state.presetToolOverrides[$0.name]?.applied(to: $0) ?? $0 }
            + state.extraTools
    }

    /// A project's remembered model, with a key found for it: the row's own when the provider is
    /// unchanged, otherwise the provider's Keychain slot (`CodeProviderKeys`).
    static func restoredModel(_ model: ProviderConfig, replacing current: ProviderConfig) -> ProviderConfig {
        var restored = model
        let sameProvider = current.apiProvider == model.apiProvider
        let rowKey = sameProvider ? current.apiKey : nil
        restored.apiKey = rowKey ?? CodeProviderKeys.key(for: model.apiProvider)

        // Never the key itself — only where it came from.
        if restored.apiKey == nil && providerNeedsKey(model.apiProvider) {
            logger.warning("[CODE_KEYS] Restored \(model.apiProvider.rawValue)/\(model.modelName) with NO API key — none on the profile and none in the provider's Keychain slot. CONSEQUENCE: the first send fails authentication until a key is entered in the model picker.")
        } else if restored.apiKey != nil {
            let source = rowKey != nil ? "the profile (same provider)" : "the \(model.apiProvider.rawValue) Keychain slot"
            logger.info("[CODE_KEYS] Restored \(model.apiProvider.rawValue)/\(model.modelName) — key from \(source).")
        }
        return restored
    }

    /// Local providers run without a key; a missing one only matters for cloud providers.
    static func providerNeedsKey(_ provider: ApiProvider) -> Bool {
        switch provider {
        case .ollama, .mlx, .openAICompatible: return false
        case .anthropic, .openAI, .google, .openRouter: return true
        }
    }

    // MARK: - Recent Project Paths

    /// Move-to-front an entry in `recentProjectPaths`, dropping missing folders and
    /// capping the list. Persists to UserDefaults.
    private func rememberRecentPath(_ url: URL) {
        let standardized = url.standardizedFileURL
        // Compares with `sameLocation`, not `!=`: a symlinked project folder diverges under `standardizedFileURL`,
        // which never resolves symlinks, and would add a duplicate row to Recent Projects.
        var updated = recentProjectPaths.filter { !$0.sameLocation(as: standardized) }
        updated.insert(standardized, at: 0)
        // Drops entries whose folders are gone from disk.
        updated = updated.filter { FileManager.default.fileExists(atPath: $0.path) }
        if updated.count > Self.maxRecentPaths {
            updated = Array(updated.prefix(Self.maxRecentPaths))
        }
        recentProjectPaths = updated
        self.defaults.set(updated.map(\.path), forKey: Self.recentPathsKey)
    }

    private func loadRecentProjectPaths() {
        guard let raw = self.defaults.array(forKey: Self.recentPathsKey) as? [String] else { return }
        recentProjectPaths = raw
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Refreshes the code profile's instructions with the latest system prompt, and the display
    /// copy of the project's knowledge. Called before each send.
    func refreshInstructionsOnProfile() {
        guard let profileID = codeProfileID,
              var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
              case .code(var agentConfig) = profile.details else {
            logger.warning("refreshInstructionsOnProfile: no code profile to refresh")
            return
        }

        // What is on disk right now. Compared against the rebuilt value below so an unchanged
        // send does not pay for a write — see the guard at the end of this function.
        let detailsBeforeRefresh = profile.details

        let projectPathStr = projectPath?.path ?? "/"
        let projectName = projectPath?.lastPathComponent ?? "?"

        refreshProjectKnowledge()
        let tier = agentConfig.llmConfig.modelMetadata?.tier
        let instructions = Self.instructions(forProject: projectPathStr,
                                             apiProvider: agentConfig.llmConfig.apiProvider,
                                             tier: tier)

        agentConfig.instructions = instructions
        agentConfig.projectPath = projectPathStr

        // Quick settings are re-applied on every send: the row is shared by every project, so this guarantees the run uses
        // this project's limits. `apply` also performs the tool merge; the capture below records Tool Library changes.
        let settings = CodeQuickSettingsStore.settings(for: projectPathStr, defaults: defaults)
        Self.apply(settings, to: &agentConfig)
        // Logged on every send, not only for overrides: a maximum-iterations stop is diagnosable only against the cap in force.
        if let path = projectPath?.path { captureProject(path, from: agentConfig, reason: "send") }
        let limitSource = settings.isDefault ? "preset" : "per-project override"
        logger.info("[CODE_SETTINGS] '\(projectName)' runs with maxIterations: \(AgentExecutionDefaults.describe(agentConfig.maxIterations)), timeout: \(agentConfig.executionTimeout.map { "\(Int($0))s" } ?? "none"), context: \(agentConfig.llmConfig.numCtxOverride.map { "\($0) tokens (\(settings.contextTokens == nil ? "Code default" : "chosen"))" } ?? "provider default") — source: \(limitSource). CONSEQUENCE: an iteration-cap or timeout termination in this run is against these exact values.")

        profile.details = .code(agentConfig)

        // Skips the write when nothing changed (this runs on every send). The guard lives here, not in the store: the `details`
        // setter also moves the API key and rewrites denormalized columns, which a central skip would bypass.
        guard profile.details != detailsBeforeRefresh else {
            logger.debug("[CODE] Instructions unchanged for '\(projectName)' — skipping the profile write. CONSEQUENCE: no SwiftData write and no lastSelected bump this send; the row already holds these exact instructions, project path and quick settings.")
            return
        }

        do {
            try BackendProfileStore.shared.saveProfile(profile)
            logger.info("[CODE] Instructions refreshed — project: '\(projectName)', instructions: \(instructions.count) chars, wording: \(CodeSystemPrompt.Wording.forTier(tier).rawValue) (model tier \(tier?.rawValue ?? "unknown")). CONSEQUENCE: tiny and small models get the compact wording of the same rules.")
        } catch {
            // Store validation rejects a profile with no model, so this fires for a folder with no model yet; harmless since
            // `attemptSend` refuses to send without one, but the write did nothing, so the log says what was lost.
            logger.error("[CODE] Failed to refresh instructions: \(error.localizedDescription). CONSEQUENCE: the profile keeps its previous instructions, project path and quick settings for now; all of them are re-applied on the next successful refresh, so nothing is permanently lost.")
        }
    }

    // Why: the row is reset, never deleted: per-tool settings and enabled MCP tools live on it.
    /// Home: the session goes back to no folder and the row goes back to the preset.
    /// The project being left is captured first so its settings return when reopened; the model is kept as the fallback.
    func resetSession() {
        projectKnowledgeContent = nil
        projectMemoryEntryCount = 0

        let leaving = projectPath
        // Uses `ensureCodeProfile()`, not `codeProfileID`: the handle resolves lazily, so Home pressed before any Code action
        // would reset nothing and the adoption that follows would re-hydrate the stale folder.
        let profileID = ensureCodeProfile()
        if var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
           case .code(var agentConfig) = profile.details {
            if let path = leaving?.path { captureProject(path, from: agentConfig, reason: "Home") }
            agentConfig.projectPath = nil
            agentConfig.tools = CodeToolPreset.defaultTools
            Self.apply(.default, to: &agentConfig)
            profile.details = .code(agentConfig)
            do {
                try BackendProfileStore.shared.saveProfile(profile)
            } catch {
                logger.error("[CODE_PROFILE] Could not reset profile \(profileID.uuidString) to the preset: \(error.localizedDescription). CONSEQUENCE: the row keeps the previous project's tools until the next folder is opened, which replaces them; that project's copy was already captured, so nothing is lost.")
            }
        } else {
            logger.warning("[CODE_PROFILE] Home could not read Code profile \(profileID.uuidString). CONSEQUENCE: \(leaving.map { "'\($0.lastPathComponent)' was NOT captured — tool changes since its last send or switch are lost" } ?? "nothing to capture"); the folder is still cleared.")
        }

        projectPath = nil
        logger.info("[CODE_PROFILE] Home — left \(leaving.map { "'\($0.lastPathComponent)'" } ?? "no folder"); profile \(self.codeProfileID?.uuidString ?? "(none)") KEPT and reset to the preset tools and limits; model kept as last used: \(self.modelName.isEmpty ? "(none)" : self.modelName).")
    }

    // MARK: - Duplicate Collapse

    // Why: `!isNodeOwned` matches `fetchSharedProfiles()`: a workflow node's private code row is neither adopted nor deleted.
    /// Every `.code` row in the shared library: the candidates for adoption and for collapse.
    /// Capped at 500 rows by `lastSelected`; past that the caller creates instead of adopting.
    private func sharedCodeProfilesOnDisk() -> [BackendProfileSnapshot] {
        do {
            return try BackendProfileStore.shared.fetchProfiles()
                .filter { $0.profileType == .code && !$0.isNodeOwned }
        } catch {
            logger.error("[CODE_PROFILE] Could not scan for existing code profiles: \(error.localizedDescription). CONSEQUENCE: no row can be adopted or collapsed on this pass — a caller resolving the profile creates a new one, which orphans any code row already on disk; that is the duplicate-row defect this scan exists to prevent.")
            return []
        }
    }

    // Why: a bare skeleton (created with an empty model) must lose, or the user's configured model seems silently forgotten.
    /// Ordering for adoption: a row with a model configured outranks a bare skeleton, then most recently selected wins.
    private static func adoptionPreference(_ lhs: BackendProfileSnapshot, _ rhs: BackendProfileSnapshot) -> Bool {
        let lhsConfigured = !(lhs.details.agentConfig?.llmConfig.modelName.isEmpty ?? true)
        let rhsConfigured = !(rhs.details.agentConfig?.llmConfig.modelName.isEmpty ?? true)
        if lhsConfigured != rhsConfigured { return lhsConfigured }
        return (lhs.lastSelected ?? .distantPast) > (rhs.lastSelected ?? .distantPast)
    }

    // Why: duplicates must go: the Profiles sidebar hides `.code`, so users cannot remove them and their tool settings idle.
    /// Deletes the code rows that lost the adoption race.
    /// Only deletes from the rows `ensureCodeProfile()` just scanned, already filtered to shared `.code` rows.
    private func collapseDuplicateCodeProfiles(keeping keptID: UUID, from scanned: [BackendProfileSnapshot]) {
        let duplicates = scanned.filter { $0.id != keptID }
        guard !duplicates.isEmpty else { return }

        var removed = 0
        for duplicate in duplicates {
            do {
                try BackendProfileStore.shared.deleteProfile(withId: duplicate.id)
                removed += 1
            } catch {
                logger.error("[CODE_PROFILE] Failed to remove duplicate code profile \(duplicate.id.uuidString): \(error.localizedDescription). CONSEQUENCE: it stays in the Tool Library's profile menu as a second 'Code Session', and tools enabled on it apply to nothing.")
            }
        }

        logger.warning("[CODE_PROFILE] Collapsed \(removed) of \(duplicates.count) duplicate code profile(s); kept \(keptID.uuidString). CONSEQUENCE: tool enablement previously saved against a removed row is gone — the Code interface never read it, so no behaviour the user could observe changes.")
    }

    // MARK: - Helpers

    /// Hydrates local caches from a fetched profile snapshot.
    private func hydrateFromProfile(_ profile: BackendProfileSnapshot) {
        guard case .code(let agentConfig) = profile.details else { return }
        hydrateModelCaches(from: agentConfig.llmConfig)
        if let path = agentConfig.projectPath, !path.isEmpty, path != "/" {
            self.projectPath = URL(fileURLWithPath: path)
        }
    }

    private func hydrateModelCaches(from llmConfig: ProviderConfig) {
        provider = llmConfig.apiProvider
        modelName = llmConfig.modelName
        apiKey = llmConfig.apiKey
        baseURL = llmConfig.baseURL
        modelMetadata = llmConfig.modelMetadata
    }

    // MARK: - Tool Merge
    // The tools list is rewritten on every send; merging, not replacing it with the preset, keeps the user's Auto/Ask
    // toggles and added non-preset tools. Preset tools cannot be disabled; user-added tools are appended unchanged.

    /// A tool's identity in the merge: the same name from two sources is two tools.
    static func toolKey(_ tool: Tool) -> String { "\(tool.sourceId)-\(tool.name)" }

    /// Ask/Auto is carried over from `existing` like the other fields. The row is shared by every
    /// project, but it is not another project's value: switching project rewrites the row's tools
    /// from that project's `CodeToolOverride`s (`restore(_:into:)`), Ask/Auto included.
    static func mergePresetTools(
        preset: [Tool],
        existing: [Tool]
    ) -> [Tool] {
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { (toolKey($0), $0) })
        let presetKeys = Set(preset.map(toolKey))

        var merged: [Tool] = []

        // 1. Preset tools — always present, carry over user preferences when set.
        for presetTool in preset {
            var carried = presetTool
            if let user = existingByKey[toolKey(presetTool)] {
                carried.requiresConfirmation = user.requiresConfirmation
                carried.isFavorite = user.isFavorite
                carried.timeout = user.timeout
                carried.timeoutMessage = user.timeoutMessage
                carried.cutStrategy = user.cutStrategy
            }
            merged.append(carried)
        }

        // 2. User-added tools that aren't in the preset — append in original order.
        for tool in existing where !presetKeys.contains(toolKey(tool)) {
            merged.append(tool)
        }

        return merged
    }

    // MARK: - Project knowledge

    /// Re-reads `AGENTS.md` and the memory listing into the display copy. Creates nothing: a
    /// project without either simply has no section (the old `context.md` was created from a
    /// template on open, which put an untracked `.devgentic/` into every repository opened).
    func refreshProjectKnowledge() {
        guard let projectURL = projectPath else {
            projectKnowledgeContent = nil
            projectMemoryEntryCount = 0
            return
        }
        let store = ProjectMemoryStore(projectRoot: projectURL)
        projectMemoryEntryCount = store.entries().count
        let agents = ProjectInstructionsFile.read(inProject: projectURL.path)
        projectKnowledgeContent = CodeSystemPrompt.projectKnowledgeSection(
            agentsInstructions: agents,
            memoryListing: store.promptListing(),
            apiProvider: provider)
        logger.debug("[CODE] Project knowledge for '\(projectURL.lastPathComponent)': AGENTS.md \(agents.map { "\($0.count) chars" } ?? "absent"), memory \(store.entries().count) entr(ies), \(self.projectKnowledgeContent?.count ?? 0) chars in all.")
    }
}
