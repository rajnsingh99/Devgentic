// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ComposerDraftStoreTests.swift
//  DevgenticTests
//
//  C2 (composer audit, 2026-07-18): the composer's view model is app-scoped and
//  `attachedFiles` lives on the single MainApplicationViewModel, so nothing reset either
//  when the selected conversation changed — a half-typed message and its attachments
//  followed you from conversation A into B, where they could be sent by accident.
//
//  `ComposerDraftStore` makes composer contents belong to a conversation. These tests
//  cover the store's contract directly (it's pure); the view wiring that calls it on
//  `selectedConversationID` changes needs an on-device pass.
//

import XCTest
@testable import devgentic

@MainActor
final class ComposerDraftStoreTests: XCTestCase {

    /// A fresh instance per test — deliberately NOT `.shared`, so these don't leak state
    /// into each other or into anything else using the app-wide store.
    private var store: ComposerDraftStore!
    private let convA = UUID()
    private let convB = UUID()

    override func setUp() async throws {
        store = ComposerDraftStore()
    }

    private func file(_ name: String) -> FileSystemItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    // MARK: - The reported bug

    func testDraftDoesNotLeakBetweenConversations() {
        store.save(.init(text: "half-typed for A", attachments: [file("a.swift")]), for: .init(.chat, convA))

        let b = store.draft(for: .init(.chat, convB))
        XCTAssertEqual(b.text, "", "B must not inherit A's text")
        XCTAssertTrue(b.attachments.isEmpty, "B must not inherit A's attachments")
    }

    /// Every mode's Home is conversation `nil`. Keyed by conversation alone, a draft typed on
    /// Code's Home showed up on Chat's Home after a mode switch (screenshots, 2026-10-04).
    func testHomeDraftsBelongToTheirOwnMode() {
        store.save(.init(text: "fdsafsdf", attachments: [file("april-25.py")]), for: .init(.code, nil))

        XCTAssertTrue(store.draft(for: .init(.chat, nil)).isEmpty, "Code's Home draft must not appear on Chat's Home")
        XCTAssertTrue(store.draft(for: .init(.workflow, nil)).isEmpty)
        XCTAssertEqual(store.draft(for: .init(.code, nil)).text, "fdsafsdf", "and it is back when Code is")
        XCTAssertEqual(store.draft(for: .init(.code, nil)).attachments.map(\.name), ["april-25.py"])
    }

    func testDiscardRemovesTheConversationsDraftInEveryMode() {
        store.save(.init(text: "A"), for: .init(.code, convA))
        store.save(.init(text: "Home"), for: .init(.code, nil))
        store.discard(for: convA)
        XCTAssertTrue(store.draft(for: .init(.code, convA)).isEmpty)
        XCTAssertEqual(store.draft(for: .init(.code, nil)).text, "Home", "other keys untouched")
    }

    func testDraftIsRestoredForItsOwnConversation() {
        store.save(.init(text: "for A", attachments: [file("a.swift")]), for: .init(.chat, convA))
        store.save(.init(text: "for B", attachments: []), for: .init(.chat, convB))

        XCTAssertEqual(store.draft(for: .init(.chat, convA)).text, "for A")
        XCTAssertEqual(store.draft(for: .init(.chat, convA)).attachments.map(\.name), ["a.swift"])
        XCTAssertEqual(store.draft(for: .init(.chat, convB)).text, "for B")
        XCTAssertTrue(store.draft(for: .init(.chat, convB)).attachments.isEmpty)
    }

    /// Restoring an EMPTY draft is what clears the composer when entering a conversation
    /// that has none — the mechanism that replaced the old `clearAttachedFiles()` calls.
    func testUnknownConversationYieldsAnEmptyDraft() {
        XCTAssertTrue(store.draft(for: .init(.chat, UUID())).isEmpty)
    }

    // MARK: - The "new chat" (nil) slot

    func testNilConversationIsItsOwnDraftSlot() {
        store.save(.init(text: "typed before the chat exists"), for: .init(.chat, nil))
        store.save(.init(text: "for A"), for: .init(.chat, convA))

        XCTAssertEqual(store.draft(for: .init(.chat, nil)).text, "typed before the chat exists",
                       "A draft typed in the new-chat state survives a detour into a real conversation")
        XCTAssertEqual(store.draft(for: .init(.chat, convA)).text, "for A")
    }

    // MARK: - Growth / hygiene

    func testEmptyDraftIsNotStored() {
        store.save(.init(text: "", attachments: []), for: .init(.chat, convA))
        XCTAssertEqual(store.storedDraftCount, 0, "Merely visiting a conversation must not leave a slot")
    }

