// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeToolCatalog.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "NativeToolCatalog")

/// Where a tool is offered. Availability is DATA on the entry, not a second list somewhere else:
/// `LocalToolManager` registers `.library`, and `CodeToolPreset` supplies `.codeOnly` to Code
/// profiles while hiding them from the Library.
enum NativeToolVisibility: Sendable, Equatable {
    /// Selectable in the Tool Library, and therefore in the workflow Action-node picker too
    /// (both read `UnifiedToolStore`, which is built from `LocalToolManager`).
    case library

    /// In the Library for Chat and Workflow profiles, but hidden when the Library is opened for a Code profile because
    /// the preset supplies something that supersedes it. `supersededBy` names the replacement, so offering both to a Code
    /// agent (several shapes for one intent) is avoided.
    case libraryExceptCode(supersededBy: String)

    /// Supplied by `CodeToolPreset` and absent from the Library: the intent-split tools whose originals the Library
    /// offers instead. Surfacing both would give the model several shapes for one intent.
    case codeOnly

    /// Runs, but is offered nowhere. **Nothing is `.hidden` today.** Kept because the state is
    /// reachable by accident and should have a name — and a reason attached — rather than being
    /// an unexplained absence. `ToolRegistryDriftTests` treats this as the documented exception.
    case hidden(reason: String)
}

/// What a tool needs before it can work, and where the user provides it. Declared on the catalogue entry so a tool
/// needing configuration (API key, account, path) gets the Setup option, enable-block and workflow warning.
struct ToolSetup: Sendable {
    /// Why the tool cannot work yet, or nil when it is ready. Evaluated live.
    let blocker: @Sendable () -> String?
    /// The Settings pane where the user finishes setup.
    let settings: SettingsCategory
}

/// One tool's identity, availability, and how to build it for each consumer.
struct NativeToolEntry: Sendable {
    let name: String
    let category: String
    let visibility: NativeToolVisibility

    /// A precondition, not a policy: returns why this tool cannot work yet (no API key, no provider), or nil when ready.
    /// Evaluated live; nil for most tools. The Tool Library refuses to enable a blocked tool and agent resolution does
    /// not offer it. Unrelated to `HITLRiskTier` / `ToolCapability`, which label and never gate.
    let setup: ToolSetup?

    private let buildAgentTool: @Sendable (UUID?, Bool, TimeInterval?, String?) -> AgentTool
    private let buildExecutable: @Sendable () -> any ExecutableTool

    /// Builds an entry from a tool factory, capturing the concrete type. `name` and `category` come from a probe instance
    /// built once here; tools are cheap value types, so the metadata is the tool's own answer.
    static func make<T: DevgenticTool>(
        _ visibility: NativeToolVisibility,
        setup: ToolSetup? = nil,
        _ build: @escaping @Sendable (UUID?) -> T
    ) -> NativeToolEntry {
        let probe = build(nil)
        return NativeToolEntry(
            name: probe.name,
            category: probe.category,
            visibility: visibility,
            setup: setup,
            buildAgentTool: { conversationID, requiresConfirmation, timeout, timeoutMessage in
                AgentToolFactory.wrap(
                    build(conversationID),
                    requiresConfirmation: requiresConfirmation,
                    timeout: timeout,
                    timeoutMessage: timeoutMessage
                )
            },
            buildExecutable: { NativeToolWrapper(nativeTool: build(nil)) }
        )
    }

    /// The executor's view: a runnable, type-erased tool carrying this profile's settings.
    func agentTool(
        conversationID: UUID?,
        requiresConfirmation: Bool,
        timeout: TimeInterval? = nil,
        timeoutMessage: String? = nil
    ) -> AgentTool {
        buildAgentTool(conversationID, requiresConfirmation, timeout, timeoutMessage)
    }

    /// The UI's view: name, description, category and schema for the Tool Library.
    func executable() -> any ExecutableTool { buildExecutable() }
}

enum NativeToolCatalog {

