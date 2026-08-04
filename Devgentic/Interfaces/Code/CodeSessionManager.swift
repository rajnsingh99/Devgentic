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
        guard let path = projectPath else { return "Select folder" }
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
    private static let recentPathsKey = "devgentic.codeRecentProjectPaths"
    private static let legacyConfigKey = "devgentic.codeSessionConfig"
    private static let devgenticDirName = ".devgentic"
    private static let projectMemoryFileName = ".devgentic/context.md"

    @ObservationIgnored private var contextFileMonitor: FileSystemMonitor?

    // MARK: - Init

    init() {
        // Clean up legacy CodeSessionConfig from UserDefaults
        UserDefaults.standard.removeObject(forKey: Self.legacyConfigKey)

        // Restore cached recent project paths
        loadRecentProjectPaths()

        // Restore profile ID
        if let uuidString = UserDefaults.standard.string(forKey: Self.profileIDKey),
           let uuid = UUID(uuidString: uuidString) {
            // Verify profile still exists in SwiftData
            if let profile = try? BackendProfileStore.shared.fetchProfile(byId: uuid) {
                self.codeProfileID = uuid
                hydrateFromProfile(profile)
                logger.info("CodeSessionManager restored profile \(uuid.uuidString) — provider: \(self.provider.rawValue), model: \(self.modelName)")
            } else {
                // Profile was deleted externally — clear stale ID
                UserDefaults.standard.removeObject(forKey: Self.profileIDKey)
                logger.warning("CodeSessionManager: stale profile ID \(uuid.uuidString) — profile not found, cleared")
            }
        } else {
            logger.info("CodeSessionManager initialized — no existing code profile")
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

    /// Lazily creates or returns the singleton code profile.
    @discardableResult
    func ensureCodeProfile() -> UUID {
        // Fast path: profile already exists
        if let id = codeProfileID,
           (try? BackendProfileStore.shared.fetchProfile(byId: id)) != nil {
            return id
        }

        // Create a skeleton code profile with empty model (lenient validation allows this)
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
            UserDefaults.standard.set(snapshot.id.uuidString, forKey: Self.profileIDKey)
            logger.info("Created code profile \(snapshot.id.uuidString)")
            return snapshot.id
        } catch {
            logger.error("Failed to create code profile: \(error.localizedDescription)")
            return UUID() // Should not happen — lenient validation for inserts
        }
    }

    // MARK: - Config Updates

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
        UserDefaults.standard.set(updated.map(\.path), forKey: Self.recentPathsKey)
    }

    private func loadRecentProjectPaths() {
        guard let raw = UserDefaults.standard.array(forKey: Self.recentPathsKey) as? [String] else { return }
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
        agentConfig.tools = Self.mergePresetTools(preset: CodeToolPreset.defaultTools, existing: agentConfig.tools)
        agentConfig.projectPath = projectPathStr

        profile.details = .code(agentConfig)

        do {
            try BackendProfileStore.shared.saveProfile(profile)
            logger.info("[CODE] Instructions refreshed — project: '\(projectName)', instructions: \(instructions.count) chars")
        } catch {
            logger.error("[CODE] Failed to refresh instructions: \(error.localizedDescription)")
        }
    }

    /// Resets the code session by deleting the profile. `isConfigured` returns false.
    /// A fresh profile is lazily created on next `ensureCodeProfile()` call.
    func resetSession() {
        // Stop file watcher
        contextFileMonitor?.stop()
        contextFileMonitor = nil
        projectMemoryContent = nil

        // Delete the profile from SwiftData
        if let profileID = codeProfileID {
            try? BackendProfileStore.shared.deleteProfile(withId: profileID)
            logger.info("Deleted code profile \(profileID.uuidString)")
        }

        // Clear persisted handle
        codeProfileID = nil
        UserDefaults.standard.removeObject(forKey: Self.profileIDKey)

        // Clear local caches
        modelName = ""
        projectPath = nil
        apiKey = nil
        baseURL = nil

        logger.info("Code session reset — profile deleted, folder & model cleared")
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

    private static func mergePresetTools(preset: [Tool], existing: [Tool]) -> [Tool] {
        func key(_ tool: Tool) -> String { "\(tool.sourceId)-\(tool.name)" }
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { (key($0), $0) })
        let presetKeys = Set(preset.map(key))

        var merged: [Tool] = []

        // 1. Preset tools — always present, carry over user preferences when set.
        for presetTool in preset {
            if let user = existingByKey[key(presetTool)] {
                var carried = presetTool
                carried.requiresConfirmation = user.requiresConfirmation
                carried.isFavorite = user.isFavorite
                carried.timeout = user.timeout
                carried.timeoutMessage = user.timeoutMessage
                merged.append(carried)
            } else {
                merged.append(presetTool)
            }
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
