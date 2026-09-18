// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RenderAndPlaybackFixTests.swift
//  DevgenticTests
//
//  The 2026-09-12 batch from the functional+performance audit register:
//  mc-1/mm-1 (markdown cache keyed on its source text), mm-2 (indexing is pure),
//  RS-3 (pagination epoch guard), mc-2 (path-list separator), mc-4 (link affordance).
//
//  Each test is written to FAIL if its fix is reverted — see each doc comment for the
//  mutation that must kill it.
//

import XCTest
import SwiftUI
@testable import devgentic

@MainActor
private final class PagingStubStore: ChatPersistenceProtocol {
    /// Messages handed back by `fetchMessages`, regardless of offset.
    var page: [ChatMessage] = []
    /// Runs INSIDE `fetchMessages`, i.e. while `loadMoreMessages` is suspended on it. This is
    /// the deterministic stand-in for "the user clicked another conversation mid-fetch".
    var duringFetch: (@MainActor () -> Void)?

    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        duringFetch?()
        return page
    }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

@MainActor
final class RenderAndPlaybackFixTests: XCTestCase {

    // MARK: - mc-1 / mm-1: the markdown cache is keyed on the text it parsed

    private func agentMessage(_ text: String) -> ChatMessage {
        ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText(text))
    }

    /// ⚠️ THE REGRESSION GUARD for the version-switch bug. `getOrCreateMarkdownBlocks(from:)`
    /// used to return `cachedMarkdownBlocks` whenever it was non-nil, IGNORING its `text`
    /// argument — so after the bubble had rendered variant 1, selecting variant 2 re-rendered
    /// variant 1's prose. Mutation that must kill this: drop `cachedMarkdownSource == text`
    /// from either cache-hit guard.
    func testSwitchingVariantsReparsesInsteadOfReturningThePreviousVariantsBlocks() throws {
        let message = agentMessage("first answer")
        // Render variant 1 — this is what warms the cache.
        let first = message.getOrCreateMarkdownBlocks(from: "first answer")
        XCTAssertTrue(blockText(first).contains("first answer"))
        XCTAssertNotNil(message.cachedMarkdownBlocks, "the render warmed the cache")

        // A regeneration appends a second variant and selects it. The picker does NOT call
        // `invalidateMarkdownCache()` — that is precisely why the key has to carry the weight.
        XCTAssertTrue(message.beginRegenerationVariant(backendEntityId: nil))
        let response = try XCTUnwrap(message.agentResponse)
        message.agentResponse?.variants[response.selectedVariantIndex].content =
            .markdownText("second answer")
        message.isStreaming = false

        guard case .markdownText(let shown) = message.displayedContent else {
            return XCTFail("the message should display the selected variant's markdown")
        }
        XCTAssertEqual(shown, "second answer", "displayedContent resolves through the variant")

        let second = message.getOrCreateMarkdownBlocks(from: shown)
        XCTAssertTrue(blockText(second).contains("second answer"),
                      "the bubble must render the SELECTED variant, not the cached one")
        XCTAssertFalse(blockText(second).contains("first answer"),
                       "the previous variant's prose must not survive the switch")
    }

    /// The memoisation must still work, or the fix would be a per-body re-parse of every
    /// message. Same text twice returns the identical block ids.
    /// ⚠️ Observes the CACHE, not the block ids. The first version compared `map(\.id)` — and
    /// `ContentBlock.id` is a POSITIONAL string ("block-0", "block-1"), so a fresh re-parse of the
    /// same text produces identical ids and the assertion held whether or not the cache was used.
    func testUnchangedTextStillHitsTheCache() {
        let message = agentMessage("stable text")
        XCTAssertNil(message.cachedMarkdownBlocks, "precondition: cold")

        _ = message.getOrCreateMarkdownBlocks(from: "stable text")
        XCTAssertNotNil(message.cachedMarkdownBlocks, "the first call populates the cache")
        XCTAssertEqual(message.cachedMarkdownSourceForTesting, "stable text",
                       "…keyed on the text it parsed")

        // Poison the cache with a value a re-parse could never produce. A second call for the
        // SAME text must return it, which is only possible if the cache was consulted.
        let sentinel = [ContentBlock(id: "sentinel", type: .paragraph("served from cache"))]
        message.cachedMarkdownBlocks = sentinel
        let second = message.getOrCreateMarkdownBlocks(from: "stable text")
        XCTAssertEqual(second.map(\.id), ["sentinel"],
                       "identical text must be served from the cache, not re-parsed")
    }

    /// `invalidateMarkdownCache()` must clear the KEY too. If it cleared only the blocks, the
    /// next parse would re-cache under a stale source and the guard would be wrong from then on.
    func testInvalidateClearsTheKeyAsWellAsTheBlocks() {
        let message = agentMessage("text")
        _ = message.getOrCreateMarkdownBlocks(from: "text")
        message.invalidateMarkdownCache()
        XCTAssertNil(message.cachedMarkdownBlocks)
        // Re-parsing different text after an invalidate must produce THAT text.
        let blocks = message.getOrCreateMarkdownBlocks(from: "other text")
        XCTAssertTrue(blockText(blocks).contains("other text"))
    }

    // MARK: - mm-2: the RAG indexer must not touch the cache

    /// The indexer runs DETACHED against the same `ChatMessage` the main actor renders, so it
    /// must not write `cachedMarkdownBlocks`. Mutation that must kill this: route
    /// `getBlocksForIndexing` back through `getOrCreateMarkdownBlocks`.
    func testIndexingDoesNotPopulateTheRenderCache() {
        let message = agentMessage("indexed prose")
        XCTAssertNil(message.cachedMarkdownBlocks, "precondition: cold cache")

        let blocks = message.getBlocksForIndexing()

        XCTAssertFalse(blocks.isEmpty, "indexing still returns parsed blocks")
        XCTAssertTrue(blockText(blocks).contains("indexed prose"))
        XCTAssertNil(message.cachedMarkdownBlocks,
                     "indexing must leave the render cache untouched — it runs off the main actor")
    }

    /// The checkpoint case routes through the same pure path.
    func testIndexingACheckpointDoesNotPopulateTheRenderCache() {
        let message = ChatMessage(conversationId: UUID(), sender: .agent,
                                  content: .checkpoint(summary: "compacted summary"))
        _ = message.getBlocksForIndexing()
        XCTAssertNil(message.cachedMarkdownBlocks)
    }

    // MARK: - RS-3: pagination must not append across a conversation switch

    /// ⚠️ Deterministic interleaving: the store performs the conversation switch while
    /// `loadMoreMessages` is suspended on the fetch. Without the epoch guard, conversation A's
    /// older messages are appended onto whatever array is resident when the fetch returns.
    /// Mutation that must kill this: delete the `guard myEpoch == loadEpoch` block.
    func testPageInIsDiscardedWhenTheConversationChangedDuringTheFetch() async {
        let store = PagingStubStore()
        let viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )

        let conversationA = UUID()
        let resident = (0..<4).map { i in
            ChatMessage(conversationId: conversationA, sender: .user,
                        content: .markdownText("A-resident-\(i)"))
        }
        viewModel.currentChatMessages = resident
        viewModel.canLoadMorePages = true

        // The older page the store is about to hand back — all conversation A's.
        store.page = (0..<3).map { i in
            ChatMessage(conversationId: conversationA, sender: .user,
                        content: .markdownText("A-older-\(i)"))
        }
        // …and the switch lands inside the fetch. Bumping the epoch is what `loadConversation`
        // does first; doing it directly keeps the test on the guard rather than on a full load.
        store.duringFetch = { [weak viewModel] in
            viewModel?.bumpLoadEpochForTesting()
        }

        await viewModel.loadMoreMessages()

        XCTAssertEqual(viewModel.currentChatMessages.count, resident.count,
                       "a stale page must not be appended after the conversation changed")
        XCTAssertFalse(viewModel.isLoadingPage,
                       "…and pagination must not stay wedged for the conversation switched TO")
    }

    /// The guard must not break the ordinary path: with no switch, the page still lands.
    func testPageInStillAppendsWhenTheConversationDidNotChange() async {
        let store = PagingStubStore()
        let viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            ),
            ownsCodeViewer: true
        )
        let conversationA = UUID()
        viewModel.currentChatMessages = (0..<4).map { i in
            ChatMessage(conversationId: conversationA, sender: .user,
                        content: .markdownText("A-resident-\(i)"))
        }
        viewModel.canLoadMorePages = true
        store.page = [ChatMessage(conversationId: conversationA, sender: .user,
                                  content: .markdownText("A-older-0"))]

        await viewModel.loadMoreMessages()

        XCTAssertEqual(viewModel.currentChatMessages.count, 5, "the page is appended as normal")
        XCTAssertFalse(viewModel.isLoadingPage)
    }

    // MARK: - mc-2: the path-list separator must survive rendering

    /// ⚠️ Asserts the RENDERED string, not the preprocessed text — that distinction is the
    /// whole finding. A "\n\n" separator passes any test that inspects the block text and
    /// still fuses the paths on screen, because `AttributedString(markdown:)` contributes NO
    /// character for a paragraph boundary. Mutation that must kill this: change the separator
    /// back to "\n\n".
    func testAPathListRendersWithLineBreaksRatherThanFusedTogether() throws {
        let source = """
        /Users/me/proj/src/Main.java
        /Users/me/proj/src/Util.java
        /Users/me/proj/test/MainTest.java
        /Users/me/proj/build.gradle
        """
        let processed = preprocessMarkdownText(source)
        let rendered = String(try AttributedString(markdown: processed).characters)

        XCTAssertFalse(rendered.contains("Main.java/Users"),
                       "the paths must not fuse — a path copied out of that does not exist")
        XCTAssertTrue(rendered.contains("Main.java\n"),
                      "each path keeps its own line (a markdown HARD break survives; a soft one becomes a space and a paragraph break becomes nothing)")
        for name in ["Main.java", "Util.java", "MainTest.java", "build.gradle"] {
            XCTAssertTrue(rendered.contains(name), "\(name) survives the transform")
        }
    }

    /// Pins the Foundation semantics the fix rests on, so a future change to the separator is
    /// evaluated against measured behaviour rather than an assumption.
    func testAttributedStringBreakSemanticsThatTheSeparatorChoiceDependsOn() throws {
        XCTAssertEqual(String(try AttributedString(markdown: "a\nb").characters), "a b",
                       "a SOFT break renders as one space")
        XCTAssertEqual(String(try AttributedString(markdown: "a\n\nb").characters), "ab",
                       "a PARAGRAPH boundary contributes NO character — this is what fused the paths")
        XCTAssertEqual(String(try AttributedString(markdown: "a  \nb").characters), "a\nb",
                       "a HARD break is the only form that survives as a line break")
    }

    /// Prose that does not look like a path list must pass through untouched.
    func testOrdinaryProseIsNotRewritten() {
        let prose = "Just a sentence.\nAnd another one.\nA third."
        XCTAssertEqual(preprocessMarkdownText(prose), prose,
                       "the heuristic needs >3 lines with more than half containing a slash")
    }

    // MARK: - mc-4: a link needs an affordance

    /// ⚠️ HONEST SCOPE. `createStyledString` is `private` on two SwiftUI views
    /// (`ContentBlockView`, `WorkflowMarkdownView`) and takes `Font`/`Color` from the
    /// environment, so the branch itself has no test seam and extracting one would yield a
    /// function that returns its own argument. The branch wiring was verified by reading both
    /// call sites; what is pinned here is the Foundation fact that makes the branch NECESSARY —
    /// that `.link` alone provides no underline — because that is the assumption a future
    /// author would otherwise re-make. The old comment asserting the opposite is what shipped
    /// the bug.
    func testMarkdownLinkCarriesNoUnderlineOfItsOwn() throws {
        let parsed = try XCTUnwrap(try? AttributedString(markdown: "see [docs](https://example.com) here"))
        let linkRun = parsed.runs.first { $0.link != nil }
        let run = try XCTUnwrap(linkRun, "the parse must produce a run carrying .link")

        XCTAssertNil(run.underlineStyle,
                     "AttributedString(markdown:) sets NO underline on a link — the renderer must set one, which is why the `run.link != nil` branch exists")
        XCTAssertNil(run.inlinePresentationIntent,
                     "a link carries no inlinePresentationIntent, so it reaches the renderer's final `else` unless a branch claims it first — that is how it ended up painted as body text")
    }

    // MARK: - helpers

    /// `ContentBlock.plainText` is the codebase's own recursive flattener — used rather than a
    /// local switch so a new block kind cannot silently start flattening to "".
    private func blockText(_ blocks: [ContentBlock]) -> String {
        blocks.map(\.plainText).joined(separator: "\n")
    }
}
