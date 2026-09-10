// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
//  lets one list hold 72 different tool types.
//
//  **Why the closure takes a `UUID?`.** Exactly one tool — `execute_shell` — needs the
//  conversation to persist its working directory across calls. Passing `nil` yields the same
//  tool without directory memory, which is what the Library needs for metadata. The other 71
//  ignore the parameter. One uniform signature beats a special case.
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

/// One tool's identity, availability, and how to build it for each consumer.
struct NativeToolEntry: Sendable {
    let name: String
    let category: String
    let visibility: NativeToolVisibility

    private let buildAgentTool: @Sendable (UUID?, Bool, TimeInterval?, String?) -> AgentTool
    private let buildExecutable: @Sendable () -> any ExecutableTool

    /// Builds an entry from a tool factory, capturing the concrete type.
    ///
    /// `name` and `category` are read from a probe instance built once here. Tools are cheap
    /// value types whose initialisers do no work, so this costs nothing and keeps the metadata
    /// honest — it is the tool's own answer, not a string repeated in the catalogue.
    static func make<T: DevgenticTool>(
        _ visibility: NativeToolVisibility,
        _ build: @escaping @Sendable (UUID?) -> T
    ) -> NativeToolEntry {
        let probe = build(nil)
        return NativeToolEntry(
            name: probe.name,
            category: probe.category,
            visibility: visibility,
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
        // MARK: Offered in the Tool Library (63)
        .make(.library) { _ in ListDirectoryTool() },
        .make(.library) { _ in ReadFileTool() },
        .make(.libraryExceptCode(supersededBy: "the preset's create_new_file / overwrite_file")) { _ in WriteFileTool() },
        .make(.library) { _ in DeleteFileTool() },
        .make(.library) { _ in MoveFileTool() },
        .make(.library) { _ in CopyFileTool() },
        .make(.library) { _ in CreateFolderTool() },
        .make(.libraryExceptCode(supersededBy: "batch_command")) { TerminalTool(conversationID: $0) },
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
        .make(.library) { _ in DNSLookupTool() },
        .make(.library) { _ in ManageAudioTool() },
        .make(.library) { _ in MediaControlTool() },
        .make(.library) { _ in ToggleDarkModeTool() },
        .make(.library) { _ in ToggleDoNotDisturbTool() },
        .make(.library) { _ in GetWiFiInfoTool() },
        .make(.library) { _ in ManageBluetoothTool() },
        .make(.library) { _ in GrepFilesTool() },
        .make(.library) { _ in PreviewFileTool() },
        .make(.library) { _ in GetFileHashTool() },
        .make(.libraryExceptCode(supersededBy: "edit_code_single / edit_code_batch")) { _ in EditCodeTool() },
        .make(.libraryExceptCode(supersededBy: "code_search_text / code_search_symbol / code_search_files")) { _ in CodeSearchTool() },
        .make(.library) { _ in GlobFilesTool() },
        .make(.library) { _ in FindDefinitionTool() },
        .make(.library) { _ in BatchCommandTool() },
        .make(.libraryExceptCode(supersededBy: "create_new_file / overwrite_file")) { _ in CreateFileTool() },
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

        // MARK: Code interface only — hidden from the Library by CodeToolPreset (9)
        .make(.codeOnly) { _ in DiffFilesTool() },
        .make(.codeOnly) { _ in GitTool() },
        .make(.codeOnly) { _ in EditCodeSingleTool() },
        .make(.codeOnly) { _ in EditCodeBatchTool() },
        .make(.codeOnly) { _ in CodeSearchTextTool() },
        .make(.codeOnly) { _ in CodeSearchSymbolTool() },
        .make(.codeOnly) { _ in CodeSearchFilesTool() },
        .make(.codeOnly) { _ in CreateNewFileTool() },
        .make(.codeOnly) { _ in OverwriteFileTool() },
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
