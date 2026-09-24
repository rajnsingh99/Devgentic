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

    /// Reasoning cycles before the loop stops. `nil` → the preset's 20.
    var maxIterations: Int?

    /// COMPUTE budget in seconds — time parked awaiting a human is excluded by
    /// `ComputeTimeoutSentinel`. `nil` → `CodeSessionManager.presetExecutionTimeout`. `.some(0)` means no limit.
    var executionTimeout: TimeInterval?

    /// Per-tool confirmation overrides, keyed by tool name. `true` = ask first, `false` = run
    /// without asking. A tool absent from this map keeps whatever `CodeToolPreset` declares.
    ///
    /// ⚠️ Only preset tools belong here. `CodeToolPreset`'s tools are hidden from the Tool
    /// Library for a Code profile (`ToolLibraryContainerView.hiddenToolNames`), so this map is
    /// the ONLY surface that can set their Ask/Auto state. Non-preset tools keep using the
    /// Library, and `mergePresetTools` leaves them alone.
    var toolConfirmations: [String: Bool] = [:]

    /// Extended thinking. `nil` → off, which is the Code default: the ReAct loop pays the
    /// thinking cost once per ITERATION, so it multiplies by `maxIterations` rather than being
    /// paid once per turn. Offered only for models detection reports as capable.
    var thinkingEnabled: Bool?

    /// True when nothing has been changed from the preset — used to decide whether the toolbar
    /// button shows a "modified" dot.
    var isDefault: Bool {
        maxIterations == nil
            && executionTimeout == nil
            && toolConfirmations.isEmpty
            && thinkingEnabled == nil
    }

    static let `default` = CodeQuickSettings()
}

// MARK: - Store

/// Persists `CodeQuickSettings` per project folder in UserDefaults.
///
/// ⚠️⚠️ WHY NOT ON THE PROFILE. The obvious home is the `.code` BackendProfile's `AgentConfig`,
/// which already carries `maxIterations` and `executionTimeout`. It cannot go there:
/// `CodeSessionManager.resetSession()` DELETES the profile row outright, and it runs on every
/// Home-button press via `ConversationManagementCoordinator.deselectConversationAndShowWelcome`.
/// A user who raised their iteration cap would find it silently back at 20 after clicking Home,
/// with nothing having reported a change — the same shape of defect as a setting that survives
/// only until you next look at it. UserDefaults outlives the profile row, so the settings are
/// re-applied onto whatever profile `ensureCodeProfile()` mints next.
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

        if settings.isDefault {
            if store.entries.removeValue(forKey: key) != nil {
                logger.info("[CODE_SETTINGS] Cleared quick settings for '\(key)' — every value is back to the preset. CONSEQUENCE: the entry is removed rather than stored empty, so it no longer occupies a retention slot.")
            }
        } else {
            store.entries[key] = Entry(settings: settings, updatedAt: now)
        }

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
