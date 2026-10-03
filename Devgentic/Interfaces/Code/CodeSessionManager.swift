// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeSessionManager.swift
//  Devgentic
//
//  Manages the Code interface's singleton profile persisted in SwiftData.
//  Handles model + project selection, cognitive profile capture, project
//  folder coordination with the Explorer sidebar, and .devgentic/context.md
//  lifecycle (auto-creation, file watching, prompt injection).
//
//  ⚠️ ONE PERMANENT PROFILE, SETTINGS PER PROJECT (2026-09-24). The row is created once and never
//  deleted — Home resets it to the preset instead. Everything the user can change (limits,
//  Ask/Auto, the model, the tools) belongs to the project folder and lives in
//  `CodeQuickSettingsStore`; the row only ever holds the CURRENT project's copy. Opening a folder
//  loads its copy onto the row (`updateProjectPath`), and leaving it — another folder, Home, or a
//  send — captures the row back. Before this, Home deleted the row, and every per-tool setting and
//  enabled MCP tool went with it.
//

import Foundation
import os

private let logger = DGLogger(category: "CodeSessionManager")

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

    // MARK: - Project Memory (cached)

    /// Cached content of `.devgentic/context.md`. Updated on file change via the monitor
    /// and on initial project open. `nil` means the file doesn't exist or is empty.
    var projectMemoryContent: String?

    // MARK: - Private

    private static let profileIDKey = "devgentic.codeProfileID"
    /// Per-project settings live in their OWN UserDefaults key: the one profile row can only hold
    /// the current project's copy — see `CodeQuickSettingsStore`.
    private static let quickSettingsKey = CodeQuickSettingsStore.defaultsKey
    private static let recentPathsKey = "devgentic.codeRecentProjectPaths"
    private static let devgenticDirName = ".devgentic"
    private static let projectMemoryFileName = ".devgentic/context.md"

    @ObservationIgnored private var contextFileMonitor: FileSystemMonitor?

    /// Set when `init()` kept the stored handle but could not READ the row, because the store threw
    /// rather than reporting the row absent. The first `ensureCodeProfile()` that manages to read
    /// it fills the caches.
    ///
    /// ⚠️ An explicit flag, NOT `modelName.isEmpty`. `resetSession()` deliberately empties the
    /// caches while the row can still carry a model, so keying the re-hydrate off emptiness would
    /// repopulate the session the user just reset — restoring a model they had explicitly cleared.
    @ObservationIgnored private var needsHydrationFromStore = false

    /// Where the profile handle and recent-paths cache live.
    ///
    /// ⚠️ Injectable for ONE reason: the handle is the thing whose loss creates duplicate code
    /// profiles, so a test has to be able to clear it — and `UserDefaults.standard` under the test
    /// host IS the shipping app's domain, so a test that cleared it there would delete the
    /// developer's own `devgentic.codeProfileID` and hand them the very defect under test.
    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Restore cached recent project paths
        loadRecentProjectPaths()

        // Restore profile ID
        if let uuidString = self.defaults.string(forKey: Self.profileIDKey),
           let uuid = UUID(uuidString: uuidString) {
            // ⚠️ A THROWN fetch is not a deleted row, and the difference is a duplicate profile.
            // `try?` collapsed both into `nil`, and the else-branch below deletes the handle — so a
            // transient `containerNotConfigured` (this type is constructed from a stored-property
            // default, i.e. before `DevgenticApp.init()`'s body, and only declaration order puts the
            // container first) permanently orphaned the row: the store kept it, nothing referenced
            // it, and the next `ensureCodeProfile()` minted a rival "Code Session". Keep the two
            // cases apart — only a genuine `nil` may clear the key.
            do {
                if let profile = try BackendProfileStore.shared.fetchProfile(byId: uuid) {
                    self.codeProfileID = uuid
                    hydrateFromProfile(profile)
                    logger.info("[CODE_PROFILE] Restored profile \(uuid.uuidString) — provider: \(self.provider.rawValue), model: \(self.modelName)")
                    // ⚠️ Reconcile even on a SUCCESSFUL restore. Adoption only collapses duplicates
                    // when the handle was lost, and a machine that already accumulated them has a
                    // perfectly valid handle pointing at the newest one — so without this pass the
                    // existing orphans are permanent. Once per launch, not per action: the rows
                    // cannot multiply mid-session, and `ensureCodeProfile()` runs on every Tools
                    // click and model change.
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

        // If a project path was restored, bootstrap memory and ensure it's in recents
        // (covers first launch after this feature ships for existing users).
        if let restored = projectPath {
            rememberRecentPath(restored)
            bootstrapProjectMemory()
            // Restored across launches — publish it too, or the roots list would only be
            // populated by an explicit folder change during the session.
            Task { await MCPRootsProvider.setCodeProjectRoot(restored) }
        }
    }

    // MARK: - Profile Lifecycle

    /// Returns the singleton code profile — adopting the one already on disk before creating a new
    /// one.
    ///
    /// ⚠️ THE STORE IS AUTHORITATIVE; the UserDefaults handle is only a cache. It has been lost
    /// three distinct ways in practice: a bundle-identifier change (`com.dev.devgentic` →
    /// `app.devgentic.macos`) wiped the whole defaults domain while `DevgenticSD.store` — whose
    /// path is not bundle-scoped — kept every row; a thrown fetch in `init()` was read as
    /// "deleted"; and `resetSession()` cleared the handle on a delete that had silently failed.
    /// Each loss used to mint a SECOND "Code Session" and orphan the first forever — nothing GCs
    /// profiles, and the orphan stays selectable in the Tool Library under the identical name, so
    /// tool enablement saved against it is read by nobody. Adopting makes every one of those
    /// losses self-healing instead of duplicating.
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
                // ⚠️ Return, do NOT fall through to create. Falling through on an unreadable store
                // is precisely how a duplicate is born: the adopt scan below would fail for the
                // same reason and a rival row would be written the moment the store recovered.
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

    /// Execution overrides for the CURRENT project folder, or the preset defaults when the folder
    /// has none (or when no folder is open).
    ///
    /// ⚠️ Reads through to UserDefaults on every access rather than caching. The store is the
    /// single source of truth, and a cache here would have to be invalidated on project switch —
    /// exactly the kind of staleness that makes a settings panel show one thing while the run
    /// uses another.
    var quickSettings: CodeQuickSettings {
        CodeQuickSettingsStore.settings(for: projectPath?.path, defaults: defaults)
    }

    /// Persists quick settings for the current project and pushes them onto the live profile.
    ///
    /// The profile write is what makes a change take effect for a run already configured; the
    /// per-send `refreshInstructionsOnProfile()` re-applies them anyway, so this is belt-and-braces
    /// for the case where the user changes a setting between sends.
    func updateQuickSettings(_ settings: CodeQuickSettings) {
        guard let path = projectPath?.path else {
            logger.warning("[CODE_SETTINGS] Quick settings changed with no project selected. CONSEQUENCE: the change is dropped — settings are scoped per project and there is nothing to attach them to.")
            return
        }

        // ⚠️ The popover commits on appear-hydration and again on dismiss, so most calls carry the
        // values already stored. Seen on device 2026-09-24 as a `[PROFILE_SAVE] ⚠️ REDUNDANT` write
        // on every open and close.
        guard settings != CodeQuickSettingsStore.settings(for: path, defaults: defaults) else {
            logger.debug("[CODE_SETTINGS] Quick settings for '\(URL(fileURLWithPath: path).lastPathComponent)' unchanged — nothing saved.")
            return
        }

        CodeQuickSettingsStore.save(settings, for: path, defaults: defaults, now: Date())
        logger.info("[CODE_SETTINGS] Saved quick settings for '\(URL(fileURLWithPath: path).lastPathComponent)' — maxIterations: \(settings.maxIterations.map(String.init) ?? "no cap"), timeout: \(settings.executionTimeout.map { String(Int($0)) } ?? "default")s, thinking: \(settings.thinkingEnabled.map(String.init) ?? "default").")

        applyQuickSettingsToProfile(settings)
    }

    /// Writes the execution-shaped fields of `settings` onto the persisted `.code` profile.
    ///
    /// ⚠️ Tool CONFIRMATIONS go through `mergePresetTools` rather than being written directly:
    /// the preset is the authority on which tools exist, and a direct write here would let a
    /// stale override resurrect a tool the preset had dropped.
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

    /// The one place quick settings become `AgentConfig` fields.
    ///
    /// ⚠️ Static and pure so the settings→config mapping is testable without a store, a profile or
    /// a MainActor hop. Both callers — `applyQuickSettingsToProfile` and the per-send
    /// `refreshInstructionsOnProfile` — go through here, so the two cannot drift.
    /// Preset values an untouched project runs with. Named constants rather than literals at the
    /// two sites that need them — the same drift `AgentExecutionDefaults` exists to stop.
    ///
    /// ⚠️ NO CAP by default since 2026-09-25 (user decision; was 20). The iteration cap is opt-in
    /// per project, typed in the quick settings. A run without one is still bounded by
    /// `presetExecutionTimeout`. The circuit breaker does NOT stop a Code run: `.fallbackPrompt`
    /// downgrades every trigger to a warning and a nudge (owner decision 2026-09-27, D-15).
    static let presetMaxIterations = AgentExecutionDefaults.uncapped

    /// What the quick settings accept for a typed cap (user decision 2026-09-25). A stored value
    /// outside it — from before the range existed — is clamped at `apply`, never trusted as-is.
    static let iterationCapRange = 10...1000

    /// Bounds the COMPUTE of a whole turn — every iteration and every tool call together, with
    /// time parked awaiting a human excluded (`ComputeTimeoutSentinel`).
    ///
    /// ⚠️ 60 minutes since 2026-09-26 (HITL Waiting Contract, decision D: every limit lives inside
    /// the one above it, and the terminal ceiling rose to 30 min). Raised 300 → 1800 on 2026-09-21,
    /// and it is NOT an independent choice. It must stay
    /// comfortably above `BatchCommandTool.maxTimeoutSeconds` (1800): a turn that spends the
    /// command's full ceiling on one build still has to read the output, fix the error and
    /// re-run. At 300 s the two bounds contradicted each other — the tool advertised a timeout
    /// the run could never reach, and the sentinel got there first and aborted the whole turn
    /// WITHOUT the partial output the tool's own timeout would have returned.
    ///
    /// ⚠️ With no iteration cap by default (2026-09-25), this is the ONLY automatic stop for a Code
    /// run — the circuit breaker only warns there (D-15).
    static let presetExecutionTimeout: TimeInterval = 3600

    /// Code's default context window: the model's own, capped here. KV-cache memory grows with the
    /// window, so the cap is what keeps a 128K-trained model from claiming many GB by default;
    /// the per-project "Context size" goes past it deliberately.
    ///
    /// ⚠️ Why Code needs its own default at all (2026-09-24). With no override, an Ollama model ran
    /// under the agent preset's 8,192 — and Code's fixed prompt plus 23 tool definitions is ~5.5K
    /// tokens of that, before the task. A five-step run overflowed; Ollama silently dropped the
    /// START of the prompt (the instructions and `final_answer` contract) and the run ended with no
    /// answer.
    static let presetContextCap = 32_768

    /// The window a Code run on `llm` should use — nil leaves Ollama's usual ladder in charge.
    static func contextTokens(_ settings: CodeQuickSettings, for llm: ProviderConfig) -> Int? {
        guard llm.apiProvider == .ollama else { return nil }
        if let chosen = settings.contextTokens, chosen > 0 { return chosen }
        return EffectiveContextWindow.trainedWindow(for: llm).map { min($0, presetContextCap) }
    }

    static func apply(_ settings: CodeQuickSettings, to agentConfig: inout AgentConfig) {
        // ⚠️⚠️ ALWAYS ASSIGN — never "skip when nil". These used to be `if let`, which made the
        // mapping a ONE-WAY DOOR: pressing Remove in the limits panel stored 0, `apply` turned
        // that into `nil` (unbounded) on the profile, and afterwards resetting the setting back to
        // "inherit" wrote nothing at all, so the preset's 300 s could never come back. A run
        // observed 2026-09-20 logged "[EXEC_LIMITS] No execution timeout configured" for exactly
        // this reason. An unset override must RESTORE the preset, not leave the last value in
        // place — that is what makes "Reset to defaults" mean anything.
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

        // The key goes to the provider's Keychain slot so another project's model on this
        // provider — or this one, after a detour — finds it again. ⚠️ BEFORE the profile save: for a
        // shared-key provider the slot is the shared key, and the profile keeps the shared key rather
        // than one it carries — so the save must find the new key already there.
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

        // Publish as an MCP root so filesystem-shaped servers get a workspace boundary
        // instead of an empty `roots/list`. Connected servers are notified immediately, so
        // switching project re-scopes them without a reconnect.
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
        bootstrapProjectMemory()
    }

    /// Puts a Code conversation's own folder back when it is selected.
    ///
    /// ⚠️ Before conversations recorded their folder, reopening an old session ran it against
    /// whichever folder happened to be open — a session begun in project A would read and write
    /// project B's files.
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
    ///
    /// A project never captured before gets the PRESET tools when another project is being left —
    /// otherwise it would inherit that project's MCP tools and settings. When no project was open
    /// (the welcome screen), it adopts what is on the row instead, so tools enabled before picking
    /// a folder are not thrown away.
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

    /// The prompt a Code run in `projectPath` is given.
    static func instructions(forProject projectPath: String, apiProvider: ApiProvider, projectContext: String?) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        // CodeSystemPrompt picks the XML or markdown variant by provider (Claude → XML, others →
        // markdown) and formats the project_context injection to match.
        return CodeSystemPrompt.production(
            projectPath: projectPath,
            projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            currentDate: dateFormatter.string(from: Date()),
            apiProvider: apiProvider,
            projectContext: projectContext
        )
    }

    /// `.devgentic/context.md` in `projectPath`, or nil when missing or empty.
    static func readProjectContext(inProject projectPath: String) -> String? {
        let memoryURL = URL(fileURLWithPath: projectPath).appendingPathComponent(projectMemoryFileName)
        guard let content = try? String(contentsOf: memoryURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return content
    }

    /// The Code profile as a run in `conversationProjectPath` must see it.
    ///
    /// ⚠️⚠️ WHY (2026-09-24). There is ONE Code profile and it holds whichever project is OPEN. A run
    /// the composer starts is always for the open project, but a background-task wake, a scheduled
    /// run or a resume after approval starts for ITS conversation — possibly while another project
    /// is open. Taken from the row as-is, such a run got the other project's folder, prompt,
    /// context.md, tools and limits. This builds the conversation's own, in memory; the row is not
    /// touched.
    ///
    /// Returns `profile` unchanged when it is not Code, the conversation has no folder, or the folder
    /// is already the one on the row (every composer send).
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
                                           projectContext: readProjectContext(inProject: target))
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
        // `sameLocation`, not `!=`. **Hardening, not a fixed bug**: today both sides are
        // directory-flavoured (`NSOpenPanel` hands back a directory URL, and reloaded entries
        // go through `URL(fileURLWithPath:)`, which stats the path), so `!=` compared correctly.
        // It is worth the change anyway — a symlinked project folder DOES diverge here, since
        // `standardizedFileURL` never resolves symlinks, and the failure is a silent duplicate
        // row in Recent Projects. This loop already stats every entry below, so resolution
        // costs nothing extra.
        var updated = recentProjectPaths.filter { !$0.sameLocation(as: standardized) }
        updated.insert(standardized, at: 0)
        // Drop entries whose folders no longer exist on disk (user moved/deleted them).
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

    /// Refreshes the code profile's instructions with the latest system prompt + project memory.
    /// Called before each send to pick up context.md changes.
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

        let memoryContent = loadProjectMemory()
        let instructions = Self.instructions(forProject: projectPathStr,
                                             apiProvider: agentConfig.llmConfig.apiProvider,
                                             projectContext: memoryContent)
        if let projectMemory = memoryContent {
            logger.info("[CODE] Injected project context into instructions (\(projectMemory.count) chars)")
        } else {
            logger.debug("[CODE] No project context to inject (context.md empty or missing)")
        }

        agentConfig.instructions = instructions
        agentConfig.projectPath = projectPathStr

        // ⚠️ Quick settings are re-applied on EVERY send, not just when the user changes them —
        // the row is shared by every project, so this is what guarantees a run uses THIS
        // project's limits. `apply` also performs the tool merge, so the preset's guarantees still
        // hold. The capture below then records anything the Tool Library changed on the row.
        let settings = CodeQuickSettingsStore.settings(for: projectPathStr, defaults: defaults)
        Self.apply(settings, to: &agentConfig)
        // ⚠️ Logged on EVERY send, not only when the user has overridden something. This was
        // gated on `!settings.isDefault`, so a run at the preset limits said nothing about what
        // they were — and "Reached maximum iterations (N)" is only diagnosable against the cap
        // that was in force. `apply` runs either way; only the line was conditional.
        if let path = projectPath?.path { captureProject(path, from: agentConfig, reason: "send") }
        let limitSource = settings.isDefault ? "preset" : "per-project override"
        logger.info("[CODE_SETTINGS] '\(projectName)' runs with maxIterations: \(AgentExecutionDefaults.describe(agentConfig.maxIterations)), timeout: \(agentConfig.executionTimeout.map { "\(Int($0))s" } ?? "none"), context: \(agentConfig.llmConfig.numCtxOverride.map { "\($0) tokens (\(settings.contextTokens == nil ? "Code default" : "chosen"))" } ?? "provider default") — source: \(limitSource). CONSEQUENCE: an iteration-cap or timeout termination in this run is against these exact values.")

        profile.details = .code(agentConfig)

        // ⚠️⚠️ F10. This runs on EVERY send and rebuilds the same 7,567-char instruction block
        // from the same inputs, so an unchanged session wrote an identical row per message —
        // each one a real SwiftData write, a WAL entry, and a `lastSelected` bump that reordered
        // "recently used" for a profile the user had not selected. The store logs that as
        // `[PROFILE_SAVE] ⚠️ REDUNDANT`, which is how this was found.
        //
        // ⚠️ The guard lives HERE rather than in the store, deliberately. `BackendProfile.details`
        // has a setter that moves the API key to the Keychain, refuses to overwrite an
        // undecodable blob and rewrites every denormalized column — skipping it centrally would
        // also skip those, and would strand a row whose cached value diverged from its persisted
        // blob after an encode failure. This caller knows exactly what it recomputed, so it is
        // the one place that can answer "nothing changed" without giving anything up.
        guard profile.details != detailsBeforeRefresh else {
            logger.debug("[CODE] Instructions unchanged for '\(projectName)' — skipping the profile write. CONSEQUENCE: no SwiftData write and no lastSelected bump this send; the row already holds these exact instructions, project path and quick settings.")
            return
        }

        do {
            try BackendProfileStore.shared.saveProfile(profile)
            logger.info("[CODE] Instructions refreshed — project: '\(projectName)', instructions: \(instructions.count) chars")
        } catch {
            // ⚠️ Store validation rejects a profile with no model, so this fires for a session
            // that has a folder but no model yet. Harmless in practice — `attemptSend` refuses to
            // send without a model, and the next refresh re-applies everything — but it means the
            // write silently did nothing, so say what was lost.
            logger.error("[CODE] Failed to refresh instructions: \(error.localizedDescription). CONSEQUENCE: the profile keeps its previous instructions, project path and quick settings for now; all of them are re-applied on the next successful refresh, so nothing is permanently lost.")
        }
    }

    /// Home: the session goes back to "no folder", and the ROW goes back to the preset.
    ///
    /// ⚠️⚠️ The row is RESET, never deleted (2026-09-24). Deleting it was how every per-tool
    /// setting and every MCP tool enabled for Code vanished on each Home press — they lived on the
    /// row and nowhere else. Now the project being left is captured first, so everything it had
    /// comes back when its folder is opened again.
    ///
    /// The model is kept: it is the "last used" fallback a project with no remembered model starts
    /// with.
    func resetSession() {
        // Stop file watcher
        contextFileMonitor?.stop()
        contextFileMonitor = nil
        projectMemoryContent = nil

        let leaving = projectPath
        // ⚠️ `ensureCodeProfile()`, not `codeProfileID`. The handle is resolved lazily, so a Home
        // pressed before any Code action this launch found NO handle, reset nothing — and the
        // adoption that followed re-hydrated the row's stale folder, undoing the Home (seen on
        // device 2026-09-24: "Home with no readable Code profile (handle: none)").
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

    /// Every `.code` row in the shared library — the candidates for adoption and for collapse.
    ///
    /// ⚠️ `!isNodeOwned` matches `fetchSharedProfiles()`'s rule. A workflow node's private code row
    /// belongs to that node's graph: adopting one would hand the Code interface a configuration it
    /// does not own, and collapsing one would delete part of a workflow.
    ///
    /// (`fetchProfiles()` is capped at 500 rows by `lastSelected`. Past that cap this simply misses
    /// and the caller creates instead — it degrades to the pre-fix behaviour, never worse.)
    private func sharedCodeProfilesOnDisk() -> [BackendProfileSnapshot] {
        do {
            return try BackendProfileStore.shared.fetchProfiles()
                .filter { $0.profileType == .code && !$0.isNodeOwned }
        } catch {
            logger.error("[CODE_PROFILE] Could not scan for existing code profiles: \(error.localizedDescription). CONSEQUENCE: no row can be adopted or collapsed on this pass — a caller resolving the profile creates a new one, which orphans any code row already on disk; that is the duplicate-row defect this scan exists to prevent.")
            return []
        }
    }

    /// Ordering for `ensureCodeProfile()`'s adoption: a row with a model configured outranks a bare
    /// skeleton, then most-recently-selected wins.
    ///
    /// ⚠️ The skeleton tie-break is the part that matters. `ensureCodeProfile()` creates with an
    /// EMPTY model, so "opened Code mode once, never picked a model" leaves a bare row behind —
    /// exactly the shape of the orphans this whole change exists to stop. Adopting one of those
    /// over a configured row would read to the user as their model being silently forgotten.
    private static func adoptionPreference(_ lhs: BackendProfileSnapshot, _ rhs: BackendProfileSnapshot) -> Bool {
        let lhsConfigured = !(lhs.details.agentConfig?.llmConfig.modelName.isEmpty ?? true)
        let rhsConfigured = !(rhs.details.agentConfig?.llmConfig.modelName.isEmpty ?? true)
        if lhsConfigured != rhsConfigured { return lhsConfigured }
        return (lhs.lastSelected ?? .distantPast) > (rhs.lastSelected ?? .distantPast)
    }

    /// Deletes the code rows that lost the adoption race.
    ///
    /// ⚠️ Leaving them is not the neutral option. The code profile is a singleton by design: the
    /// user cannot create a second one, and the Profiles sidebar filters `.code` out entirely, so a
    /// duplicate has NO hand-removal path. It is not inert either — the Tool Library lists every
    /// tool-capable profile, so duplicates appear there as several identically-named "Code Session"
    /// entries, and tool enablement saved against the wrong one is a silent no-op.
    ///
    /// Deliberately narrow: it only ever deletes from the rows `ensureCodeProfile()` just scanned,
    /// which are already filtered to shared `.code` rows.
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
    //
    // The Code profile's tools list is rewritten on every send via
    // `refreshInstructionsOnProfile()`. Naively replacing it with
    // `CodeToolPreset.defaultTools` would nuke two kinds of user choices:
    //   1. Auto/Ask toggles the user set on preset tools via the Tool Library.
    //   2. Additional tools the user added (non-preset built-ins, MCP servers).
    // The merge preserves both: preset tools stay in the list (user can't disable
    // them), carrying over the user's requiresConfirmation / favorite / timeout
    // fields; user-added tools outside the preset are appended unchanged.

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

    // MARK: - Project Memory Lifecycle

    /// Called when a project path is set (or restored from persistence).
    /// Ensures `.devgentic/context.md` exists, loads its content, and starts watching for changes.
    private func bootstrapProjectMemory() {
        let projectName = projectPath?.lastPathComponent ?? "?"
        logger.info("[CODE] Bootstrapping project memory for '\(projectName)'")
        ensureProjectMemoryExists()
        projectMemoryContent = readProjectMemoryFromDisk()
        startContextFileMonitor()
        logger.info("[CODE] Project memory bootstrap complete — cached: \(self.projectMemoryContent != nil), chars: \(self.projectMemoryContent?.count ?? 0), monitor: \(self.contextFileMonitor != nil)")
    }

    /// Creates `.devgentic/context.md` with a template if it doesn't already exist.
    private func ensureProjectMemoryExists() {
        guard let projectURL = projectPath else { return }

        let devgenticDir = projectURL.appendingPathComponent(Self.devgenticDirName)
        let contextFile = devgenticDir.appendingPathComponent("context.md")

        guard !FileManager.default.fileExists(atPath: contextFile.path) else {
            logger.info("Project memory file already exists at \(contextFile.path)")
            return
        }

        do {
            if !FileManager.default.fileExists(atPath: devgenticDir.path) {
                try FileManager.default.createDirectory(at: devgenticDir, withIntermediateDirectories: true)
            }
            let template = Self.contextTemplate(projectName: projectURL.lastPathComponent)
            try template.write(to: contextFile, atomically: true, encoding: .utf8)
            logger.info("Created project memory file at \(contextFile.path)")
        } catch {
            logger.error("Failed to create project memory file: \(error.localizedDescription)")
        }
    }

    /// Reads `.devgentic/context.md` from disk. Returns nil if missing or empty.
    private func readProjectMemoryFromDisk() -> String? {
        guard let projectURL = projectPath else { return nil }
        let memoryURL = projectURL.appendingPathComponent(Self.projectMemoryFileName)
        guard FileManager.default.fileExists(atPath: memoryURL.path),
              let content = try? String(contentsOf: memoryURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        logger.info("Loaded project memory from \(memoryURL.path) (\(content.count) chars)")
        return content
    }

    /// Returns the cached project memory content, falling back to a disk read.
    func loadProjectMemory() -> String? {
        if let cached = projectMemoryContent { return cached }
        projectMemoryContent = readProjectMemoryFromDisk()
        return projectMemoryContent
    }

    // MARK: - File Watcher

    /// Starts monitoring `.devgentic/` for context.md changes.
    private func startContextFileMonitor() {
        contextFileMonitor?.stop()
        contextFileMonitor = nil

        guard let projectURL = projectPath else { return }

        let devgenticDir = projectURL.appendingPathComponent(Self.devgenticDirName)
        guard FileManager.default.fileExists(atPath: devgenticDir.path) else { return }

        let monitor = FileSystemMonitor { [weak self] changedURLs in
            let contextFileName = "context.md"
            let relevant = changedURLs.contains { $0.lastPathComponent == contextFileName }
            guard relevant else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.projectMemoryContent = self.readProjectMemoryFromDisk()
                logger.info("Project memory reloaded via file watcher (\(self.projectMemoryContent?.count ?? 0) chars)")
            }
        }
        monitor.start(path: devgenticDir.path)
        contextFileMonitor = monitor
        logger.info("Context file monitor started for \(devgenticDir.path)")
    }

    // MARK: - Template

    /// Seed template for a new `.devgentic/context.md` file.
    private static func contextTemplate(projectName: String) -> String {
        """
        # \(projectName) — Project Context

        > This file is maintained by the Devgentic agent. It accumulates project knowledge
        > across sessions so the agent can provide better, more context-aware assistance.
        > You can also edit this file manually — changes are picked up automatically.

        ## Architecture


        ## Key Files


        ## Build & Run


        ## Patterns & Conventions


        ## Notes

        """
    }
}
