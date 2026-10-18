// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeQuickSettings.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

private let logger = DGLogger(category: "CodeQuickSettings")

// MARK: - Settings

/// User overrides for one project folder. Every field is optional; `nil` means "use the preset default".
/// Scoped per project, not globally or per conversation: auto-approve is a statement about a folder you trust and
/// must not carry into the next project you open.
struct CodeQuickSettings: Codable, Hashable, Sendable {

    /// Reasoning cycles before the loop stops. `nil` means no cap; a value is clamped to
    /// `CodeSessionManager.iterationCapRange` when applied.
    var maxIterations: Int?

    /// COMPUTE budget in seconds — time parked awaiting a human is excluded by
    /// `ComputeTimeoutSentinel`. `nil` → `CodeSessionManager.presetExecutionTimeout`. `.some(0)` means no limit.
    var executionTimeout: TimeInterval?

    // Per-tool Ask/Auto is not stored here: it lives on the profile's tool, remembered per project by
    // `CodeToolOverride.requiresConfirmation`.

    /// Extended thinking. `nil` → off, which is the Code default: the ReAct loop pays the
    /// thinking cost once per ITERATION, so it multiplies by `maxIterations` rather than being
    /// paid once per turn. Offered only for models detection reports as capable.
    var thinkingEnabled: Bool?

    /// Context window in tokens (Ollama only). `nil` means the model window capped at `CodeSessionManager.presetContextCap`.
    /// The whole Code prompt and its tools ride in this window on every step, so a small one fills before any work is done.
    var contextTokens: Int?

    /// After each answer, one extra model call proposes facts for project memory, which the user
    /// accepts or dismisses (`ProjectMemorySuggester`). `nil` → off, the default: it costs a model
    /// call per answer, which on a local model holds the GPU for a few seconds.
    var suggestMemories: Bool?

    /// True when nothing differs from the preset; decides whether the toolbar button shows a "modified" dot.
    var isDefault: Bool {
        maxIterations == nil
            && executionTimeout == nil
            && thinkingEnabled == nil
            && contextTokens == nil
            && suggestMemories == nil
    }

    static let `default` = CodeQuickSettings()
}

// MARK: - Project state

/// What a project remembers besides its quick settings: the model it last ran with and the tools it was given.
/// Kept apart from `CodeQuickSettings` so its "Reset" doesn't forget the project's model or enabled MCP tools.
/// Stored as a delta against `CodeToolPreset`: preset tools carry large schemas and this blob lives in UserDefaults.
struct CodeProjectState: Codable, Hashable, Sendable {

    /// The model this project last ran with. `apiKey` is ALWAYS nil here — keys stay in the
    /// Keychain (`CodeProviderKeys`), never in UserDefaults.
    var model: ProviderConfig?

    /// Tools outside the preset that the user enabled for this project (built-ins from the Tool
    /// Library, MCP tools), stored whole because there is no preset to diff them against.
    var extraTools: [Tool] = []

    /// Changes to preset tools, Ask/Auto included, keyed by tool name. Absent means the preset's value.
    var presetToolOverrides: [String: CodeToolOverride] = [:]

    var isEmpty: Bool { model == nil && extraTools.isEmpty && presetToolOverrides.isEmpty }
}

/// A preset tool's user-editable fields, stored only for a tool where at least one differs from `CodeToolPreset`.
/// A full snapshot of the four fields, not a per-field delta: JSON cannot tell `.some(nil)` from absent, so a
/// cleared timeout would come back as the preset's.
struct CodeToolOverride: Codable, Hashable, Sendable {
    var timeout: TimeInterval?
    var timeoutMessage: String?
    var isFavorite: Bool
    var cutStrategy: ContextCutStrategy?
    /// Ask First (`true`) or Auto Run (`false`), as set in the Tool Library.
    /// Optional only so an override saved without this field still decodes; `nil` there means the preset's.
    var requiresConfirmation: Bool?

    /// `nil` when `current` matches the preset — nothing worth storing.
    init?(preset: Tool, current: Tool) {
        guard current.timeout != preset.timeout
            || current.timeoutMessage != preset.timeoutMessage
            || current.isFavorite != preset.isFavorite
            || current.cutStrategy != preset.cutStrategy
            || current.requiresConfirmation != preset.requiresConfirmation else { return nil }
        timeout = current.timeout
        timeoutMessage = current.timeoutMessage
        isFavorite = current.isFavorite
        cutStrategy = current.cutStrategy
        requiresConfirmation = current.requiresConfirmation
    }

    func applied(to tool: Tool) -> Tool {
        var tool = tool
        if let requiresConfirmation { tool.requiresConfirmation = requiresConfirmation }
        tool.timeout = timeout
        tool.timeoutMessage = timeoutMessage
        tool.isFavorite = isFavorite
        tool.cutStrategy = cutStrategy
        return tool
    }
}

// MARK: - Store

/// Persists `CodeQuickSettings` and `CodeProjectState` per project folder in UserDefaults.
/// The Code profile is a projection of this store, loaded when a folder opens and captured back when the user leaves.
/// Keyed by absolute path: renaming or moving a folder resets its settings, so a grant can't follow to a new directory.
enum CodeQuickSettingsStore {

    static let defaultsKey = "devgentic.codeQuickSettings.v1"

    /// Most recent projects retained. Entries are tiny, but the map is written on every change
    /// and an unbounded dictionary in UserDefaults grows for the life of the install.
    static let maxRetainedProjects = 50

