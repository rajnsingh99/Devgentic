// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NativeToolCatalog.swift
//  Devgentic
//
//  The single source of truth for which native tools exist.
//
//  Until 2026-07-31 there were two hand-maintained lists: a `switch` in
//  `AgentConnect.resolveNativeTool` deciding what RUNS, and a sequence of `registerNative(…)`
//  calls in `LocalToolManager` deciding what is OFFERED. 63 of them constructed the same struct
//  with the same expression in both files, and nothing checked they agreed.
//
//  The failure modes were asymmetric, which is why the drift only ever ran one way: forget the
//  registration and you get a working, INVISIBLE tool that nobody notices because it works;
//  forget the dispatch case and you get a visible tool that fails loudly the first time anyone
//  picks it. Over time that produced 11 unreachable tools, 25 dispatchable tools in no picker,
//  one struct dispatched under two names, and a split whose destructive half was selectable
//  while its harmless half was not — every tool bug found in the 2026-07-31 audit.
//
//  Both consumers now derive from `entries` below. Adding a tool is one line, in one place.
//
//  **Why entries store a closure rather than an instance.** `AgentToolFactory.wrap` is generic
//  over the concrete `T` so it can decode `T.Arguments`; a heterogeneous `[any DevgenticTool]`
//  would erase exactly the type it needs. `make` captures `T` at each call site, which is what
//  lets one list hold 71 different tool types.
//
//  **Why the closure takes a `UUID?`.** The shell tools need the conversation
//  (`run_command`, `start_background_task`, `get_task_output`, `stop_background_task`), to scope their tasks
//  so `bg_1` means one thing per conversation and one conversation cannot poll or stop another's
//  build. Passing `nil` yields the same tool without that state, which is what the Library needs
//  for metadata. The rest ignore the parameter. One uniform signature beats a special case.
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

    /// In the Library for Chat and Workflow profiles, but hidden when the Library is opened for a
    /// CODE profile, because the preset supplies something that supersedes it.
    ///
    /// `supersededBy` names the replacement, and it is the point of this case: the previous
    /// design carried these five names in a `Set` literal inside `CodeToolPreset`, so the fact
    /// that `edit_code` is hidden *because* `edit_code_single`/`edit_code_batch` exist lived in a
    /// comment rather than beside either tool. Offering both to a Code agent would hand it
    /// several shapes for one intent — the exact confusion the splits were introduced to prevent.
    case libraryExceptCode(supersededBy: String)

    /// Supplied by `CodeToolPreset` and deliberately absent from the Library — the intent-split
    /// tools (`edit_code_single`, `code_search_text`, `overwrite_file`, …) whose originals the
    /// Library offers instead. Surfacing both would hand the model several shapes for one intent.
    case codeOnly

    /// Runs, but is offered nowhere. **Nothing is `.hidden` today.** Kept because the state is
    /// reachable by accident and should have a name — and a reason attached — rather than being
    /// an unexplained absence. `ToolRegistryDriftTests` treats this as the documented exception.
    case hidden(reason: String)
}

