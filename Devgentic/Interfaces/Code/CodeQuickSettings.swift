// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeQuickSettings.swift
//  Devgentic
//
//  Per-PROJECT execution settings for the Code interface, and the UserDefaults store behind them.
//

import Foundation

private let logger = DGLogger(category: "CodeQuickSettings")

// MARK: - Settings

/// User overrides for one project folder. Every field is optional and `nil` means "use the
/// preset default" — the struct never restates a default, so changing `CodeSessionManager`'s
/// baked values changes what an untouched project does.
///
/// ⚠️ SCOPED PER PROJECT, not globally and not per conversation. "Auto-approve file edits" is a
/// statement about a folder you trust, and carrying it into the next project you open would grant
/// a permission nobody granted. The trade is that a setting does not follow you between projects;
/// that is the intended direction.
struct CodeQuickSettings: Codable, Hashable, Sendable {

    /// Reasoning cycles before the loop stops. `nil` → NO cap (the Code default since 2026-09-25);
    /// a value is clamped to `CodeSessionManager.iterationCapRange` when applied.
    var maxIterations: Int?

    /// COMPUTE budget in seconds — time parked awaiting a human is excluded by
    /// `ComputeTimeoutSentinel`. `nil` → `CodeSessionManager.presetExecutionTimeout`. `.some(0)` means no limit.
    var executionTimeout: TimeInterval?

    // ⚠️ `toolConfirmations` (per-tool Ask/Auto) WAS REMOVED 2026-09-25. It existed because the
    // preset tools were hidden from the Tool Library for a Code profile, which made this popover the
    // only place to set them. They are in the Library now, with Auto Run / Ask First, so there were
    // two controls for one fact — and this one was applied LAST on every run, silently undoing a
    // Library choice. Ask/Auto now lives on the profile's tool, remembered per project by
    // `CodeToolOverride.requiresConfirmation`. A stored value under the old key is ignored on decode.

    /// Extended thinking. `nil` → off, which is the Code default: the ReAct loop pays the
    /// thinking cost once per ITERATION, so it multiplies by `maxIterations` rather than being
    /// paid once per turn. Offered only for models detection reports as capable.
    var thinkingEnabled: Bool?

    /// Context window in tokens (Ollama only). `nil` → `CodeSessionManager.presetContextCap`-capped
    /// model window. The whole Code prompt and its tools ride in this window on every step, so a
    /// small one fills before any work is done (seen on device 2026-09-24: 5.5K of 8K).
    var contextTokens: Int?

    /// After each answer, one extra model call proposes facts for project memory, which the user
    /// accepts or dismisses (`ProjectMemorySuggester`). `nil` → off, the default: it costs a model
    /// call per answer, which on a local model holds the GPU for a few seconds.
    var suggestMemories: Bool?

    /// True when nothing has been changed from the preset — used to decide whether the toolbar
    /// button shows a "modified" dot.
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

/// What a project remembers besides its quick settings: the model it last ran with and the tools
/// it was given (2026-09-24).
///
/// ⚠️ Kept APART from `CodeQuickSettings` on purpose. The quick-settings popover's "Reset" writes
/// `CodeQuickSettings.default`, and that must reset the limits — not forget the project's model
/// or the MCP tools the user enabled for it.
///
/// Stored as a DELTA against `CodeToolPreset`, never as the full tool list: preset tools carry
/// large parameter schemas, and this blob lives in UserDefaults for up to
/// `CodeQuickSettingsStore.maxRetainedProjects` projects.
struct CodeProjectState: Codable, Hashable, Sendable {

    /// The model this project last ran with. `apiKey` is ALWAYS nil here — keys stay in the
    /// Keychain (`CodeProviderKeys`), never in UserDefaults.
    var model: ProviderConfig?

    /// Tools outside the preset that the user enabled for this project (built-ins from the Tool
    /// Library, MCP tools), stored whole because there is no preset to diff them against.
    var extraTools: [Tool] = []

    /// Changes to PRESET tools — Ask/Auto included since 2026-09-25 — keyed by tool name.
    /// Absent = the preset's value.
    var presetToolOverrides: [String: CodeToolOverride] = [:]

    var isEmpty: Bool { model == nil && extraTools.isEmpty && presetToolOverrides.isEmpty }
}

/// A preset tool's user-editable fields, stored only for a tool where at least one of them differs
/// from `CodeToolPreset`.
///
/// ⚠️ A full snapshot of the four fields, not a per-field delta: a delta needs "changed to nil"
/// (`TimeInterval??`), and JSON cannot tell `.some(nil)` from absent — a cleared timeout would come
/// back as the preset's.
struct CodeToolOverride: Codable, Hashable, Sendable {
    var timeout: TimeInterval?
    var timeoutMessage: String?
    var isFavorite: Bool
    var cutStrategy: ContextCutStrategy?
    /// Ask First (`true`) or Auto Run (`false`), as set in the Tool Library (2026-09-25).
    ///
    /// Optional ONLY so an override saved before this field existed still decodes; `nil` there
    /// means "the preset's". Every override written now carries it. Without it here, an Ask/Auto
    /// choice made in the Library held for the current project and reverted to the preset on the
    /// next project switch.
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
///
/// ⚠️⚠️ WHY NOT ON THE PROFILE. There is ONE permanent Code profile for every project, so it can
/// only ever hold the CURRENT project's values — it is a projection of this store, loaded when a
/// folder is opened (`CodeSessionManager.updateProjectPath`) and captured back when the user
/// leaves it. (Until 2026-09-24 the row was also deleted on every Home press; this store is what
/// survived that, and it is still the only per-project record.)
///
/// Keyed by ABSOLUTE PATH. Renaming or moving a project folder therefore loses its settings and
/// it reverts to defaults. That is the honest failure: the alternative (following the folder by
/// inode or bookmark) would silently carry an auto-approve grant to a directory the user may have
/// replaced.
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

    /// Stores `settings` for `projectPath`, pruning the least recently touched projects past the
    /// retention cap.
    ///
    /// A settings value equal to the preset default REMOVES the entry rather than storing an empty
    /// record, so "reset to defaults" does not consume a retention slot and cannot evict a project
    /// the user actually configured.
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
            // ⚠️ Do NOT delete the blob here. An unreadable record is recoverable by a later build
            // that understands it; clearing it makes the loss permanent, and this runs on a read
            // path where the user has not asked for anything to be discarded.
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
