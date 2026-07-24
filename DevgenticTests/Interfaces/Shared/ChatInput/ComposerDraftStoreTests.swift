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
        store.save(.init(text: "half-typed for A", attachments: [file("a.swift")]), for: convA)

        let b = store.draft(for: convB)
        XCTAssertEqual(b.text, "", "B must not inherit A's text")
        XCTAssertTrue(b.attachments.isEmpty, "B must not inherit A's attachments")
    }

    func testDraftIsRestoredForItsOwnConversation() {
        store.save(.init(text: "for A", attachments: [file("a.swift")]), for: convA)
        store.save(.init(text: "for B", attachments: []), for: convB)

        XCTAssertEqual(store.draft(for: convA).text, "for A")
        XCTAssertEqual(store.draft(for: convA).attachments.map(\.name), ["a.swift"])
        XCTAssertEqual(store.draft(for: convB).text, "for B")
        XCTAssertTrue(store.draft(for: convB).attachments.isEmpty)
    }

    /// Restoring an EMPTY draft is what clears the composer when entering a conversation
    /// that has none — the mechanism that replaced the old `clearAttachedFiles()` calls.
    func testUnknownConversationYieldsAnEmptyDraft() {
        XCTAssertTrue(store.draft(for: UUID()).isEmpty)
    }

    // MARK: - The "new chat" (nil) slot

    func testNilConversationIsItsOwnDraftSlot() {
        store.save(.init(text: "typed before the chat exists"), for: nil)
        store.save(.init(text: "for A"), for: convA)

        XCTAssertEqual(store.draft(for: nil).text, "typed before the chat exists",
                       "A draft typed in the new-chat state survives a detour into a real conversation")
        XCTAssertEqual(store.draft(for: convA).text, "for A")
    }

    // MARK: - Growth / hygiene

    func testEmptyDraftIsNotStored() {
        store.save(.init(text: "", attachments: []), for: convA)
        XCTAssertEqual(store.storedDraftCount, 0, "Merely visiting a conversation must not leave a slot")
    }

    /// Sending clears the composer; the next switch then saves an empty draft, which must
    /// REMOVE the entry rather than leave an empty one to resurrect later.
    func testSavingEmptyOverAnExistingDraftClearsIt() {
        store.save(.init(text: "draft"), for: convA)
        XCTAssertEqual(store.storedDraftCount, 1)

        store.save(.init(text: "", attachments: []), for: convA)
        XCTAssertEqual(store.storedDraftCount, 0)
        XCTAssertTrue(store.draft(for: convA).isEmpty)
    }

    func testDiscardRemovesADraft() {
        store.save(.init(text: "draft", attachments: [file("a.swift")]), for: convA)
        store.discard(for: convA)
        XCTAssertTrue(store.draft(for: convA).isEmpty, "A deleted conversation's unsent text must not linger")
        XCTAssertEqual(store.storedDraftCount, 0)
    }

    func testDiscardLeavesOtherConversationsAlone() {
        store.save(.init(text: "A"), for: convA)
        store.save(.init(text: "B"), for: convB)
        store.discard(for: convA)
        XCTAssertEqual(store.draft(for: convB).text, "B")
    }

    // MARK: - Round trip

    /// The exact switch sequence the view performs: leave A (save), enter B (restore),
    /// come back to A (restore) — A's work must be intact.
    func testRoundTripAcrossASwitchPreservesBothConversations() {
        store.save(.init(text: "A work", attachments: [file("a.swift")]), for: convA)
        store.save(.init(text: "B work", attachments: [file("b.swift")]), for: convB)

        let backToA = store.draft(for: convA)
        XCTAssertEqual(backToA.text, "A work")
        XCTAssertEqual(backToA.attachments.map(\.name), ["a.swift"])
    }
}
