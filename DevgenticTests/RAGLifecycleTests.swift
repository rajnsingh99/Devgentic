// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGLifecycleTests.swift
//  devgenticTests
//
//  Batch 5 of the RAG readiness register:
//    RAG-5  — a deleted conversation's memory stays deleted: tombstones checked under the write
//             lock, plus a launch sweep that collects strays.
//    RAG-16 — the detached indexer reads a value snapshot, never the live `ChatMessage`.
//    RAG-4b — choosing a response version re-indexes the message as that version.
//

import XCTest
@testable import devgentic

@MainActor
final class RAGLifecycleTests: XCTestCase {

    private var directories: [URL] = []
    private var conversationsToClean: [UUID] = []

    override func tearDown() async throws {
        for dir in directories { try? FileManager.default.removeItem(at: dir) }
        for id in conversationsToClean { VectorStoreService.shared.deleteDocuments(forConversation: id) }
        directories = []
        conversationsToClean = []
    }

    private func testStore() throws -> VectorStoreService {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rag-lifecycle-\(UUID().uuidString)")
        directories.append(dir)
        return try VectorStoreService(testDirectory: dir, maxDatabaseSizeKB: 256 * 1024)
    }

    private func document(_ text: String, conversation: UUID, source: String? = nil)
        -> (ParentDocumentEntity, [ChildChunkEntity]) {
        let messageID = UUID()
        let parent = ParentDocumentEntity(sourceMessageID: messageID, conversationID: conversation,
                                          fullTextContent: text, sourceIdentifier: source ?? messageID.uuidString)
        let chunks = (0..<2).map {
            ChildChunkEntity(chunkText: "\(text) \($0)", embedding: [Float](repeating: 0.05, count: 384),
                             chunkIndex: $0, conversationID: conversation.uuidString)
        }
        return (parent, chunks)
    }

    // MARK: - RAG-5: tombstones

