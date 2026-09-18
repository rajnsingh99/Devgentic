// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ConversationDestinationTests.swift
//  DevgenticTests
//
//  "Which conversation do the rows and Code Viewer tabs ON SCREEN belong to?" — the question every
//  consumer of a mid-switch event has to ask, and which the codebase answered six different ways.
//  `ChatHistoryViewModel.destinationConversationID` is the answer; these tests pin it.
//
//  Its consumers are the Code Viewer's live-write guards (`handleAgentWriteBegan` /
//  `handleAgentWriteCompleted`) and `ConversationSyncService`, which injects a live stream into the
//  visible transcript. Both are VIEWER state, which is why the property is defined as
//  `loadingConversationID ?? viewerOwningConversationID` and deliberately does NOT lead the user's
//  SELECTION. ⚠️ It is not constant across a switch, though: `loadingConversationID` leads inside
//  `loadConversation` itself, so during the load this names the INCOMING conversation while the
//  array still holds the outgoing rows. That span is hidden behind the loading ProgressView and is
//  not covered here — `testTheDestinationStaysWithTheDisplayedConversationUntilTheLoadSwapsIt`
//  observes only the before and after states, because the middle needs a suspended load to see.
//
//  ⚠️ A `pendingDestinationConversationID` that DID lead the selection was added 2026-09-06 and
//  removed 2026-09-07. Two things went wrong with it, and both are worth remembering because the
//  idea is superficially attractive — it "fixes" a 250 ms window where the viewer names the
//  outgoing conversation:
//
//    1. Folding it into this property broke the Code Viewer in BOTH directions. A live-write
//       `completed` for the still-displayed conversation was dropped, leaving its tab pulsing
//       "agent is writing this file" forever — the consequence that guard's own log line states —
//       while a `began` for the incoming conversation was admitted into the outgoing viewer and
//       then stashed under the wrong conversation. The window is not a bug: during the debounce the
//       rows on screen really do belong to the outgoing conversation.
//    2. Splitting it into a separate `routingDestinationConversationID` fixed that, and left a
//       property no production code ever read — machinery set on every conversation switch and
//       cleared on every load, for no reader. Tests passed. That is the shape the project's own
//       memory records as "F2 shipped dead with 163 green tests".
//
//  If a SEND path ever needs "where is the user going?", that is a genuinely different question:
//  add it for that consumer, with that consumer, and do not route viewer state through it.
//

import XCTest
@testable import devgentic


@MainActor
private final class DestinationStubStore: ChatPersistenceProtocol {
    var all: [ChatMessage] = []

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        let scoped = all.filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp > $1.timestamp }
        return Array(scoped.dropFirst(offset).prefix(limit))
    }

    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {
        all.removeAll { $0.id == message.id }
        all.append(message)
    }

    func addConversation(from conversation: Conversation) {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func updateOpenAIThreadID(for conversationId: UUID, with threadId: String) {}
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendType: BackendType?, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}


@MainActor
final class ConversationDestinationTests: XCTestCase {

    private let convA = UUID()
    private let convB = UUID()
    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    private var store: DestinationStubStore!
    private var viewModel: ChatHistoryViewModel!

    override func setUp() async throws {
        store = DestinationStubStore()
        viewModel = ChatHistoryViewModel(
            persistenceService: store,
            activeStreamManager: ActiveStreamManager(
                persistenceService: store,
                fileProcessorService: FileProcessorService()
            )
        )
    }

    override func tearDown() async throws {
        viewModel = nil
        store = nil
    }

    private func seed(_ conversation: UUID, count: Int = 4) {
        for i in 0..<count {
            store.all.append(ChatMessage(
                id: UUID(), conversationId: conversation,
                timestamp: t0.addingTimeInterval(TimeInterval(i)),
                sender: i % 2 == 0 ? .user : .agent, content: .plainText("m\(i)")))
        }
    }

    // MARK: - What the viewer identity answers

    /// The ordinary case: nothing loading, so the destination is simply what is displayed.
    func testWithNoLoadInFlightTheDestinationIsTheLoadedConversation() async {
        seed(convA)
        await viewModel.loadConversation(id: convA)

        XCTAssertEqual(viewModel.destinationConversationID, convA)
    }