    /// Every native tool the app can run. A tool absent here cannot be dispatched or offered; one present is both,
    /// according to its `visibility`. Order is presentational only; lookup is by name via `entry(named:)`.
    static let entries: [NativeToolEntry] = [
        // MARK: Offered in the Tool Library (71)
        .make(.library) { _ in UpdateSkillTool() },
        .make(.library) { _ in ListDirectoryTool() },
        .make(.library) { _ in ReadFileTool() },
        .make(.library) { _ in DeleteFileTool() },
        .make(.library) { _ in MoveFileTool() },
        .make(.library) { _ in CopyFileTool() },
        .make(.library) { _ in CreateFolderTool() },
        .make(.library) { _ in OpenApplicationTool() },
        .make(.library) { _ in RunAppleScriptTool() },
        .make(.library) { _ in GetSystemStatsTool() },
        .make(.library) { _ in WatchFolderTool() },
        .make(.library) { _ in SmartSearchTool() },
        .make(.library) { _ in ReadMetadataTool() },
        .make(.library) { _ in OrganizeBatchTool() },
        .make(.library) { _ in ReadScreenStateTool() },
        .make(.library) { _ in ClickUIElementTool() },
        .make(.library) { _ in ManageWindowsTool() },
        .make(.library) { _ in ManageCalendarTool() },
        .make(.library) { _ in DeleteCalendarEventTool() },
        .make(.library) { _ in ManageRemindersTool() },
        .make(.library) { _ in DeleteReminderTool() },
        .make(.library) { _ in ManageContactsTool() },
        .make(.library) { _ in RunMacShortcutTool() },
        .make(.library) { _ in ManageClipboardTool() },
        .make(.library) { _ in PushLocalNotificationTool() },
        .make(.library) { _ in GetPowerStateTool() },
        .make(.library) { _ in ManageProcessesTool() },
        .make(.library) { _ in KillProcessTool() },
        .make(.library) { _ in ManageSafariTabsTool() },
        .make(.library) { _ in ReadSafariBookmarksTool() },
        .make(.library) { _ in ExtractSafariReaderViewTool() },
        .make(.library) { _ in ScrollUITool() },
        .make(.library) { _ in ReadUIElementTreeTool() },
        .make(.library) { _ in CheckNetworkStatusTool() },
        .make(.library) { _ in HTTPRequestTool() },
        .make(.library, setup: ToolSetup(blocker: { WebSearchConfig().setupBlocker }, settings: .webSearch)) { _ in WebSearchTool() },
        .make(.library) { _ in DNSLookupTool() },
        .make(.library) { _ in ManageAudioTool() },
        .make(.library) { _ in MediaControlTool() },
        .make(.library) { _ in ToggleDarkModeTool() },
        .make(.library) { _ in ToggleDoNotDisturbTool() },
        .make(.library) { _ in GetWiFiInfoTool() },
        .make(.library) { _ in ManageBluetoothTool() },
        .make(.library) { _ in PreviewFileTool() },
        .make(.library) { _ in GetFileHashTool() },
        .make(.library) { _ in GlobFilesTool() },
        .make(.library) { _ in FindDefinitionTool() },
        // `batch_command` is not in the catalogue; `BatchCommandTool` remains as the type owning `precheck`,
        // `runForeground`, `startBackground` and `effectiveTimeout`. A missing stored name is reported as NOT RESOLVED.
        .make(.library) { RunCommandTool(conversationID: $0) },
        .make(.library) { StartBackgroundTaskTool(conversationID: $0) },
        // The observer tools that make `background: true` worth calling; conversation-scoped like the starters.
        .make(.library) { CommandOutputTool(conversationID: $0) },
        .make(.library) { CommandStopTool(conversationID: $0) },
        .make(.library) { _ in FileOverviewTool() },
        .make(.library) { _ in CodebaseMapTool() },
        .make(.library) { _ in ScreenCaptureTool() },
        .make(.library) { _ in FinderTagsTool() },
        .make(.library) { _ in ReplaceFinderTagsTool() },
        .make(.library) { _ in DiskUsageTool() },
        .make(.library) { _ in DisplayManagementTool() },
        .make(.library) { _ in OpenSystemSettingsTool() },
        .make(.library) { _ in LoginItemsTool() },
        .make(.library) { _ in ExternalDevicesTool() },
        .make(.library) { _ in AppleNotesTool() },

        // MARK: - Precision Coding Tools (Shared between Chat and Code)
        .make(.library) { _ in DiffFilesTool() },
        .make(.library) { _ in GitTool() },
        .make(.library) { _ in EditCodeSingleTool() },
        .make(.library) { _ in EditCodeBatchTool() },
        .make(.library) { _ in CodeSearchTextTool() },
        .make(.library) { _ in CodeSearchSymbolTool() },
        .make(.library) { _ in CodeSearchFilesTool() },
        .make(.library) { _ in CreateNewFileTool() },
        .make(.library) { _ in OverwriteFileTool() },
    ]

    /// Name to entry, built once; `resolveNativeTool` is a lookup in this. A duplicate name would silently drop an entry,
    /// so the build is checked to be lossless.
    static let byName: [String: NativeToolEntry] = {
        var map: [String: NativeToolEntry] = [:]
        for entry in entries { map[entry.name] = entry }
        if map.count != entries.count {
            // `assert` is compiled out of release builds, so a duplicate name would silently drop a tool in shipped builds; log
            // it so it shows in a field log.
            let dupes = Dictionary(grouping: entries, by: \.name).filter { $0.value.count > 1 }.keys.sorted()
            logger.error("[TOOLCATALOG] ⚠️ duplicate tool name(s) \(dupes) — \(entries.count) entries collapsed to \(map.count). The later entry wins; the earlier tool is unreachable.")
            assertionFailure("NativeToolCatalog has duplicate tool names: \(dupes)")
        }
        return map
    }()