/// What a tool needs before it can work, and where the user provides it.
///
/// Declared on the catalogue entry so a future tool that needs configuration (an API key, an
/// account, a path) opts in with one line and gets the Tool Library's "Setup" option, the
/// enable-block and the workflow warning for free.
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

    /// A PRECONDITION, not a policy: returns why this tool cannot work yet (no API key, no
    /// provider chosen), or nil when it is ready. Evaluated live, so it follows the user's
    /// settings. Nil for the vast majority of tools, which need nothing.
    ///
    /// ⚠️ This says "it would only return an error", never "it is risky": the Tool Library
    /// refuses to ENABLE a blocked tool and agent resolution does not offer it, because
    /// advertising a tool that can only fail wastes a slot and invites retry loops. It is
    /// unrelated to `HITLRiskTier` / `ToolCapability`, which label and never gate.
    let setup: ToolSetup?

    private let buildAgentTool: @Sendable (UUID?, Bool, TimeInterval?, String?) -> AgentTool
    private let buildExecutable: @Sendable () -> any ExecutableTool

    /// Builds an entry from a tool factory, capturing the concrete type.
    ///
    /// `name` and `category` are read from a probe instance built once here. Tools are cheap
    /// value types whose initialisers do no work, so this costs nothing and keeps the metadata
    /// honest — it is the tool's own answer, not a string repeated in the catalogue.
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

    /// Every native tool the app can run. **This is the list.** A tool absent here cannot be
    /// dispatched and cannot be offered; a tool present here is automatically both, according to
    /// its `visibility`.
    ///
    /// Order is presentational only — lookup is by name via `entry(named:)`.
    static let entries: [NativeToolEntry] = [
        // MARK: Offered in the Tool Library (71)
        .make(.library) { _ in UpdateSkillTool() },
        .make(.library) { _ in ListDirectoryTool() },
        .make(.library) { _ in ReadFileTool() },
        // ⚠️ `write_file` is gone (2026-09-24): superseded by `create_new_file` / `overwrite_file`,
        // which are now offered in the Tool Library for all profiles.
        .make(.library) { _ in DeleteFileTool() },
        .make(.library) { _ in MoveFileTool() },
        .make(.library) { _ in CopyFileTool() },
        .make(.library) { _ in CreateFolderTool() },
        // ⚠️ `execute_shell` is gone (2026-09-24): a duplicate of `run_command`. No rename map, for
        // the reasons given at `batch_command` below.
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
        // ⚠️ `grep_files` is gone (2026-09-24): superseded by `code_search_text`,
        // which provides structured regex and literal search across files and directories.
        .make(.library) { _ in PreviewFileTool() },
        .make(.library) { _ in GetFileHashTool() },
        // ⚠️ `edit_code` is gone (2026-09-24): superseded by `edit_code_single` / `edit_code_batch`,
        // which are now offered in the Tool Library for all profiles.
        // ⚠️ `code_search` is gone (2026-09-24): superseded by `code_search_text` / `code_search_symbol` /
        // `code_search_files`, which are now offered in the Tool Library for all profiles.
        .make(.library) { _ in GlobFilesTool() },
        .make(.library) { _ in FindDefinitionTool() },
        // ⚠️ `batch_command` IS GONE FROM THIS CATALOGUE. It was never two behaviours — its `call`
        // was a two-line dispatcher over the same `runForeground` / `startBackground` statics these
        // two use, so `run_command` was a literal duplicate of `batch_command(background: false)`.
        // Keeping both meant chat and Code were offered different names for identical work, and the
        // observer tools below had to describe a starter that differed by mode.
        //
        // ⚠️ `BatchCommandTool` the TYPE remains: it owns `precheck`, `runForeground`,
        // `startBackground` and `effectiveTimeout`, which both tools below call.
        // Only its catalogue entry is withdrawn, so no profile can select it any more.
        //
        // ⚠️ NO RENAME MAP. One was built and then deliberately removed: the only seeded tool lists
        // (`CodeToolPreset`, `OnboardingToolPreset`) are built from this catalogue by name, so a
        // profile created after this withdrawal CANNOT contain the old name, and
        // with no released users the only holders were local development profiles. A standing
        // "withdrawn names resolve to something else" mechanism is a first-party cousin of the
        // guess-by-name fallback `resolveExecutableTools` deleted on purpose — keeping one invites
        // reaching for it instead of migrating properly. A stored name that no longer exists is
        // reported by the ⚠️ NOT RESOLVED error, which is the honest outcome.
        .make(.library) { RunCommandTool(conversationID: $0) },
        .make(.library) { StartBackgroundTaskTool(conversationID: $0) },
        // The three that make `background: true` worth calling. Without them the flag starts work
        // nobody can observe, which is not a capability. Conversation-scoped for the same reason
        // `batch_command` now is.
        .make(.library) { CommandOutputTool(conversationID: $0) },
        .make(.library) { CommandStopTool(conversationID: $0) },
        // ⚠️ `create_file` is gone (2026-09-24): superseded by `create_new_file` / `overwrite_file`,
        // which are now offered in the Tool Library for all profiles.
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

    /// Name → entry. Built once; `resolveNativeTool` is a lookup in this, not a 100-line switch.
    ///
    /// A duplicate name would silently drop one entry, which is the shape of the old
    /// `read_contacts` bug (one struct dispatched under two names), so the build order is
    /// asserted to be lossless rather than trusted.
    static let byName: [String: NativeToolEntry] = {
        var map: [String: NativeToolEntry] = [:]
        for entry in entries { map[entry.name] = entry }
        if map.count != entries.count {
            // `assert` is compiled OUT of release builds, so a duplicate name would silently
            // drop a tool in exactly the builds users run. This is the `read_contacts` bug's
            // shape (one struct, two names) and it must be visible in a field log.
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

    /// The tools `LocalToolManager` registers, and therefore what the Tool Library and the
    /// workflow Action-node picker show.
    ///
    /// `.libraryExceptCode` is included: those tools ARE in the Library — they are filtered out
    /// later, and only when the Library is opened for a Code profile. Registration is about
    /// existence; `hiddenFromCodeLibrary` is about that one context.
    static var libraryTools: [NativeToolEntry] {
        entries.filter {
            switch $0.visibility {
            case .library, .libraryExceptCode: return true
            case .codeOnly, .hidden:           return false
            }
        }
    }

    /// Library tools a CODE profile should not see, because the preset supersedes them.
    ///
    /// `CodeToolPreset.hiddenToolNames` used to carry these as a `Set` literal, which meant the
    /// reason each was hidden lived in a comment above the list rather than beside the tool. Now
    /// the entry states it, and the preset asks.
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

/// Name, description and argument schema for a tool `AgentConnect` builds per run.
///
/// ⚠️⚠️ METADATA ONLY — deliberately no `agentTool(...)` builder. These tools genuinely cannot
/// live in `entries`: each needs run-scoped data to CONSTRUCT (the run's chat history, its skill
/// manifests, a Code profile's project folder), which a startup catalogue cannot supply, and
/// `ToolRegistryDriftTests` fails the build if one appears there. Giving this type a builder
/// would re-open exactly that door.
///
/// But the data they need affects their BEHAVIOUR, not their schema: all five declare a constant
/// `description` and `parameterSchema`. So they can be PRICED from a probe built with empty data
/// even though they cannot be dispatched from one — and until 2026-09-20 nothing priced them, so
/// every one cost 0 in the fit gauge.
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

    /// Every tool `AgentConnect` injects outside the catalogue. **This is the list.**
    ///
    /// It used to exist only as `ToolRegistryDriftTests.injectedOutsideCatalog` — a hand-written
    /// `Set` in a TEST file, which is why nothing in production could price these or show them in
    /// a loadout. That test now derives its list from here, so this is one list where there were
    /// two, not a third one.
    ///
    /// ⚠️ `ask_user` is described in its RICH form. Its schema is the one thing here that varies
    /// at runtime — `AgentConnect` drops `options`/`multiline` for small and tiny models, which
    /// fumble them — so no single entry is exact. Rich is the larger of the two (456 vs 195
    /// chars), and over-reading is the safe direction for a budget on the models with the
    /// smallest windows.
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

    /// Tools renamed in Build 102.6 (2026-09-25, commit 3d80ff6), old → new.
    ///
    /// ⚠️ DIAGNOSTICS ONLY — this is NOT an alias table. Nothing resolves an old name to the new
    /// tool at run time (`ToolNameResolver` does not read this): there are no users to keep working,
    /// and a silent alias would hide exactly the stale reference the user needs to fix. It exists so
    /// that instructions written against the old vocabulary — Agent 3's "use fs_smart_search first"
    /// was the case that found this — get a precise "renamed to X" advisory instead of a vague
    /// "unknown tool". Every pair was verified against that commit's diff.
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