    /// ⚠️ THE PROPERTY THAT MUST NOT BE "FIXED". A selection has moved on, but until the load
    /// swaps them the rows and Code Viewer tabs on screen still belong to the OUTGOING
    /// conversation — so a live write for it must still be admitted and settled. Making this
    /// follow the selection is what left tabs pulsing "agent is writing this file" forever.
    func testTheDestinationStaysWithTheDisplayedConversationUntilTheLoadSwapsIt() async {
        seed(convA); seed(convB)
        await viewModel.loadConversation(id: convA)

        // No load for B has run yet — exactly the 250 ms debounce + model-unload span.
        XCTAssertEqual(viewModel.destinationConversationID, convA,
                       "the viewer still holds A's rows and A's tabs; an event for A belongs to A")

        await viewModel.loadConversation(id: convB)
        XCTAssertEqual(viewModel.destinationConversationID, convB,
                       "and only once the load settles does it become B")
    }

    /// Deselection is a real answer, not a missing one: there is no viewer state to update, and a
    /// consumer must treat nil as "drop it", never as "route it anywhere".
    func testDeselectionLeavesNoDestination() async {
        seed(convA)
        await viewModel.loadConversation(id: convA)

        await viewModel.loadConversation(id: nil)

        XCTAssertNil(viewModel.destinationConversationID)
        XCTAssertTrue(viewModel.currentChatMessages.isEmpty)
    }

    /// Re-selecting the conversation already open must not disturb the answer — the
    /// same-conversation reload path (the user-messages filter routes through it) runs a full
    /// `loadConversation` and must land on the same identity.
    func testReloadingTheSameConversationIsAnoOp() async {
        seed(convA)
        await viewModel.loadConversation(id: convA)
        await viewModel.loadConversation(id: convA)

        XCTAssertEqual(viewModel.destinationConversationID, convA)
    }

    /// ⚠️ The pre-cleared viewer — the case the POSITIONAL definition got wrong.
    /// `deselectConversationAndShowWelcome` and `performInterfaceSwitch` both set
    /// `currentChatMessages = []` before triggering a load, so `first?.conversationId` returned nil
    /// and `ConversationSyncService`'s observer bailed: the stream was never injected and never
    /// recorded, leaving a bubble that only appeared on reload. `loadedConversationID` still names
    /// the conversation, so the identity survives.
    func testAPreClearedViewerStillHasADestination() async {
        seed(convA)
        await viewModel.loadConversation(id: convA)
        viewModel.currentChatMessages = []

        XCTAssertNil(viewModel.currentChatMessages.first?.conversationId,
                     "precondition: the positional definition returns nil here")
        XCTAssertEqual(viewModel.destinationConversationID, convA,
                       "the destination survives a pre-cleared viewer")
    }

    /// A conversation with no messages at all still has an identity once loaded — otherwise the
    /// first stream into a brand-new chat has nowhere to be filed.
    func testAnEmptyConversationStillHasADestinationOnceLoaded() async {
        await viewModel.loadConversation(id: convA)

        XCTAssertTrue(viewModel.currentChatMessages.isEmpty)
        XCTAssertEqual(viewModel.destinationConversationID, convA)
    }

    // MARK: - The removed design must not come back by accident

    /// ⚠️ WIRING. Source-scanned, because the removed machinery is the kind of thing a future
    /// reader re-adds on sight of the 250 ms window — and the tests for it all passed while no
    /// production code read a thing.
    func testNoPendingDestinationMachineryHasBeenReintroduced() throws {
        // ⚠️ FIVE components: file → Chat → Shared → Interfaces → DevgenticTests → repo root.
        // Four lands on DevgenticTests/, the `Devgentic/` probe fails, and the whole scan
        // SKIPS while reporting green — which is what the first version of this test did.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = repoRoot.appendingPathComponent("Devgentic")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sources.path),
                          "sources not reachable at \(sources.path) — running outside a checkout")
        func code(_ path: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }

        let viewModelSource = try code("Devgentic/Interfaces/Shared/Chat/ChatHistoryViewModel.swift")
        XCTAssertFalse(viewModelSource.contains("pendingDestinationConversationID"),
                       "a pending destination that leads the selection broke the Code Viewer in "
                       + "both directions and then shipped unread — see this file's header before "
                       + "re-adding it")
        XCTAssertFalse(viewModelSource.contains("routingDestinationConversationID"),
                       "if a SEND path needs routing identity, add it WITH that consumer")
        XCTAssertTrue(viewModelSource.contains("loadingConversationID ?? viewerOwningConversationID"),
                      "destinationConversationID must remain viewer identity")
    }
}