    static func entry(named name: String) -> NativeToolEntry? { byName[name] }

    /// Why the named built-in cannot work yet, or nil when it is ready (or needs nothing).
    static func setupBlocker(for name: String) -> String? { byName[name]?.setup?.blocker() }

    /// The Settings pane that finishes the named tool's setup, or nil if it needs none. Unlike
    /// `setupBlocker(for:)` this is non-nil even once the tool IS configured, so the Library can
    /// keep offering "Setup" for changing the configuration.
    static func setupSettings(for name: String) -> SettingsCategory? { byName[name]?.setup?.settings }

    /// The tools `LocalToolManager` registers, and so what the Tool Library and the workflow Action-node picker show.
    /// `.libraryExceptCode` is included: registration is about existence, and `hiddenFromCodeLibrary` filters only for a
    /// Code profile.
    static var libraryTools: [NativeToolEntry] {
        entries.filter {
            switch $0.visibility {
            case .library, .libraryExceptCode: return true
            case .codeOnly, .hidden:           return false
            }
        }
    }

    /// Library tools a Code profile should not see, because the preset supersedes them; each entry states its own reason.
    static var hiddenFromCodeLibrary: Set<String> {
        Set(entries.compactMap {
            if case .libraryExceptCode = $0.visibility { return $0.name }
            return nil
        })
    }

    /// Tools only a Code profile gets — the intent-splits, absent from the Library entirely.
    static var codeOnlyTools: [NativeToolEntry] { entries.filter { $0.visibility == .codeOnly } }
}

// MARK: - Control-plane tools

// Why: do not add an `agentTool(...)` builder; `ToolRegistryDriftTests` fails the build if such a tool appears in
// `entries`.
/// Name, description and argument schema for a tool `AgentConnect` builds per run. Metadata only, with no builder:
/// these tools need run-scoped data to construct, but their schema is constant, so they can be priced from a probe.
struct InjectedToolMetadata: Sendable {
    let name: String
    let description: String
    let parameters: ToolParameters

    /// Reads the metadata off a probe instance, so the values are the tool's own answer rather
    /// than strings repeated here — the same discipline as `NativeToolEntry.make`.
    static func describe<T: DevgenticTool>(_ probe: T) -> InjectedToolMetadata {
        InjectedToolMetadata(name: probe.name, description: probe.description, parameters: probe.parameterSchema)
    }
}

extension NativeToolCatalog {

    /// Every tool `AgentConnect` injects outside the catalogue; `ToolRegistryDriftTests` derives its list from here.
    /// `ask_user` is described in its rich form, the larger of its two schemas, since over-reading is the safe direction
    /// for a budget.
    static let injectedTools: [InjectedToolMetadata] = [
        .describe(FinalAnswerTool()),
        .describe(AskUserTool(richFields: true)),
        .describe(ConversationHistoryTool(chatHistory: [], correlation: "")),
        .describe(LoadSkillTool(manifests: [])),
        .describe(RememberTool(projectPath: "", conversationID: nil)),
        .describe(ForgetTool(projectPath: "")),
        .describe(RecallTool(projectPath: "")),
    ]

    static var injectedToolNames: Set<String> { Set(injectedTools.map(\.name)) }

    /// Every native tool name the catalogue can register.
    static var allToolNames: Set<String> { Set(byName.keys) }

    // MARK: - Retired names (diagnostics only)

    /// Tools that were renamed, old to new; diagnostics only, not an alias table (`ToolNameResolver` does not read it).
    /// Lets instructions written against an old name get a precise "renamed to X" advisory instead of "unknown tool".
    static let renamedTools: [String: String] = [
        "fs_smart_search":    "spotlight_search",
        "fs_read_metadata":   "read_file_metadata",
        "fs_organize_batch":  "batch_move_files",
        "fs_watch_folder":    "watch_folder",
        "media_control":      "control_media",
        "command_output":     "get_task_output",
        "command_stop":       "stop_background_task",
        "codebase_map":       "project_tree",
        "git_tool":           "git",
        "finder_tags":        "manage_finder_tags",
        "disk_usage":         "get_disk_usage",
        "display_management": "manage_displays",
        "login_items":        "manage_login_items",
        "external_devices":   "list_external_devices",
        "apple_notes":        "manage_apple_notes",
        "read_screen_state":  "extract_screen_text",
    ]

    /// Tools deleted with no direct successor. Diagnostics only, as above.
    static let removedTools: Set<String> = ["execute_shell"]
}