    /// Sending clears the composer; the next switch then saves an empty draft, which must
    /// REMOVE the entry rather than leave an empty one to resurrect later.
    func testSavingEmptyOverAnExistingDraftClearsIt() {
        store.save(.init(text: "draft"), for: .init(.chat, convA))
        XCTAssertEqual(store.storedDraftCount, 1)

        store.save(.init(text: "", attachments: []), for: .init(.chat, convA))
        XCTAssertEqual(store.storedDraftCount, 0)
        XCTAssertTrue(store.draft(for: .init(.chat, convA)).isEmpty)
    }

    func testDiscardRemovesADraft() {
        store.save(.init(text: "draft", attachments: [file("a.swift")]), for: .init(.chat, convA))
        store.discard(for: convA)
        XCTAssertTrue(store.draft(for: .init(.chat, convA)).isEmpty, "A deleted conversation's unsent text must not linger")
        XCTAssertEqual(store.storedDraftCount, 0)
    }

    func testDiscardLeavesOtherConversationsAlone() {
        store.save(.init(text: "A"), for: .init(.chat, convA))
        store.save(.init(text: "B"), for: .init(.chat, convB))
        store.discard(for: convA)
        XCTAssertEqual(store.draft(for: .init(.chat, convB)).text, "B")
    }

    // MARK: - Round trip

    /// The exact switch sequence the view performs: leave A (save), enter B (restore),
    /// come back to A (restore) — A's work must be intact.
    func testRoundTripAcrossASwitchPreservesBothConversations() {
        store.save(.init(text: "A work", attachments: [file("a.swift")]), for: .init(.chat, convA))
        store.save(.init(text: "B work", attachments: [file("b.swift")]), for: .init(.chat, convB))

        let backToA = store.draft(for: .init(.chat, convA))
        XCTAssertEqual(backToA.text, "A work")
        XCTAssertEqual(backToA.attachments.map(\.name), ["a.swift"])
    }

    // MARK: - Persisted across launches (2026-10-05)

    private func tempFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drafts-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func realFile(_ name: String) throws -> FileSystemItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data("x".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return FileSystemItem(id: url, name: name, url: url, isDirectory: false)
    }

    func testADraftSurvivesARelaunch() throws {
        let fileURL = tempFile()
        let attachment = try realFile("notes.md")
        let first = ComposerDraftStore(fileURL: fileURL)
        first.save(.init(text: "half-typed", attachments: [attachment]), for: .init(.code, convA))
        first.writeNow()

        let relaunched = ComposerDraftStore(fileURL: fileURL)
        XCTAssertEqual(relaunched.draft(for: .init(.code, convA)).text, "half-typed")
        XCTAssertEqual(relaunched.draft(for: .init(.code, convA)).attachments.map(\.url), [attachment.url])
        XCTAssertTrue(relaunched.draft(for: .init(.chat, convA)).isEmpty, "still keyed per mode after a relaunch")
    }

    func testAnAttachmentWhoseFileIsGoneIsDroppedOnRestore() throws {
        let fileURL = tempFile()
        let gone = FileSystemItem(id: URL(fileURLWithPath: "/nonexistent/\(UUID()).txt"), name: "gone.txt",
                                  url: URL(fileURLWithPath: "/nonexistent/x.txt"), isDirectory: false)
        let first = ComposerDraftStore(fileURL: fileURL)
        first.save(.init(text: "keep me", attachments: [gone]), for: .init(.chat, nil))
        first.writeNow()

        let restored = ComposerDraftStore(fileURL: fileURL).draft(for: .init(.chat, nil))
        XCTAssertEqual(restored.text, "keep me")
        XCTAssertTrue(restored.attachments.isEmpty)
    }

    func testDraftsUntouchedPastMaxAgeAreDroppedAtLoad() throws {
        let fileURL = tempFile()
        let first = ComposerDraftStore(fileURL: fileURL)
        first.save(.init(text: "old"), for: .init(.chat, convA))
        first.writeNow()

        let muchLater = Date().addingTimeInterval(ComposerDraftStore.maxAge + 60)
        XCTAssertTrue(ComposerDraftStore(fileURL: fileURL, now: muchLater).draft(for: .init(.chat, convA)).isEmpty)
    }

    /// Sending clears the composer — that must remove the saved draft too, or it would come
    /// back after a relaunch.
    func testClearingADraftRemovesItFromDisk() throws {
        let fileURL = tempFile()
        let first = ComposerDraftStore(fileURL: fileURL)
        first.save(.init(text: "sent soon"), for: .init(.chat, convA))
        first.save(.init(), for: .init(.chat, convA))
        first.writeNow()

        XCTAssertTrue(ComposerDraftStore(fileURL: fileURL).draft(for: .init(.chat, convA)).isEmpty)
    }
}
