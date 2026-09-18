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

    // MARK: - Project Memory (cached)

    /// Cached content of `.devgentic/context.md`. Updated on file change via the monitor
    /// and on initial project open. `nil` means the file doesn't exist or is empty.
    var projectMemoryContent: String?

    // MARK: - Private

    private static let profileIDKey = "devgentic.codeProfileID"
    /// Per-project quick settings live in their OWN UserDefaults key, deliberately outside the
    /// profile row — see `CodeQuickSettingsStore`'s note on `resetSession()` deleting that row.
    private static let quickSettingsKey = CodeQuickSettingsStore.defaultsKey
    private static let recentPathsKey = "devgentic.codeRecentProjectPaths"
    private static let legacyConfigKey = "devgentic.codeSessionConfig"
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

        // Clean up legacy CodeSessionConfig from UserDefaults
        defaults.removeObject(forKey: Self.legacyConfigKey)

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
            maxIterations: 20,
            executionTimeout: 300,
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
            logger.warning("[CODE_SETTINGS] Quick settings changed with no project folder open. CONSEQUENCE: the change is dropped — settings are scoped per project and there is nothing to attach them to.")
            return
        }

        CodeQuickSettingsStore.save(settings, for: path, defaults: defaults, now: Date())
        logger.info("[CODE_SETTINGS] Saved quick settings for '\(URL(fileURLWithPath: path).lastPathComponent)' — maxIterations: \(settings.maxIterations.map(String.init) ?? "default"), timeout: \(settings.executionTimeout.map { String(Int($0)) } ?? "default")s, \(settings.toolConfirmations.count) tool override(s), thinking: \(settings.thinkingEnabled.map(String.init) ?? "default").")

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

        Self.apply(settings, to: &agentConfig)
        profile.details = .code(agentConfig)

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
    static func apply(_ settings: CodeQuickSettings, to agentConfig: inout AgentConfig) {
        if let maxIterations = settings.maxIterations {
            agentConfig.maxIterations = maxIterations
        }
        if let timeout = settings.executionTimeout {
            // 0 is the UI's "No limit". `nil` on the config means unbounded — see AgentConnect's
            // `[EXEC_LIMITS]` notice for what that costs.
            agentConfig.executionTimeout = timeout > 0 ? timeout : nil
        }
        if let thinking = settings.thinkingEnabled {
            agentConfig.llmConfig.thinkingEnabled = thinking
        }
        agentConfig.tools = mergePresetTools(
            preset: CodeToolPreset.defaultTools,
            existing: agentConfig.tools,
            confirmationOverrides: settings.toolConfirmations
        )
    }

    /// Updates the provider selection. Lightweight — only clears local model cache.
    /// The profile is not written until a model is actually selected.
    func updateProvider(_ provider: ApiProvider) {
        self.provider = provider
        self.modelName = ""
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

        profile.details = .code(agentConfig)

        do {
            try BackendProfileStore.shared.saveProfile(profile)
            // Update local caches
            self.provider = provider
            self.modelName = modelName
            self.apiKey = apiKey
            self.baseURL = baseURL
            logger.info("Model updated to \(modelName) (provider: \(provider.rawValue), capability: \(cognitiveProfile.capability.rawValue), dialect: \(cognitiveProfile.dialect.rawValue), thinking: \(thinkingEnabled))")
        } catch {
            logger.error("Failed to save model update: \(error.localizedDescription)")
        }
    }

    /// Updates the project path on the persisted code profile and bootstraps project memory.
    func updateProjectPath(_ url: URL) {
        self.projectPath = url
        logger.info("Project path updated to \(url.path)")

        // Publish as an MCP root so filesystem-shaped servers get a workspace boundary
        // instead of an empty `roots/list`. Connected servers are notified immediately, so
        // switching project re-scopes them without a reconnect.
        Task { await MCPRootsProvider.setCodeProjectRoot(url) }

        // Update the profile if it exists
        if let profileID = codeProfileID,
           var profile = try? BackendProfileStore.shared.fetchProfile(byId: profileID),
           case .code(var agentConfig) = profile.details {
            agentConfig.projectPath = url.path
            profile.details = .code(agentConfig)
            try? BackendProfileStore.shared.saveProfile(profile)
        }

        rememberRecentPath(url)
        bootstrapProjectMemory()
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

        let projectPathStr = projectPath?.path ?? "/"
        let projectName = projectPath?.lastPathComponent ?? "?"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let currentDate = dateFormatter.string(from: Date())

        // Assemble instructions — CodeSystemPrompt picks the XML or markdown variant
        // based on provider (Claude → XML for trained preference; all others → markdown)
        // and formats the project_context injection to match.
        let memoryContent = loadProjectMemory()
        let instructions = CodeSystemPrompt.production(
            projectPath: projectPathStr,
            projectName: projectName,
            currentDate: currentDate,
            apiProvider: agentConfig.llmConfig.apiProvider,
            projectContext: memoryContent
        )
        if let projectMemory = memoryContent {
            logger.info("[CODE] Injected project context into instructions (\(projectMemory.count) chars)")
        } else {
            logger.debug("[CODE] No project context to inject (context.md empty or missing)")
        }

        agentConfig.instructions = instructions
        agentConfig.projectPath = projectPathStr

        // ⚠️ Quick settings are re-applied on EVERY send, not just when the user changes them.
        // `resetSession()` deletes the profile row on every Home press, so the row minted by the
        // next `ensureCodeProfile()` carries the hardcoded preset values — this is what puts the
        // user's per-project choices back onto it. `apply` also performs the tool merge, so the
        // preset's guarantees still hold.
        let settings = CodeQuickSettingsStore.settings(for: projectPathStr, defaults: defaults)
        Self.apply(settings, to: &agentConfig)
        if !settings.isDefault {
            logger.info("[CODE_SETTINGS] Applied per-project quick settings for '\(projectName)' — maxIterations: \(agentConfig.maxIterations.map(String.init) ?? "nil"), timeout: \(agentConfig.executionTimeout.map { String(Int($0)) } ?? "none")s, \(settings.toolConfirmations.count) tool confirmation override(s).")
        }

        profile.details = .code(agentConfig)

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

    /// Resets the code session by deleting the profile. `isConfigured` returns false.
    /// A fresh profile is lazily created on next `ensureCodeProfile()` call.
    func resetSession() {
        // Stop file watcher
        contextFileMonitor?.stop()
        contextFileMonitor = nil
        projectMemoryContent = nil

        // Delete the profile from SwiftData.
        //
        // ⚠️ The handle is cleared only when the delete ACTUALLY succeeded. `try?` plus an
        // unconditional clear is how a failed delete became a permanent orphan: the row survived,
        // nothing pointed at it any more, and the next `ensureCodeProfile()` created a rival. This
        // path is reached from the Home button on every Code-mode session
        // (`deselectConversationAndShowWelcome`), so it runs often enough to matter.
        if let profileID = codeProfileID {
            do {
                try BackendProfileStore.shared.deleteProfile(withId: profileID)
                codeProfileID = nil
                self.defaults.removeObject(forKey: Self.profileIDKey)
                logger.info("[CODE_PROFILE] Deleted code profile \(profileID.uuidString)")
            } catch {
                logger.error("[CODE_PROFILE] Failed to delete code profile \(profileID.uuidString): \(error.localizedDescription). CONSEQUENCE: the handle is KEPT so the surviving row is not orphaned into a duplicate 'Code Session'; the session still clears its model and folder below, and the next reset retries this delete.")
            }
        } else {
            // No handle to delete by — make sure a stale key cannot outlive it.
            self.defaults.removeObject(forKey: Self.profileIDKey)
        }

        // The caches are cleared below; a pending re-hydrate would undo exactly that.
        needsHydrationFromStore = false

        // Clear local caches
        modelName = ""
        projectPath = nil
        apiKey = nil
        baseURL = nil

        logger.info("Code session reset — profile deleted, folder & model cleared")
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
        self.provider = agentConfig.llmConfig.apiProvider
        self.modelName = agentConfig.llmConfig.modelName
        self.apiKey = agentConfig.llmConfig.apiKey
        self.baseURL = agentConfig.llmConfig.baseURL
        if let path = agentConfig.projectPath, !path.isEmpty, path != "/" {
            self.projectPath = URL(fileURLWithPath: path)
        }
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

    /// - Parameter confirmationOverrides: per-project Ask/Auto from `CodeQuickSettings`, keyed by
    ///   tool name. Authoritative over the carried-over profile value when present, because the
    ///   profile row is deleted by `resetSession()` while the override survives in UserDefaults —
    ///   so after a Home press the profile has nothing to carry and the override is the only
    ///   record of what the user chose.
    private static func mergePresetTools(
        preset: [Tool],
        existing: [Tool],
        confirmationOverrides: [String: Bool] = [:]
    ) -> [Tool] {
        func key(_ tool: Tool) -> String { "\(tool.sourceId)-\(tool.name)" }
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { (key($0), $0) })
        let presetKeys = Set(preset.map(key))

        var merged: [Tool] = []

        // 1. Preset tools — always present, carry over user preferences when set.
        for presetTool in preset {
            var carried = presetTool
            if let user = existingByKey[key(presetTool)] {
                carried.requiresConfirmation = user.requiresConfirmation
                carried.isFavorite = user.isFavorite
                carried.timeout = user.timeout
                carried.timeoutMessage = user.timeoutMessage
            }
            // Applied AFTER the carry-over so it wins, and keyed by NAME so it cannot resurrect a
            // tool the preset no longer contains — an override for an unknown name is simply
            // never read.
            if let override = confirmationOverrides[presetTool.name] {
                carried.requiresConfirmation = override
            }
            merged.append(carried)
        }

        // 2. User-added tools that aren't in the preset — append in original order.
        for tool in existing where !presetKeys.contains(key(tool)) {
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
