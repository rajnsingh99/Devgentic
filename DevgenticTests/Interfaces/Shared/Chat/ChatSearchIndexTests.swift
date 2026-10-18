// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatSearchIndexTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
private final class ProjectionStore: ChatPersistenceProtocol {
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
final class ChatSearchIndexTests: XCTestCase {

    private func agentMessage(_ markdown: String) -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(markdown))
    }

    private func userMessage(_ text: String) -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .user, content: .plainText(text))
    }

    private func search(_ query: String, _ messages: [ChatMessage]) -> ChatSearchViewModel {
        let vm = ChatSearchViewModel()
        vm.searchQuery = query
        vm.performSearch(in: messages.map(ChatSearchDecomposition.document(for:)))
        return vm
    }

    // MARK: - CH28 (index space)

    /// The defect: matches were counted across the whole message and the resulting index was
    /// handed to EVERY block, each of which compared it against its own offsets. With one
    /// match per paragraph, navigating to the second match highlighted nothing at all.
    func testEachMatchIsKeyedToTheBlockThatRendersIt() {
        let message = agentMessage("First paragraph has config.\n\nSecond paragraph has config too.")
        let vm = search("config", [message])

        XCTAssertEqual(vm.matches.count, 2)
        let blockIDs = vm.matches.map(\.blockID)
        XCTAssertEqual(Set(blockIDs).count, 2, "the two matches must name DIFFERENT blocks")
        XCTAssertTrue(vm.matches.allSatisfy { $0.indexInBlock == 0 },
                      "each is the first occurrence WITHIN its own block")

        // Navigating to match 2 must resolve against that block, not against block 1.
        vm.nextMatch()
        let active = vm.activeMatch(in: message.id)
        XCTAssertEqual(active?.blockID, blockIDs[1])
        XCTAssertEqual(active?.indexInBlock, 0)
    }

    /// The mirror case: several matches inside ONE block must keep ascending local indices,
    /// so the highlighter paints the occurrence actually being navigated to.
    func testMultipleMatchesInOneBlockKeepLocalIndices() {
        let message = agentMessage("alpha alpha alpha")
        let vm = search("alpha", [message])

        XCTAssertEqual(vm.matches.map(\.indexInBlock), [0, 1, 2])
        XCTAssertEqual(Set(vm.matches.map(\.blockID)).count, 1, "all three are in the same block")
    }

    /// Single-unit surfaces carry no block id, and `activeMatchIndex(in:blockID:)` must
    /// resolve for them — this is the path that was already correct and must stay that way.
    func testUserMessageMatchesCarryNoBlockID() {
        let message = userMessage("plain user text with token and token")
        let vm = search("token", [message])

        XCTAssertEqual(vm.matches.count, 2)
        XCTAssertTrue(vm.matches.allSatisfy { $0.blockID == nil })
        XCTAssertEqual(vm.activeMatchIndex(in: message.id, blockID: nil), 0)
    }

    /// A match in another message must not resolve here.
    func testActiveMatchDoesNotLeakAcrossMessages() {
        let a = agentMessage("hit here")
        let b = agentMessage("hit there")
        let vm = search("hit", [a, b])

        XCTAssertNotNil(vm.activeMatch(in: vm.matches[vm.currentMatchIndex].messageID))
        let otherID = vm.matches.first { $0.messageID != vm.currentMatchMessageID }?.messageID
        XCTAssertNotNil(otherID)
        XCTAssertNil(vm.activeMatch(in: otherID!), "only the message holding the active match resolves")
    }

    // MARK: - CH29 (count matches what can be painted)

    /// The count came from the raw markdown SOURCE while highlighting ran over the RENDERED
    /// string, so a phrase spanning a `**` marker reported "No results" for text plainly on
    /// screen.
    func testPhraseSpanningEmphasisMarkersIsFound() {
        let message = agentMessage("the **best** option")
        let vm = search("the best option", [message])

        XCTAssertEqual(vm.matches.count, 1,
                       "the rendered text reads 'the best option' — searching it must match")
    }

    /// Syntax markers themselves are not on screen, so they must not be findable.
    func testMarkdownSyntaxItselfIsNotMatched() {
        let vm = search("**", [agentMessage("some **bold** text")])
        XCTAssertTrue(vm.matches.isEmpty, "`**` is consumed by the renderer and never displayed")
    }

    /// Code blocks are rendered by views that take no search query. Counting them promised a
    /// highlight that could never be painted — "1 of 7" where 5 positions show nothing.
    func testCodeBlockTextIsNotCounted() {
        let message = agentMessage("Prose mentions import once.\n\n```swift\nimport Foundation\nimport UIKit\n```")
        let vm = search("import", [message])

        XCTAssertEqual(vm.matches.count, 1, "only the prose occurrence is paintable, so only it counts")
        XCTAssertNotNil(vm.matches.first?.blockID)
    }

    /// Nested list/blockquote content IS highlightable and must be reachable — and each nested
    /// paragraph must own its match, which is what makes `childBlock` forwarding correct.
    func testNestedListContentIsSearchableAndBlockKeyed() {
        let message = agentMessage("- first target\n- second target")
        let vm = search("target", [message])

        XCTAssertEqual(vm.matches.count, 2)
        XCTAssertEqual(Set(vm.matches.map(\.blockID)).count, 2,
                       "each list item's paragraph is its own block")
        XCTAssertTrue(vm.matches.allSatisfy { $0.blockID != nil })
    }

    /// Containers must not double-count: `ContentBlock.plainText` joins children, and using it
    /// would emit a match for the item AND for its paragraph.
    func testContainerDoesNotDoubleCount() {
        let vm = search("once", [agentMessage("- once")])
        XCTAssertEqual(vm.matches.count, 1)
    }

    // MARK: - AD7 — one expression of "what we search FOR"

    /// The producer trimmed the query and the three render paths did not, so the two sides
    /// counted occurrences of DIFFERENT strings — the same index-space drift CH28/CH29 exist to
    /// prevent, one argument over from the one they fixed.
    func testWhitespacePaddedQueryMeasuresTheSameStringOnBothSides() {
        let message = agentMessage("config config config")
        let vm = ChatSearchViewModel()
        vm.searchQuery = "  config "

        XCTAssertEqual(vm.effectiveQuery, "config",
                       "the query both sides measure is the trimmed one")

        vm.performSearch(in: [ChatSearchDecomposition.document(for: message)])
        XCTAssertEqual(vm.matches.count, 3, "the producer counts occurrences of the trimmed query")

        // The renderer measures `effectiveQuery` too, so its offsets agree with those indices.
        let unit = ChatSearchDecomposition.document(for: message).units[0]
        XCTAssertEqual(SearchHighlighter.matchOffsets(in: unit.text, query: vm.effectiveQuery).count, 3,
                       "the consumer must find the same occurrences the producer indexed")
    }

    /// A query that is only whitespace is not a search.
    func testWhitespaceOnlyQueryFindsNothing() {
        let vm = ChatSearchViewModel()
        vm.searchQuery = "   "
        vm.performSearch(in: [ChatSearchDecomposition.document(for: agentMessage("anything"))])
        XCTAssertTrue(vm.effectiveQuery.isEmpty)
        XCTAssertTrue(vm.matches.isEmpty)
    }

    // MARK: - navigation stability

    /// Editing the query must put the user back at the FIRST match. `SearchMatch.id` is a pure
    /// (message, block, ordinal) tuple with no query identity, so the old anchor could still be
    /// found in the new result set — broadening a query jumped to the middle of the list and
    /// scrolled away from the first hit of what had just been typed.
    func testEditingTheQueryResetsToTheFirstMatch() {
        // The old query's ONLY hit is in the LAST block, so its key maps to a NON-zero position
        // in the new result set — otherwise the assertion below passes either way.
        // (`searchQuery.didSet` resets `currentMatchIndex` to 0, so the surviving anchor is
        // always `matches[0]` of the previous query.)
        let message = agentMessage("alpha\n\nalpha\n\nalpha beta")
        let doc = { ChatSearchDecomposition.document(for: message) }

        let vm = ChatSearchViewModel()
        vm.searchQuery = "beta"
        vm.performSearch(in: [doc()])
        XCTAssertEqual(vm.matches.count, 1, "precondition: the old query hits only the last block")
        let staleAnchor = vm.matches[0].id

        // The new query's result set still CONTAINS that (message, block, ordinal) tuple — at
        // index 2, not 0. Re-anchoring on it would drop the user into the middle of the list.
        vm.searchQuery = "alpha"
        vm.performSearch(in: [doc()])
        XCTAssertEqual(vm.matches.count, 3)
        XCTAssertEqual(vm.matches.firstIndex { $0.id == staleAnchor }, 2,
                       "precondition: the stale anchor survives at a non-zero position")

        XCTAssertEqual(vm.currentMatchIndex, 0,
                       "a query edit must start at the first match, not re-anchor on the old one")
    }

    /// Re-running the search (streaming bumps it constantly) must keep the user on the SAME
    /// match rather than silently jumping them back to the first.
    func testReRunKeepsTheUserOnTheSameMatch() {
        let message = agentMessage("one target\n\ntwo target\n\nthree target")
        let vm = search("target", [message])
        vm.nextMatch()
        vm.nextMatch()
        let anchored = vm.matches[vm.currentMatchIndex].id

        vm.performSearch(in: [ChatSearchDecomposition.document(for: message)])

        XCTAssertEqual(vm.matches[vm.currentMatchIndex].id, anchored,
                       "the active match must survive a re-run")
    }

    // MARK: - CH31 memoization (search-6: the register named a test that never touches it)

    /// The resident projection is memoized on a hash of the displayed text, so an in-place
    /// mutation must invalidate it automatically. The register cited
    /// `testSearchReflectsInPlaceContentMutation` as pinning this — that test builds documents
    /// directly and never constructs a view model, so it exercises no cache at all.
    func testResidentProjectionRefreshesWhenMessageTextMutatesInPlace() async {
        let store = ProjectionStore()
        let vm = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store,
                                                     fileProcessorService: FileProcessorService()),
            ownsCodeViewer: true
        )
        let conversation = UUID()
        let message = ChatMessage(conversationId: conversation, sender: .agent,
                                  content: .markdownText("before text"))
        vm.currentChatMessages = [message]

        let first = vm.searchCorpus.first { $0.id == message.id }
        XCTAssertEqual(first?.units.first?.text, "before text")

        // In-place mutation, exactly as a completing stream does it: BOTH `content` and the
        // selected variant. An agent `ChatMessage` is initialised with an `agentResponse`, so
        // `displayedContent` reads the VARIANT — mutating `content` alone is a state the app
        // never produces, and a fixture built that way pins nothing.
        message.content = .markdownText("after text")
        message.agentResponse?.variants[0].content = .markdownText("after text")

        let second = vm.searchCorpus.first { $0.id == message.id }
        XCTAssertEqual(second?.units.first?.text, "after text",
                       "the memo is keyed on the text, so mutating it must re-decompose")
    }

    /// Control: re-reading with UNCHANGED text must return the same units — otherwise the memo
    /// is doing nothing and every keystroke re-decomposes the whole resident window.
    func testResidentProjectionIsStableWhenTextIsUnchanged() async {
        let store = ProjectionStore()
        let vm = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(persistenceService: store,
                                                     fileProcessorService: FileProcessorService()),
            ownsCodeViewer: true
        )
        let message = ChatMessage(conversationId: UUID(), sender: .agent,
                                  content: .markdownText("stable text"))
        vm.currentChatMessages = [message]

        let a = vm.searchCorpus.first { $0.id == message.id }?.units
        let b = vm.searchCorpus.first { $0.id == message.id }?.units
        XCTAssertEqual(a, b, "unchanged text must yield the identical projection")
    }

    // MARK: - CH31 (projection carries no payload)

    /// The corpus element must be a text projection. The old cache held whole `ChatMessage`s,
    /// so every attached image's bytes stayed resident until the conversation changed.
    func testProjectionCarriesOnlyTextUnits() {
        let message = agentMessage("hello world")
        let document = ChatSearchDecomposition.document(for: message)

        XCTAssertEqual(document.id, message.id)
        XCTAssertEqual(document.units.count, 1)
        XCTAssertEqual(document.units[0].text, "hello world")
        XCTAssertTrue(document.units[0].isHighlightable)
    }

    /// One document per message ALWAYS — callers index the corpus positionally and compare its
    /// count against the resident window, so empty messages must not be filtered out.
    func testEmptyMessageStillProducesADocument() {
        let document = ChatSearchDecomposition.document(for: agentMessage(""))
        XCTAssertTrue(document.units.isEmpty)
    }
}
