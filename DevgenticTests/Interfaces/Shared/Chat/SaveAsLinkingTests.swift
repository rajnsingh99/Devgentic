// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SaveAsLinkingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class SaveAsNoopStore: ChatPersistenceProtocol {
    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] { [] }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class SaveAsLinkingTests: XCTestCase {

    private var viewModel: ChatHistoryViewModel!
    private var tempDir: URL!

    override func setUp() async throws {
        let store = SaveAsNoopStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("saveas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        viewModel = nil
    }

    private func openUnlinkedTab(_ code: String = "let a = 1") -> UUID {
        viewModel.openTab(for: CodeSnippet(language: "swift", code: code), fileName: "snippet.swift")
    }

    // MARK: - Adoption

    /// The core of §7 item 3: after Save-As the tab IS that file.
    func testSaveAsLinksTheTabToTheChosenFile() throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("Adopted.swift")
        try "let a = 1".write(to: url, atomically: true, encoding: .utf8)

        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "let a = 1", savedTo: url)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertEqual(tab.filePath, url.path, "The tab adopts the chosen path")
        XCTAssertEqual(tab.fileName, "Adopted.swift", "…and its name, so the strip shows the real file")
        XCTAssertFalse(tab.isDirty, "Save-As satisfies an unlinked tab's dirty state")
    }

    /// D3: the drift baseline is what ARMS the guard for that file. Linking without it
    /// would leave later saves unprotected — the conservative-looking option is the worse one.
    func testSaveAsSetsTheDriftBaseline() throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("Guarded.swift")
        try "let a = 1".write(to: url, atomically: true, encoding: .utf8)

        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "let a = 1", savedTo: url)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertEqual(tab.lastSavedDisk, "let a = 1",
                       "Exactly what was written becomes the baseline for the NEXT save")
        XCTAssertEqual(tab.lastSavedBuffer, "let a = 1")
    }

    // MARK: - Saving to the adopted path

    /// A path-linked tab saves in place. Before this route existed, ⌘S on a Save-As'd tab
    /// re-opened the save panel every single time.
    func testSubsequentSaveWritesToTheAdoptedPath() async throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("InPlace.swift")
        try "let a = 1".write(to: url, atomically: true, encoding: .utf8)
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "let a = 1", savedTo: url)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 2   // edited")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let a = 2   // edited")
        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertFalse(tab.isDirty, "A successful save clears the draft")
        XCTAssertEqual(tab.lastSavedDisk, "let a = 2   // edited", "Baseline advances with our own write")
        XCTAssertNil(viewModel.codeApplyError)
    }

    /// Saving twice must keep working — the baseline advancing with each of our own writes
    /// is what stops the guard refusing a save as "drift" against our own prior one.
    func testSavingTwiceSucceeds() async throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("Twice.swift")
        try "v0".write(to: url, atomically: true, encoding: .utf8)
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "v0", savedTo: url)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "v1")
        await viewModel.saveTabToItsPath(tabID: tabID)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "v2")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "v2")
        XCTAssertNil(viewModel.codeApplyError, "The second save must not be refused as drift")
    }

    /// An edit made outside the app is not ours to overwrite.
    func testSaveRefusesWhenTheFileChangedUnderneath() async throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("Drifted.swift")
        try "ours".write(to: url, atomically: true, encoding: .utf8)
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "ours", savedTo: url)

        // Someone else edits it.
        try "theirs — do not clobber".write(to: url, atomically: true, encoding: .utf8)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "our new draft")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs — do not clobber",
                       "The external edit survives")
        XCTAssertNotNil(viewModel.codeApplyError, "…and the refusal is reported, not silent")
    }

    // MARK: - Audit regressions (2026-07-26)

    /// The tab's content must SURVIVE its own save. Clearing `editedCode` reverted
    /// `effectiveCode` to the pristine block, so the saved text vanished on the next tab
    /// reload — and the following ⌘S wrote the ORIGINAL back over the file.
    /// Both prior "save twice" tests missed it by setting a fresh draft before each save.
    func testSavedContentSurvivesTheSaveAndASecondSaveDoesNotRevertTheFile() async throws {
        let tabID = openUnlinkedTab("original")
        let url = tempDir.appendingPathComponent("Survives.swift")
        try "original".write(to: url, atomically: true, encoding: .utf8)
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "original", savedTo: url)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "edited")
        await viewModel.saveTabToItsPath(tabID: tabID)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertEqual(tab.effectiveCode, "edited",
                       "The saved text stays the tab's content — not the pristine block")
        XCTAssertFalse(tab.isDirty, "…and the tab is still clean")

        // Saving again without editing must not write the ORIGINAL back.
        await viewModel.saveTabToItsPath(tabID: tabID)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines),
                       "edited", "A no-edit re-save must not revert the file")
    }

    /// A tab opened from a tool row starts with no `lastSavedDisk`, which used to skip the
    /// drift check entirely. The baseline now falls back to the content it was opened with.
    func testTimelineOpenedTabIsDriftProtectedOnItsFirstSave() async throws {
        let url = tempDir.appendingPathComponent("Timeline.swift")
        try "on disk v1\n".write(to: url, atomically: true, encoding: .utf8)
        viewModel.openTimelineFileInCodeViewer(
            fileName: "Timeline.swift", filePath: url.path, content: "on disk v1"
        )
        let tabID = try XCTUnwrap(viewModel.codeViewerTabs.first?.id)
        XCTAssertNil(viewModel.codeViewerTabs[0].lastSavedDisk, "sanity: no baseline yet")

        // Someone edits it outside the app before we save.
        try "someone else's work".write(to: url, atomically: true, encoding: .utf8)
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "our edit")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "someone else's work",
                       "The external edit must survive — this save had no baseline before")
        XCTAssertNotNil(viewModel.codeApplyError)
    }

    /// The buffer is trimmed by `normalizedCode` on open; writing it verbatim stripped the
    /// file's POSIX trailing newline.
    func testSavePreservesTheTrailingNewline() async throws {
        let url = tempDir.appendingPathComponent("Newline.swift")
        try "let a = 1\n".write(to: url, atomically: true, encoding: .utf8)
        viewModel.openTimelineFileInCodeViewer(
            fileName: "Newline.swift", filePath: url.path, content: "let a = 1\n"
        )
        let tabID = try XCTUnwrap(viewModel.codeViewerTabs.first?.id)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "let a = 2")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let a = 2\n",
                       "The file keeps its trailing newline")
    }

    /// A file whose first byte is a newline lost that line on EVERY save, because
    /// `normalizedCode` trims both edges on open and only the trailing one was restored.
    /// Found by the 2026-07-27 audit.
    func testSavePreservesTheLeadingBlankLine() async throws {
        let onDisk = "\n// Copyright 2026\nlet a = 1\n"
        let url = tempDir.appendingPathComponent("Leading.swift")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)
        viewModel.openTimelineFileInCodeViewer(
            fileName: "Leading.swift", filePath: url.path, content: onDisk
        )
        let tabID = try XCTUnwrap(viewModel.codeViewerTabs.first?.id)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "// Copyright 2026\nlet a = 2")
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\n// Copyright 2026\nlet a = 2\n",
                       "the leading blank line survives, as does the trailing newline")
    }

    /// ⌘S is unconditional and `saveTabToItsPath` has no unchanged-buffer guard, so the
    /// zero-edit save is the one that silently ate the leading line.
    func testSavingWithNoEditsDoesNotStripEdgeWhitespace() async throws {
        let onDisk = "\n\nimport Foundation\n"
        let url = tempDir.appendingPathComponent("Untouched.swift")
        try onDisk.write(to: url, atomically: true, encoding: .utf8)
        viewModel.openTimelineFileInCodeViewer(
            fileName: "Untouched.swift", filePath: url.path, content: onDisk
        )
        let tabID = try XCTUnwrap(viewModel.codeViewerTabs.first?.id)

        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), onDisk,
                       "a save with no edits must leave the file byte-identical")
    }

    /// The save panel is modal and the tab can be closed while it's open; the file was
    /// still written, so this must not crash or half-apply.
    func testBookkeepingOnAClosedTabIsSafe() throws {
        let tabID = openUnlinkedTab()
        let url = tempDir.appendingPathComponent("Closed.swift")
        viewModel.forceCloseCodeViewerTab(id: tabID)

        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "content", savedTo: url)

        XCTAssertTrue(viewModel.codeViewerTabs.isEmpty)
    }

    // MARK: - Keystrokes typed while the Save-As was in flight (cv-1, 2026-09-12)

    /// ⚠️ THE REGRESSION GUARD. `markCodeViewerTabSavedAs` used to do `tab.editedCode =
    /// savedBuffer` unconditionally, so anything typed after the caller captured its buffer —
    /// the panel is MODELESS, so that is every keystroke from Save-As invocation until the
    /// write lands — was overwritten. Setting `lastSavedBuffer` to the same value then made
    /// `isDirty` FALSE, so the unsaved dot cleared and `closeCodeViewerTab` stopped asking:
    /// silent data loss with its own warning suppressed.
    ///
    /// `saveTabToItsPath` has carried this guard since the off-actor move; Save-As is the
    /// third save engine and was the one still missing it.
    func testSaveAsKeepsKeystrokesTypedWhileTheSaveWasInFlight() throws {
        let tabID = openUnlinkedTab("v0")
        let url = tempDir.appendingPathComponent("Raced.swift")
        try "captured".write(to: url, atomically: true, encoding: .utf8)

        // What the caller captured before `savePanel.begin`.
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured")
        // The user keeps typing while the panel is up and the write is in flight. This is the
        // real production write-through, not a direct field poke.
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured + typed during save")

        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "captured", savedTo: url)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertEqual(tab.effectiveCode, "captured + typed during save",
                       "The keystrokes typed during the save must survive it")
        XCTAssertTrue(tab.isDirty,
                      "…and the tab must stay DIRTY, or the dot clears and ⌘W closes without asking")
        // The bookkeeping is unconditional: the bytes ARE on disk and the tab IS that file.
        XCTAssertEqual(tab.filePath, url.path, "The tab still adopts the chosen path")
        XCTAssertEqual(tab.fileName, "Raced.swift", "…and its name")
        XCTAssertEqual(tab.lastSavedBuffer, "captured", "The restore point is what was written")
        XCTAssertEqual(tab.lastSavedDisk, "captured", "…and so is the drift baseline")
    }

    /// The guard must not over-correct: when nothing was typed, Save-As still adopts the
    /// buffer and the tab goes clean. Fixtures are distinguishable from the block's own text
    /// so an adopted `editedCode` cannot be confused with the pristine snippet.
    func testSaveAsStillAdoptsTheBufferWhenNothingWasTypedDuringTheSave() throws {
        let tabID = openUnlinkedTab("pristine block")
        let url = tempDir.appendingPathComponent("Quiet.swift")
        try "the saved buffer".write(to: url, atomically: true, encoding: .utf8)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "the saved buffer")
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "the saved buffer", savedTo: url)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertEqual(tab.editedCode, "the saved buffer",
                       "With no drift the buffer is adopted, not left at the block")
        XCTAssertFalse(tab.isDirty, "…and the tab is clean")
    }

    /// The recovery has to actually work: the text the guard KEPT is what the next ⌘S writes.
    /// Without this, "we kept your keystrokes" would be true of the model and false on disk.
    func testTheKeptDraftIsWhatTheNextSaveWrites() async throws {
        let tabID = openUnlinkedTab("v0")
        let url = tempDir.appendingPathComponent("Recovered.swift")
        try "captured".write(to: url, atomically: true, encoding: .utf8)

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured")
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured + typed during save")
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "captured", savedTo: url)

        // ⌘S on the now-linked tab. The baseline recorded above matches the file, so this is
        // not refused as external drift.
        await viewModel.saveTabToItsPath(tabID: tabID)

        XCTAssertNil(viewModel.codeApplyError, "The follow-up save must not be refused as drift")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "captured + typed during save",
                       "The kept keystrokes reach the file on the next save")
        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        XCTAssertFalse(tab.isDirty, "…and only then is the tab clean")
    }

    /// ⚠️ THE COLD-READ GUARD. `effectiveCode` is `editedCode ?? snippet.code`, so it also moves
    /// when the SNIPPET is replaced and `editedCode` is left nil — which a re-open of a still
    /// streaming block does while the modeless Save-As panel is up. Flagging the drift without
    /// materialising it left `editedCode == nil` against a different `lastSavedBuffer`, and
    /// `isDirty` early-returns FALSE on nil — so the tab reported CLEAN with unsaved content and
    /// ⌘W closed it without asking. Mutation that must kill this: drop
    /// `tab.editedCode = tab.effectiveCode` from the else-branch.
    func testATabWhoseSnippetMovedDuringSaveAsStillReportsDirty() throws {
        let tabID = openUnlinkedTab("v0")
        let url = tempDir.appendingPathComponent("SnippetMoved.swift")

        // The Save-As captured "v0"; meanwhile the block re-opens with more streamed content,
        // which replaces the SNIPPET and leaves `editedCode` nil.
        _ = viewModel.openTab(for: CodeSnippet(language: "swift", code: "v0 + more"),
                              fileName: "snippet.swift", filePath: nil,
                              originMessageID: nil, originBlockIndex: nil)
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "v0", savedTo: url)

        let tab = try XCTUnwrap(viewModel.codeViewerTabs.first { $0.id == tabID })
        if tab.effectiveCode != "v0" {
            XCTAssertTrue(tab.isDirty,
                          "the buffer no longer matches what was written — the tab must not report clean")
            XCTAssertNotNil(tab.editedCode,
                            "…and `editedCode` must be materialised, or `isDirty` short-circuits to false")
        }
    }

    /// The other half of the defect: the suppressed warning. A tab holding keystrokes the
    /// save did not capture must route ⌘W through the confirmation, not close silently.
    func testClosingAfterADriftedSaveAsAsksForConfirmation() throws {
        let tabID = openUnlinkedTab("v0")
        let url = tempDir.appendingPathComponent("Confirmed.swift")

        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured")
        viewModel.updateCodeViewerDraft(tabID: tabID, content: "captured + typed during save")
        viewModel.markCodeViewerTabSavedAs(tabID: tabID, savedBuffer: "captured", savedTo: url)

        viewModel.closeCodeViewerTab(id: tabID)

        XCTAssertEqual(viewModel.pendingCloseTabID, tabID,
                       "The close must be held for confirmation — the tab holds unsaved keystrokes")
        XCTAssertTrue(viewModel.codeViewerTabs.contains { $0.id == tabID },
                      "…and the tab must still be open while that is pending")
    }
}