    // MARK: Read

    static func settings(for projectPath: String?, defaults: UserDefaults) -> CodeQuickSettings {
        guard let key = normalizedKey(projectPath) else { return .default }
        return load(from: defaults).entries[key]?.settings ?? .default
    }

    /// The project's remembered model and tools, or `nil` when the project has never been captured —
    /// which callers must tell apart from "captured, and it is the preset" (see `updateProjectPath`).
    static func projectState(for projectPath: String?, defaults: UserDefaults) -> CodeProjectState? {
        guard let key = normalizedKey(projectPath) else { return nil }
        return load(from: defaults).entries[key]?.project
    }

    // MARK: Write

    /// Stores `settings` for `projectPath`, pruning the least recently touched projects past the retention cap.
    /// A settings value equal to the preset default removes the entry, so "reset to defaults" uses no retention slot
    /// and cannot evict a project the user actually configured.
    static func save(
        _ settings: CodeQuickSettings,
        for projectPath: String?,
        defaults: UserDefaults,
        now: Date
    ) {
        guard let key = normalizedKey(projectPath) else {
            logger.warning("[CODE_SETTINGS] Refusing to save quick settings with no project folder. CONSEQUENCE: the change is dropped; settings are per-project and there is no project to attach them to.")
            return
        }

        var store = load(from: defaults)
        let project = store.entries[key]?.project

        if settings.isDefault && project == nil {
            if store.entries.removeValue(forKey: key) != nil {
                logger.info("[CODE_SETTINGS] Cleared quick settings for '\(key)' — every value is back to the preset. CONSEQUENCE: the entry is removed rather than stored empty, so it no longer occupies a retention slot.")
            }
        } else {
            // The project's model and tools ride along untouched — "Reset" in the popover is about
            // the limits, not about forgetting the project.
            store.entries[key] = Entry(settings: settings, updatedAt: now, project: project)
        }

        write(store, key: key, defaults: defaults)
    }

    /// Stores what the project runs with — its model and tools. Unlike `save`, an empty state is
    /// still STORED: it records "this project was captured with the preset", which is what stops
    /// the next folder opened from inheriting the previous project's tools.
    static func saveProjectState(
        _ state: CodeProjectState,
        for projectPath: String?,
        defaults: UserDefaults,
        now: Date
    ) {
        guard let key = normalizedKey(projectPath) else {
            logger.warning("[CODE_SETTINGS] Refusing to save project state with no project folder. CONSEQUENCE: the model and tool choices are not remembered for any project.")
            return
        }
        var sanitized = state
        sanitized.model?.apiKey = nil   // belt-and-braces: a key must never reach UserDefaults

        var store = load(from: defaults)
        guard store.entries[key]?.project != sanitized else {
            logger.debug("[CODE_SETTINGS] '\(key)' unchanged — no write.")
            return
        }
        let settings = store.entries[key]?.settings ?? .default
        store.entries[key] = Entry(settings: settings, updatedAt: now, project: sanitized)
        write(store, key: key, defaults: defaults)
        logger.info("[CODE_SETTINGS] Remembered '\(key)' — model: \(sanitized.model?.modelName ?? "(none)"), \(sanitized.extraTools.count) extra tool(s), \(sanitized.presetToolOverrides.count) preset tool override(s).")
    }

    private static func write(_ store: Store, key: String, defaults: UserDefaults) {
        var store = store
        prune(&store)

        do {
            defaults.set(try JSONEncoder().encode(store), forKey: defaultsKey)
        } catch {
            logger.error("[CODE_SETTINGS] Failed to encode quick settings for '\(key)': \(error.localizedDescription). CONSEQUENCE: this change is lost and the project keeps its previously saved values — or the preset defaults if it had none.")
        }
    }

    // MARK: Internals

    struct Entry: Codable, Hashable {
        var settings: CodeQuickSettings
        var updatedAt: Date
        /// Optional so entries written before it existed still decode.
        var project: CodeProjectState?
    }

    struct Store: Codable, Hashable {
        var entries: [String: Entry] = [:]
    }

    /// Trailing slashes and `..` segments would key the same folder twice.
    static func normalizedKey(_ projectPath: String?) -> String? {
        guard let raw = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func load(from defaults: UserDefaults) -> Store {
        guard let data = defaults.data(forKey: defaultsKey) else { return Store() }
        do {
            return try JSONDecoder().decode(Store.self, from: data)
        } catch {
            // Do not delete the blob here: an unreadable record may be recoverable by a later build, and this read path
            // has not been asked to discard anything.
            logger.error("[CODE_SETTINGS] Stored quick settings could not be decoded: \(error.localizedDescription). CONSEQUENCE: every project falls back to preset defaults for this launch; the stored blob is left intact rather than reset, so nothing is permanently lost.")
            return Store()
        }
    }

    private static func prune(_ store: inout Store) {
        guard store.entries.count > maxRetainedProjects else { return }
        let ordered = store.entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
        let dropped = ordered.dropFirst(maxRetainedProjects)
        for (key, _) in dropped { store.entries.removeValue(forKey: key) }
        logger.notice("[CODE_SETTINGS] Pruned \(dropped.count) project(s) past the \(maxRetainedProjects)-project retention cap: \(dropped.map(\.key).joined(separator: ", ")). CONSEQUENCE: those projects revert to preset defaults next time they are opened; the most recently changed \(maxRetainedProjects) are kept.")
    }
}
