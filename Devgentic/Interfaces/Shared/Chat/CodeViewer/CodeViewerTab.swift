// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeViewerTab.swift
//  Devgentic
//
//  Created by Raj Singh
//

import Foundation
import CodeEditSourceEditor

/// How the Code Viewer panel occupies the window.
///
/// An enum rather than booleans: `overlay`/`split`/`full` are mutually exclusive, and two
/// flags would mint an invalid fourth state. EXPERIMENTAL (2026-07-24): `.split` is the
/// Antigravity-style side-by-side mode — the chat yields layout space instead of being
/// covered. Implemented as a trailing inset on the chat area, NOT a re-parent into a real
/// split view, so the panel keeps its view identity (no editor teardown) across modes and
/// the feature reverts by deleting a case.
enum CodeViewerPresentation: String {
    /// The historic floating panel: overlays the chat's right edge; chat keeps full width.
    case overlay
    /// Side-by-side: the chat insets by the panel width and reflows next to it.
    case split
    /// Panel fills the content area (chat fully covered; sidebar stays reachable).
    case full
}

/// Per-tab editor VIEW state — cursor positions, scroll offset, find-panel text — for the
/// Code Viewer's `SourceEditor`.
///
/// Lives here rather than in `CodeViewerTab` for two reasons:
///
/// 1. **It must outlive the panel.** The document is keyed `.id(document.id)`, so SwiftUI
///    discards the editor's controller on every tab switch and every live-write refresh,
///    and minimizing unmounts the panel entirely. State held by the view (or by the
///    controller) dies with it, which is why the editor used to land back at line 1 every
///    time — and why the floating pill's "reopens the panel where it left off" was true of
///    the tab SET and false of the position.
/// 2. **It must not be observed.** The editor writes back a cursor position on every
///    keystroke and arrow key. Putting that in the `@Observable` `codeViewerTabs` array
///    would invalidate the root window body, the panel body and every tab chip on each
///    caret move — the exact churn the Code Viewer is already too heavy for.
///
/// Keyed by TAB id, not snippet id: a tab keeps its identity across content refreshes, and
/// resuming the caret in the same tab after the agent rewrote the file is the point.
@MainActor
final class CodeViewerEditorStateStore {
    private var statesByTab: [UUID: SourceEditorState] = [:]

    /// The stored state, or a fresh one — a tab that has never been shown starts at the top.
    func state(for tabID: UUID) -> SourceEditorState { statesByTab[tabID] ?? SourceEditorState() }

    func setState(_ state: SourceEditorState, for tabID: UUID) { statesByTab[tabID] = state }

    /// Drops state for tabs the user CLOSED. Deliberately not called on a conversation
    /// switch: those tabs are stashed, not closed, and must come back where they were.
    func forget(tabIDs: [UUID]) {
        for id in tabIDs { statesByTab.removeValue(forKey: id) }
    }

    /// Number of tabs with retained editor state — for tests and leak checks only.
    var retainedTabCount: Int { statesByTab.count }
}

/// One open document in the Code Viewer's tab strip.
///
/// The Code Viewer moved from a single `(snippets, currentIndex)` selection to a set of
/// persistent tabs (Antigravity-style): opening a code block ADDS a tab, tabs survive the
/// panel being minimized to the floating reopen button.
///
/// The tab carries NO diff state: a change is shown in the tool row that produced it, not
/// here (`Docs/codeviewer-rescope-design.md` §4).
struct CodeViewerTab: Identifiable, Equatable {
    let id: UUID

    /// The code this tab displays. Replaced in place (new `snippet.id`, which is what drives
    /// the panel's snippet-id-keyed reload) when an AGENT write lands on this file, or when
    /// a re-open finds the source block's content has moved on. NOT on a save — see
    /// `isDirty`, which exists precisely so a save doesn't have to touch this.
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
    //
    // `snippet.code` is deliberately IMMUTABLE once the tab opens — it is "what the chat
    // block said", and dedup (`denotesSameBlock`), click-to-tab location, and re-open
    // focusing all compare against it. User edits therefore live beside it, not in it.

    /// The editor buffer when it has diverged from the restore point (`lastSavedBuffer`,
    /// else `snippet.code`). Nil ⟺ the buffer matches the restore point ⟺ not dirty.
    /// Kept in the tab (not the panel) so drafts survive tab switches and minimize.
    var editedCode: String? = nil

