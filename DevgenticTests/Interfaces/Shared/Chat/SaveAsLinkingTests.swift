// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SaveAsLinkingTests.swift
//  DevgenticTests
//
//  Save-As now makes the tab ADOPT the file it wrote (design §7, §12 D3).
//
//  Before this, Save-As set only `lastSavedBuffer`: the tab stayed unlinked, so every
//  subsequent ⌘S re-opened the save panel, and model-generated content never gained a real
//  path. Setting `lastSavedDisk` is the load-bearing half — the drift guard resolves
//  `lastSavedDisk ?? sourceFile.content`, and a Save-As'd tab has no source file, so
//  linking WITHOUT the baseline would leave later saves to that path with no drift
//  protection at all.
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
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
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
}