    func testAWriteAfterTheDeleteIsRefused() throws {
        let store = try testStore()
        let conv = UUID()
        let (p1, c1) = document("before the delete", conversation: conv)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p1, children: c1), .written)
        store.deleteDocuments(forConversation: conv)

        let (p2, c2) = document("an indexer that finished its embeddings late", conversation: conv)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p2, children: c2), .conversationDeleted)
        let counts = try store.documentCountsForTesting()
        XCTAssertEqual(counts.chunks, 0, "the deleted conversation's memory came back")
        XCTAssertEqual(counts.parents, 0)
    }

    /// ⚠️⚠️ The race itself: indexers and the delete in flight at once, as when a user deletes a
    /// conversation while its user message, reply and attachment are still being embedded. Whatever
    /// the interleaving, nothing of the conversation may survive.
    func testAnIndexerRacingTheDeleteNeverResurrectsTheConversation() async throws {
        let store = try testStore()
        final class Done: @unchecked Sendable { let lock = NSLock(); var value = false }
        for round in 0..<25 {
            let conv = UUID()
            let done = Done()
            Task.detached {
                await withTaskGroup(of: Void.self) { group in
                    for writer in 0..<3 {
                        group.addTask {
                            let messageID = UUID()
                            let parent = ParentDocumentEntity(sourceMessageID: messageID, conversationID: conv,
                                                              fullTextContent: "w\(writer)", sourceIdentifier: messageID.uuidString)
                            let chunks = [ChildChunkEntity(chunkText: "w\(writer)", embedding: [Float](repeating: 0.05, count: 384),
                                                           chunkIndex: 0, conversationID: conv.uuidString)]
                            store.replaceSemanticDocument(parent: parent, children: chunks)
                        }
                    }
                    group.addTask { store.deleteDocuments(forConversation: conv) }
                }
                done.lock.withLock { done.value = true }
            }
            let deadline = Date().addingTimeInterval(20)
            while !done.lock.withLock({ done.value }), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            guard done.lock.withLock({ done.value }) else { return XCTFail("round \(round): writers and delete DEADLOCKED") }
            let counts = try store.documentCountsForTesting()
            XCTAssertEqual(counts.chunks, 0, "round \(round): a write landed after the delete — the deleted conversation is back")
            if counts.chunks > 0 { return }
        }
    }

    // MARK: - RAG-5: the launch orphan sweep

    func testTheOrphanSweepRemovesOnlyConversationsThatNoLongerExist() throws {
        let store = try testStore()
        let kept = UUID(), gone = UUID(), alsoKept = UUID()
        for conv in [kept, gone, alsoKept] {
            let (p, c) = document("memory of \(conv)", conversation: conv)
            XCTAssertEqual(store.replaceSemanticDocument(parent: p, children: c), .written)
        }
        XCTAssertEqual(store.removeOrphanedConversations(liveConversationIDs: [kept, alsoKept]), 1)

        let counts = try store.documentCountsForTesting()
        XCTAssertEqual(counts.parents, 2, "only the deleted conversation's parent goes")
        XCTAssertEqual(counts.chunks, 4)
        let (p, c) = document("late write", conversation: gone)
        XCTAssertEqual(store.replaceSemanticDocument(parent: p, children: c), .conversationDeleted,
                       "a swept conversation must be tombstoned too")
    }

    /// ⚠️ "No conversations exist" is far likelier to be a store that did not load than a user who
    /// deleted everything — obeying it would erase every conversation's memory.
    func testTheOrphanSweepRefusesAnEmptyConversationList() throws {
        let store = try testStore()
        let (p, c) = document("must survive", conversation: UUID())
        XCTAssertEqual(store.replaceSemanticDocument(parent: p, children: c), .written)
        XCTAssertEqual(store.removeOrphanedConversations(liveConversationIDs: []), 0)
        XCTAssertEqual(try store.documentCountsForTesting().parents, 1)
    }

    /// WIRING: the sweep runs at launch — and only on the gated `.run` branch (it is destructive).
    func testTheLaunchSweepCollectsOrphansOnlyWhenTheSchemaIsUnchanged() throws {
        let source = try sourceText("Devgentic/DevgenticApp.swift")
        let run = try XCTUnwrap(source.range(of: "case .run:"))
        let deferred = try XCTUnwrap(source.range(of: "case .deferSchemaChanged", range: run.upperBound..<source.endIndex))
        let runBranch = source[run.upperBound..<deferred.lowerBound]
        XCTAssertTrue(runBranch.contains("removeOrphanedConversations(liveConversationIDs:"), "the launch sweep no longer collects orphaned memory")
        XCTAssertTrue(runBranch.contains("try ChatPersistenceStore.shared.liveConversationIDs()"), "the sweep must use the THROWING listing")
        XCTAssertEqual(source.components(separatedBy: "removeOrphanedConversations(").count - 1, 1,
                       "the orphan sweep must run only from the gated branch")
    }

    // MARK: - RAG-16: the indexer reads a snapshot

    func testASnapshotIsFrozenAgainstLaterEdits() {
        let message = ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .agent,
                                  content: .markdownText("The settled answer."))
        let snapshot = IndexableMessage(message)
        message.content = .markdownText("A regenerated answer still streaming…")
        XCTAssertEqual(snapshot.textContent, "The settled answer.")
        XCTAssertEqual(snapshot.blocksForIndexing().map(\.plainText).joined(), "The settled answer.")
    }

    func testTheSnapshotParsesExactlyLikeTheMessage() {
        let contents: [MessageContent] = [
            .markdownText("# Title\n\nPara one.\n\n- item\n\n```swift\nlet x = 1\n```"),
            .plainText("plain"), .codeBlock(language: "python", code: "print(1)"),
            .checkpoint(summary: "Summary of earlier turns."),
            .error(title: "Oops", details: "failed")
        ]
        for content in contents {
            let message = ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .agent, content: content)
            XCTAssertEqual(IndexableMessage(message).blocksForIndexing().map(\.plainText),
                           message.getBlocksForIndexing().map(\.plainText))
        }
        XCTAssertTrue(IndexableMessage(ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .agent,
                                                   content: .error(title: nil, details: "x"))).isError)
    }

    /// WIRING: both indexing call sites snapshot on the main actor BEFORE detaching.
    func testBothCallSitesSnapshotBeforeDetaching() throws {
        let manager = try sourceText("Devgentic/Core/Utils/ActiveStreamManager.swift")
        let snap = try XCTUnwrap(manager.range(of: "let indexable = IndexableMessage(message)"))
        let detach = try XCTUnwrap(manager.range(of: "Task.detached(priority: .background) {", range: snap.upperBound..<manager.endIndex))
        XCTAssertLessThan(manager.distance(from: snap.upperBound, to: detach.lowerBound), 200,
                          "the finalize path must snapshot right before detaching")

        let store = try sourceText("Devgentic/Core/Persistence/SwiftData/ChatPersistenceStore.swift")
        XCTAssertTrue(store.contains(".filter { $0.sender == .user }.map { IndexableMessage($0) }"),
                      "the user-message path must snapshot before detaching")
    }

    // MARK: - RAG-4b: the version picker re-indexes

    /// ⚠️⚠️ The index holds the NEWEST version; choosing an older one left memory describing the
    /// answer the user had just turned away from.
    func testChoosingAnOlderVersionReindexesTheMessageAsThatVersion() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let conv = UUID(); conversationsToClean.append(conv)
        let message = ChatMessage(id: UUID(), conversationId: conv, timestamp: Date(), sender: .agent,
                                  content: .markdownText("Project Kestrel ships in June, after the vendor audit."))
        message.agentResponse = AgentResponse(variants: [
            ResponseMessageVariant(content: .markdownText("Project Kestrel ships in March, after the hardware review."), backendEntityId: nil),
            ResponseMessageVariant(content: .markdownText("Project Kestrel ships in June, after the vendor audit."), backendEntityId: nil)
        ], selectedVariantIndex: 1)
        await RAGIndexingService.shared.indexSingleMessage(IndexableMessage(message))

        message.agentResponse?.selectedVariantIndex = 0
        await RAGIndexingService.reindexSelectedVariant(of: message)?.value

        let recalled = await BackendOrchestrationService.conversationMemoryContext(
            query: "When does Project Kestrel ship?", lexicalQuery: "When does Project Kestrel ship?",
            profile: BackendProfileModel(displayName: "bot", details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: .mlx, modelName: "m")))),
            conversationID: conv, originalHistory: [], shippedHistory: [], currentTurnFiles: [],
            regenerating: nil, contextWindowTokens: 8_192, traceID: "test")
        XCTAssertTrue(recalled?.contains("March") == true, "memory does not hold the chosen version — got: \(recalled ?? "nil")")
        XCTAssertFalse(recalled?.contains("June") == true, "memory still holds the version the user turned away from")
    }

    /// WIRING: the picker's action calls the re-index.
    func testTheVersionPickerReindexes() throws {
        let view = try sourceText("Devgentic/Interfaces/Shared/Chat/ChatBubbleView.swift")
        let set = try XCTUnwrap(view.range(of: "message.agentResponse?.selectedVariantIndex = index"))
        let call = try XCTUnwrap(view.range(of: "RAGIndexingService.reindexSelectedVariant(of: message)", range: set.upperBound..<view.endIndex))
        XCTAssertLessThan(view.distance(from: set.upperBound, to: call.lowerBound), 200)
    }

    // MARK: - Source access

    private func sourceText(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