    /// Buffer content at the last successful save — the dirty-comparison restore point.
    /// Distinct from `lastSavedDisk` because the write path may append a trailing newline
    /// the buffer doesn't have; comparing the buffer against disk bytes would leave the
    /// tab phantom-dirty forever.
    var lastSavedBuffer: String? = nil

    /// The bytes this tab last KNEW to be on disk — the drift-guard baseline for the NEXT
    /// save. Normally that is our own last write; without it the guard compares against
    /// attach-time content forever and refuses every save after the first as "drift"
    /// (it's our own prior write).
    ///
    /// It is also set from `preWriteDisk` when an agent write is REJECTED, because nothing
    /// was written and the pre-write snapshot is then exactly what is on disk. Leaving it
    /// nil there made the guard fall back to `snippet.code` — the PROPOSAL, which by
    /// definition is not on disk — so every ⌘S on a rejected tab was refused as drift.
    var lastSavedDisk: String? = nil

    /// The target file's content as of the moment an agent write STARTED: the UI's
    /// best-effort pre-read (`handleAgentWriteBegan`), replaced by the executor's
    /// authoritative snapshot when the completion carries one.
    ///
    /// Held separately from `lastSavedDisk` and only promoted on REJECTION: on success the
    /// agent's proposal IS what landed on disk, and seeding the guard with the pre-write
    /// bytes there would refuse the user's next save as drift against our own agent's write.
    /// Nil when the file was unreadable/over the cap — the tab then keeps the old
    /// (proposal) baseline and a save on a rejected write is still refused; the log says so.
    var preWriteDisk: String? = nil


    /// Live-agent state: `.active` while the agent's write is in flight (pulsing chip dot,
    /// pill pulse, "agent is writing" banner), `.rejected` when the write was denied or
    /// failed (the tab shows a proposal that never reached disk), nil once settled.
    /// Never persisted — a relaunch mid-run just loses the pulse.
    enum LiveState: Equatable {
        case active
        case rejected
    }
    var liveState: LiveState? = nil

    /// Identity for a tab opened from a CHAT message rather than a file on disk.
    ///
    /// Content alone cannot identify such a tab: a message that is still STREAMING grows,
    /// so re-opening it after completion found no content match and appended a second tab
    /// holding the truncated mid-stream fragment (field-observed 2026-07-25). The message id
    /// plus the block's position within that message is stable from the first token onward.
    ///
    /// The index is over the message's UNFILTERED block list — the large-block filter is
    /// applied afterwards, and a block can cross that threshold as it streams.
    var originMessageID: UUID? = nil
    var originBlockIndex: Int? = nil


    /// What the editor should display: the user's draft when one exists, else the block.
    ///
    /// ⚠️ This is "the editor's live text" ONLY because `updateCodeViewerDraft` stores every
    /// keystroke, including one that returns to the restore point. It used to store `nil`
    /// there, which made this property silently return the pristine block for a tab the user
    /// was actively editing — and the save path reads it as the buffer to write.
    var effectiveCode: String { editedCode ?? snippet.code }

    /// Unsaved edits exist.
    ///
    /// Compares against the restore point rather than testing `editedCode` for nil. A save
    /// used to CLEAR `editedCode`, which made the tab clean but also reverted
    /// `effectiveCode` to the pristine block — so the just-saved text vanished on the next
    /// tab reload and a subsequent ⌘S wrote the ORIGINAL back over the file. Keeping the
    /// buffer and comparing it here is what makes "saved" and "clean" the same state
    /// without minting a new `snippet.id`.
    ///
    /// ⚠️ [CF-13] That parenthetical used to read "which would rebuild the editor and lose
    /// the cursor" — no longer true. `CodeViewerEditorStateStore` is keyed by TAB id, so it
    /// survives the panel's `.id(document.id)` teardown, and `SourceEditor` restores the
    /// caret in `makeNSViewController` and the scroll offset on the first update. The
    /// remaining reason is IDENTITY, not the caret: `snippet.code` is what dedup
    /// (`denotesSameBlock`), click-to-tab and re-open focusing all compare against (see the
    /// "Editing state" note above), so re-pointing it at the saved text would move the
    /// anchor. The teardown and re-highlight on every ⌘S are waste on top of that.
    ///
    /// Found by the 2026-07-26 re-scope audit; pre-existed in `applyChanges`.
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

    /// Label shown on the tab: the linked filename if present, else the capitalized
    /// language, else a generic fallback. Kept here so the tab bar reads one property.
    var title: String {
        if let fileName, !fileName.isEmpty { return fileName }
        if let language = snippet.language, !language.isEmpty { return language.capitalized }
        return String(localized: "Snippet")
    }
}
