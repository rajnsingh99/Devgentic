// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerTab.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import CodeEditSourceEditor

/// How the Code Viewer panel occupies the window: `overlay`, `split` or `full`, mutually exclusive. `.split` is
/// experimental: a trailing inset on the chat area, not a re-parent, so the panel keeps its view identity across
/// modes.
enum CodeViewerPresentation: String {
    /// The historic floating panel: overlays the chat's right edge; chat keeps full width.
    case overlay
    /// Side-by-side: the chat insets by the panel width and reflows next to it.
    case split
    /// Panel fills the content area (chat fully covered; sidebar stays reachable).
    case full
}

/// Per-tab editor view state (cursor positions, scroll offset, find-panel text) for the Code Viewer's `SourceEditor`,
/// keyed by tab id. Held outside `CodeViewerTab` and not observed: it must outlive the panel, and per-keystroke caret
/// writes would invalidate the whole window body.
@MainActor
final class CodeViewerEditorStateStore {
    private var statesByTab: [UUID: SourceEditorState] = [:]

    /// The stored state, or a fresh one — a tab that has never been shown starts at the top.
    func state(for tabID: UUID) -> SourceEditorState { statesByTab[tabID] ?? SourceEditorState() }

    func setState(_ state: SourceEditorState, for tabID: UUID) { statesByTab[tabID] = state }

    /// Drops state for tabs the user closed; not called on a conversation switch, where tabs are stashed and must return
    /// where they were.
    func forget(tabIDs: [UUID]) {
        for id in tabIDs { statesByTab.removeValue(forKey: id) }
    }

    /// Number of tabs with retained editor state — for tests and leak checks only.
    var retainedTabCount: Int { statesByTab.count }
}

/// One open document in the Code Viewer's tab strip. Tabs are persistent: opening a code block adds a tab, and tabs
/// survive the panel being minimized. A tab carries no diff state; changes are shown in the tool row that produced
/// them.
struct CodeViewerTab: Identifiable, Equatable {
    let id: UUID

    /// The code this tab displays. Replaced in place (new `snippet.id`, which drives the reload) when an agent write
    /// lands or a re-open finds the source block changed; not replaced on save (see `isDirty`).
    var snippet: CodeSnippet

    /// The linked source filename, when the block was resolved to a user-attached file (or
    /// the raw marker name when unresolved). Nil for ad-hoc opens (speech, user-file card).
    /// Drives the tab's display title.
    var fileName: String? = nil

    /// Absolute path, for tabs opened from a real file (agent timeline rows, live writes).
    /// IDENTITY for those tabs — matching on `fileName` alone merges `src/Main.java` with
    /// `test/Main.java` into one tab. Nil for chat-block tabs, which have no path.
    var filePath: String? = nil

    // MARK: Editing state
    // `snippet.code` is immutable once the tab opens ("what the chat block said"): dedup, click-to-tab and re-open all
    // compare against it, so user edits live here.

    /// The editor buffer when it has diverged from the restore point (`lastSavedBuffer`,
    /// else `snippet.code`). Nil ⟺ the buffer matches the restore point ⟺ not dirty.
    /// Kept in the tab (not the panel) so drafts survive tab switches and minimize.
    var editedCode: String? = nil

    /// Buffer content at the last successful save, the dirty-comparison restore point. Distinct from `lastSavedDisk`
    /// because the write path may append a trailing newline the buffer lacks.
    var lastSavedBuffer: String? = nil

    /// The bytes this tab last knew to be on disk: the drift-guard baseline for the next save (normally our own last
    /// write). Also set from `preWriteDisk` when an agent write is rejected, since the pre-write snapshot is then what is
    /// on disk.
    var lastSavedDisk: String? = nil

    /// The target file's content when an agent write started: the UI's pre-read, replaced by the executor's authoritative
    /// snapshot when the completion carries one. Promoted to `lastSavedDisk` only on rejection; nil when the file was
    /// unreadable or over the cap.
    var preWriteDisk: String? = nil


    /// Live-agent state: `.active` while the agent's write is in flight, `.rejected` when the write was denied or failed
    /// (the tab shows a proposal that never reached disk), nil once settled. Never persisted.
    enum LiveState: Equatable {
        case active
        case rejected
    }
    var liveState: LiveState? = nil

    /// Identity for a tab opened from a chat message rather than a file on disk. The message id plus the block's index in
    /// the message's unfiltered block list is stable from the first token, while content grows during streaming.
    var originMessageID: UUID? = nil
    var originBlockIndex: Int? = nil


    /// What the editor should display: the user's draft when one exists, else the block. It is the editor's live text
    /// only because `updateCodeViewerDraft` stores every keystroke, including one that returns to the restore point.
    var effectiveCode: String { editedCode ?? snippet.code }

    /// Whether unsaved edits exist, compared against the restore point rather than testing `editedCode` for nil. The
    /// buffer is kept after a save so "saved" and "clean" are the same state without minting a new `snippet.id`, whose
    /// identity dedup and re-open compare against.
    var isDirty: Bool {
        guard let editedCode else { return false }
        return editedCode != (lastSavedBuffer ?? snippet.code)
    }

    init(snippet: CodeSnippet, fileName: String? = nil, filePath: String? = nil, originMessageID: UUID? = nil, originBlockIndex: Int? = nil, id: UUID = UUID()) {
        self.id = id
        self.snippet = snippet
        self.fileName = fileName
        self.filePath = filePath
        self.originMessageID = originMessageID
        self.originBlockIndex = originBlockIndex
    }

    /// An explicit language override chosen by the user in the editor status bar.
    /// When set, takes precedence over `snippet.language`.
    var customLanguage: String? = nil

    /// The effective language for syntax highlighting and display.
    var effectiveLanguage: String? { customLanguage ?? snippet.language }

    /// Label shown on the tab: the linked filename if present, else the capitalized
    /// language, else a generic fallback. Kept here so the tab bar reads one property.
    var title: String {
        if let fileName, !fileName.isEmpty { return fileName }
        if let language = effectiveLanguage, !language.isEmpty { return language.capitalized }
        return String(localized: "Snippet")
    }
}
