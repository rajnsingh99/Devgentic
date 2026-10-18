// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGRetrievalScopeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import ObjectBox
@testable import devgentic

@MainActor
final class RAGRetrievalScopeTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 9_000_000)
    private var conversationsToClean: [UUID] = []
    private var filesToClean: [URL] = []

    override func tearDown() async throws {
        for id in conversationsToClean { VectorStoreService.shared.deleteDocuments(forConversation: id) }
        for url in filesToClean { try? FileManager.default.removeItem(at: url) }
        conversationsToClean = []
        filesToClean = []
    }

    // MARK: - Fixtures

    private func message(_ sender: SenderRole, _ text: String, _ i: Int, in conversation: UUID) -> ChatMessage {
        ChatMessage(id: UUID(), conversationId: conversation, timestamp: t0.addingTimeInterval(TimeInterval(i)),
                    sender: sender, content: .plainText(text))
    }

    /// `pairs` turns of distinct small talk, oldest first. `answers[n]` replaces turn n's reply.
    private func conversation(_ id: UUID, pairs: Int, answers: [Int: String] = [:]) -> [ChatMessage] {
        let topics = ["pasta sauces", "garden tomatoes", "bicycle gears", "tide pools", "jazz chords",
                      "bread starters", "chess openings", "camping stoves", "paper kites", "river otters",
                      "pottery glazes", "wind chimes", "fern spores", "coffee grinders", "map projections"]
        return (0..<pairs).flatMap { n -> [ChatMessage] in
            let topic = topics[n % topics.count]
            let reply = answers[n] ?? "Here are some thoughts about \(topic): they reward patience and practice."
            return [message(.user, "Tell me something about \(topic).", n * 2, in: id),
                    message(.agent, reply, n * 2 + 1, in: id)]
        }
    }

    private func profile(_ provider: ApiProvider) -> BackendProfileModel {
        BackendProfileModel(displayName: "Memory bot",
                            details: .bot(BotConfig(llmConfig: ProviderConfig(apiProvider: provider, modelName: "test-model"))))
    }

    private static let fact = "Project Kestrel ships on the fourteenth of March, after the hardware review."
    private static let question = "When does Project Kestrel ship?"

    private func index(_ messages: [ChatMessage]) async {
        for m in messages { await RAGIndexingService.shared.indexSingleMessage(IndexableMessage(m)) }
    }

    /// Runs Section 3 retrieval exactly as the send path composes it. `current` is the turn's
    /// own user row: it is in the fetched history and stripped from what ships.
    private func recall(conversation id: UUID, history: [ChatMessage], current: ChatMessage,
                        provider: ApiProvider = .anthropic, files: [FileSystemItem] = [],
                        regenerating: RegenerationBoundary? = nil) async -> String? {
        await BackendOrchestrationService.conversationMemoryContext(
            query: Self.question, lexicalQuery: Self.question, profile: profile(provider),
            conversationID: id, originalHistory: history + [current], shippedHistory: history,
            currentTurnFiles: files, regenerating: regenerating,
            contextWindowTokens: 128_000, traceID: "test")
    }

    // MARK: - RAG-1: carried in full, per strategy (pure)

    func testRecentHistoryCarriesOnlyTheTurnLimitInFull() {
        let id = UUID()
        let history = conversation(id, pairs: 15)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .recentHistory, from: history, charBudget: 1_000_000, toolsAvailable: false)
        let lastTen = Set(history.suffix(EpisodicHistoryFormatter.recentTurnLimit * 2).map(\.id))
        XCTAssertEqual(native.messageIDsCarriedInFull, lastTen,
                       "exactly the last \(EpisodicHistoryFormatter.recentTurnLimit) turns — questions AND answers — ride in full")
        XCTAssertFalse(native.messageIDsCarriedInFull.contains(history[0].id), "turn 1 is outside the window")
    }

    func testTheCharBudgetNarrowsWhatIsCarried() {
        let id = UUID()
        let history = conversation(id, pairs: 15)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .recentHistory, from: history, charBudget: 250, toolsAvailable: false)
        XCTAssertLessThan(native.messageIDsCarriedInFull.count, EpisodicHistoryFormatter.recentTurnLimit * 2,
                          "a turn the budget dropped is not in the prompt, so it must stay retrievable")
        XCTAssertTrue(native.messageIDsCarriedInFull.isSubset(of: Set(history.map(\.id))))
    }

    func testPointerCarriesEveryQuestionButNoAnswer() {
        let id = UUID()
        let history = conversation(id, pairs: 4)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .pointer, from: history, charBudget: 1_000_000, toolsAvailable: true)
        XCTAssertEqual(native.fullUserMessageIDs, Set(history.filter { $0.sender == .user }.map(\.id)))
        XCTAssertTrue(native.fullAnswerMessageIDs.isEmpty, "a skeleton replaces the answer with a fetch instruction")
    }

    func testHybridCarriesEveryQuestionAndOnlyTheInlineAnswers() {
        let id = UUID()
        let history = conversation(id, pairs: 6)
        let native = NativeHistoryConverter.buildCarryingProvenance(
            strategy: .hybrid, from: history, charBudget: 1_000_000, toolsAvailable: true)
        XCTAssertEqual(native.fullUserMessageIDs, Set(history.filter { $0.sender == .user }.map(\.id)))
        XCTAssertEqual(native.fullAnswerMessageIDs,
                       Set(history.filter { $0.sender == .agent }.suffix(EpisodicHistoryFormatter.hybridInlineCount).map(\.id)))
    }

    // MARK: - RAG-1/4/15: the exclusion policy (pure)

    func testACloudBotExcludesTheCarriedWindowAndTheCurrentMessageOnly() {
        let id = UUID()
        let history = conversation(id, pairs: 15)
        let current = message(.user, Self.question, 99, in: id)
        let exclusion = BackendOrchestrationService.retrievalExclusion(
            profile: profile(.anthropic), originalHistory: history + [current], shippedHistory: history,
            currentTurnFiles: [], regenerating: nil, contextWindowTokens: 128_000)
        XCTAssertTrue(exclusion.messageIDs.contains(current.id), "the query must not retrieve its own echo")
        XCTAssertTrue(exclusion.messageIDs.contains(history.last!.id))
        XCTAssertFalse(exclusion.messageIDs.contains(history[0].id),
                       "turn 1 is not in the prompt — excluding it made conversation memory unable to recall it")
        XCTAssertNil(exclusion.indexedAtOrAfter)
    }

    func testAProfileWithoutNativeTurnsExcludesOnlyTheCurrentMessage() {
        let id = UUID()
        let history = conversation(id, pairs: 3)
        let current = message(.user, Self.question, 99, in: id)
        let exclusion = BackendOrchestrationService.retrievalExclusion(
            profile: profile(.mlx), originalHistory: history + [current], shippedHistory: history,
            currentTurnFiles: [], regenerating: nil, contextWindowTokens: 8_192)
        XCTAssertEqual(exclusion.messageIDs, [current.id],
                       "MLX sees history only as 80/200-char clips, so no past turn is carried in full")
    }

    func testARedoExcludesTheRejectedReplyAndEverythingAfterIt() {
        let id = UUID()
        let history = conversation(id, pairs: 2)
        let rejected = message(.agent, "old answer", 50, in: id)
        let exclusion = BackendOrchestrationService.retrievalExclusion(
            profile: profile(.anthropic), originalHistory: history, shippedHistory: history,
            currentTurnFiles: [], regenerating: RegenerationBoundary(messageID: rejected.id, timestamp: rejected.timestamp),
            contextWindowTokens: 128_000)
        XCTAssertTrue(exclusion.messageIDs.contains(rejected.id))
        XCTAssertEqual(exclusion.indexedAtOrAfter, rejected.timestamp)
    }

    func testThisTurnsAttachmentsAreExcludedByPath() {
        let url = URL(fileURLWithPath: "/tmp/spec.md")
        let exclusion = BackendOrchestrationService.retrievalExclusion(
            profile: profile(.anthropic), originalHistory: [], shippedHistory: [],
            currentTurnFiles: [FileSystemItem(id: url, name: "spec.md", url: url, isDirectory: false)],
            regenerating: nil, contextWindowTokens: 128_000)
        XCTAssertEqual(exclusion.sourceIdentifiers, [url.path])
    }

    // MARK: - RetrievalExclusion matching (pure)

    func testMessageIDsMatchMessageParentsOnly() {
        let turn = UUID()
        let exclusion = RetrievalExclusion(messageIDs: [turn])
        XCTAssertTrue(exclusion.excludes(sourceMessageID: turn, sourceIdentifier: turn.uuidString, timestamp: t0))
        XCTAssertTrue(exclusion.excludes(sourceMessageID: turn, sourceIdentifier: "", timestamp: t0),
                      "a row written before sourceIdentifier existed is a message row")
        XCTAssertFalse(exclusion.excludes(sourceMessageID: turn, sourceIdentifier: "/docs/spec.md", timestamp: t0),
                       "the carrying turn being in the prompt does not put the FILE's content there")
    }

    func testTheRedoCutoffIsInclusive() {
        let exclusion = RetrievalExclusion(indexedAtOrAfter: t0)
        XCTAssertTrue(exclusion.excludes(sourceMessageID: UUID(), sourceIdentifier: "", timestamp: t0))
        XCTAssertTrue(exclusion.excludes(sourceMessageID: UUID(), sourceIdentifier: "/f.md", timestamp: t0.addingTimeInterval(5)))
        XCTAssertFalse(exclusion.excludes(sourceMessageID: UUID(), sourceIdentifier: "", timestamp: t0.addingTimeInterval(-1)))
    }

    // MARK: - RAG-19: the retrieval query (pure)

    func testMemoryIsSearchedWithWhatTheUserSaid() {
        let said = message(.user, "what time is it in Lisbon", 0, in: UUID())
        let decorated = "what time is it in Lisbon\n\n(You are speaking through a text-to-speech voice. No markdown, no bullet lists.)"
        XCTAssertEqual(ActiveStreamManager.retrievalQuery(for: said, modelQuery: decorated), "what time is it in Lisbon")
    }

    func testATextlessTurnFallsBackToTheModelQuery() {
        let blank = message(.user, "   ", 0, in: UUID())
        XCTAssertEqual(ActiveStreamManager.retrievalQuery(for: blank, modelQuery: "describe this image"), "describe this image")
    }

    // MARK: - WIRING: the send path's composition against the real store

    /// ⚠️⚠️ RAG-1. A fact from turn 1 of 15 is outside the 10 turns the prompt carries. Under the
    /// old blanket exclusion it was ALSO unretrievable — conversation memory could not recall it.
    func testAnOldTurnOutsideThePromptIsRecalled() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let id = UUID(); conversationsToClean.append(id)
        let history = conversation(id, pairs: 15, answers: [0: Self.fact])
        await index(history)
        let current = message(.user, Self.question, 99, in: id)

        let context = await recall(conversation: id, history: history, current: current)
        XCTAssertTrue(context?.contains("Kestrel") == true,
                      "turn 1 is not in the prompt, so retrieval is the only way the model can see it — got: \(context ?? "nil")")
    }

    /// The other half: a turn the prompt carries in full is NOT re-injected.
    func testATurnCarriedInFullIsNotReinjected() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let id = UUID(); conversationsToClean.append(id)
        let history = conversation(id, pairs: 15, answers: [14: Self.fact])
        await index(history)
        let current = message(.user, Self.question, 99, in: id)

        let context = await recall(conversation: id, history: history, current: current)
        XCTAssertFalse(context?.contains("Kestrel") == true, "the newest turn rides in full — re-injecting it wastes a slot")

        // Control: on MLX nothing rides in full (history is 80/200-char clips), so the SAME turn
        // is retrieved — proving the assertion above is the exclusion, not an empty index.
        let mlx = await recall(conversation: id, history: history, current: current, provider: .mlx)
        XCTAssertTrue(mlx?.contains("Kestrel") == true, "fixture no longer exercises retrieval — got: \(mlx ?? "nil")")
    }

    /// ⚠️⚠️ RAG-4. Redo of turn 3: the rejected answer is the closest document to the question.
    func testARedoNeverRetrievesTheRejectedReply() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let id = UUID(); conversationsToClean.append(id)
        let full = conversation(id, pairs: 3, answers: [2: Self.fact])
        await index(full)
        let rejected = full[5]
        let before = Array(full.prefix(4)) // `historySlice(before:)` — the redo's user row is full[4]
        let redoUser = full[4]

        let boundary = RegenerationBoundary(messageID: rejected.id, timestamp: rejected.timestamp)
        let context = await recall(conversation: id, history: before, current: redoUser, regenerating: boundary)
        XCTAssertFalse(context?.contains("Kestrel") == true, "the rejected answer was fed back to the model it was rejected from")

        // Control: without the boundary the rejected reply IS the top hit — the test can see it.
        let unbounded = await recall(conversation: id, history: before, current: redoUser)
        XCTAssertTrue(unbounded?.contains("Kestrel") == true, "fixture no longer exercises the leak — got: \(unbounded ?? "nil")")
    }

    /// ⚠️⚠️ RAG-15 + RAG-14. A file attached again THIS turn is delivered fresh; its indexed copy
    /// is the previous version and must not ride beside it.
    func testThisTurnsAttachmentIsNotRetrievedInItsOldVersion() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let id = UUID(); conversationsToClean.append(id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-\(UUID().uuidString).md")
        filesToClean.append(url)
        try Self.fact.write(to: url, atomically: true, encoding: .utf8)
        let file = FileSystemItem(id: url, name: url.lastPathComponent, url: url, isDirectory: false)

        let history = conversation(id, pairs: 2)
        let carrier = history[2]
        await RAGIndexingService.shared.indexAttachedFiles(files: [file], conversationID: id,
                                                           messageID: carrier.id, messageTimestamp: carrier.timestamp)
        let current = message(.user, Self.question, 99, in: id)

        let attachedAgain = await recall(conversation: id, history: history, current: current, files: [file])
        XCTAssertFalse(attachedAgain?.contains("Kestrel") == true, "the file reached the model twice")

        // RAG-14: the file belongs to its carrying turn, yet that turn being carried in full does
        // NOT hide the file — the file's content is not in the prompt.
        let laterTurn = await recall(conversation: id, history: history, current: current)
        XCTAssertTrue(laterTurn?.contains("Kestrel") == true,
                      "a file whose carrying turn is in the window must stay recallable — got: \(laterTurn ?? "nil")")

        // RAG-14: dated to its TURN. A Redo of the reply AFTER the carrying turn keeps the file —
        // it arrived before the boundary. Dated to indexing time, it would fall past the cutoff.
        let replyAfterCarrier = history[3]
        let redo = await recall(conversation: id, history: Array(history.prefix(2)), current: carrier,
                                regenerating: RegenerationBoundary(messageID: replyAfterCarrier.id,
                                                                   timestamp: replyAfterCarrier.timestamp))
        XCTAssertTrue(redo?.contains("Kestrel") == true,
                      "a file is dated to when it was indexed, so a Redo of its own turn lost it — got: \(redo ?? "nil")")
    }

    // MARK: - Batch 2 (CR-29 / RAG-2 / RAG-8): cost shape and thread

    /// ⚠️⚠️ The ranker decodes each parent ONCE. Resolving `parentDocument.target` decodes the
    /// parent's whole text, and every chunk holds its own `ToOne` — so one large attachment under
    /// excluded history was decoded once per candidate (1.3 s of a 1.6 s send, -O). Asserted as
    /// WORK DONE, not time: a stopwatch flakes, a count does not.
    func testTheRankerDecodesEachParentOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rank-decode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try Store(directoryPath: dir.path)
        defer { store.close(); try? FileManager.default.removeItem(at: dir) }
        let childBox = store.box(for: ChildChunkEntity.self)
        let conv = UUID()

        func near(_ lean: Float) -> [Float] {
            var v = [Float](repeating: 0, count: 384); v[0] = 1 - lean; v[1] = lean
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 }); return v.map { $0 / n }
        }
        // One attached file: 200 chunks, all close to the query, one parent.
        let file = ParentDocumentEntity(sourceMessageID: UUID(), conversationID: conv,
                                        fullTextContent: "the whole file", sourceIdentifier: "/docs/big.md")
        let fileChunks = (0..<200).map { i -> ChildChunkEntity in
            let c = ChildChunkEntity(chunkText: "file \(i)", embedding: near(0.05 + Float(i) * 0.001), chunkIndex: i, conversationID: conv.uuidString)
            c.parentDocument.target = file; return c
        }
        try childBox.put(fileChunks)
        // Twenty history turns the request carries in full — excluded, and CLOSER than the file.
        var history: Set<UUID> = []
        for i in 0..<20 {
            let id = UUID(); history.insert(id)
            let parent = ParentDocumentEntity(sourceMessageID: id, conversationID: conv,
                                              fullTextContent: "turn \(i)", sourceIdentifier: id.uuidString)
            let c = ChildChunkEntity(chunkText: "turn \(i)", embedding: near(0.01), chunkIndex: 0, conversationID: conv.uuidString)
            c.parentDocument.target = parent
            try childBox.put(c)
        }
        let chunks = try childBox.query { ChildChunkEntity.conversationID == conv.uuidString }.build().find()

        var decodes = 0
        let hits = VectorStoreService.rankConversationChunks(
            chunks, against: near(0), queryText: nil, limit: 3, maximumDistance: 0.7,
            exclusion: RetrievalExclusion(messageIDs: history),
            resolveParent: { decodes += 1; return $0.parentDocument.target })

        XCTAssertEqual(hits.map(\.sourceIdentifier), ["/docs/big.md"], "the file is the only injectable parent")
        XCTAssertEqual(decodes, 21, "each of the 21 parents decoded once — got \(decodes) for \(chunks.count) chunks")
    }

    /// ⚠️⚠️ CR-29 WIRING: the send path's retrieval scans OFF the main thread. The test runs on
    /// the main actor, exactly like `BackendOrchestrationService`; if the hop is lost the scan
    /// reports `onMainThread == true`.
    func testTheSendPathScansOffTheMainThread() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let id = UUID(); conversationsToClean.append(id)
        let history = conversation(id, pairs: 2, answers: [0: Self.fact])
        await index(history)

        final class Seen: @unchecked Sendable { let lock = NSLock(); var values: [Bool] = [] }
        let seen = Seen()
        VectorStoreService.scanThreadObserver = { onMain in seen.lock.withLock { seen.values.append(onMain) } }
        defer { VectorStoreService.scanThreadObserver = nil }

        _ = await recall(conversation: id, history: history, current: message(.user, Self.question, 99, in: id), provider: .mlx)
        XCTAssertEqual(seen.lock.withLock { seen.values }, [false], "the scan ran on the main thread (or did not run)")
    }

    /// RAG-8: delete reads parent IDS off the relation — it must still remove the PARENTS, not
    /// just the chunks a search would show. Drives the real API.
    func testDeletingAConversationRemovesItsChunksAndParents() async throws {
        try XCTSkipUnless(VectorStoreService.shared.isAvailable)
        let doomed = UUID(), survivor = UUID()
        conversationsToClean += [doomed, survivor]
        await index(conversation(doomed, pairs: 3))
        await index(conversation(survivor, pairs: 1, answers: [0: Self.fact]))

        let before = try VectorStoreService.shared.documentCountsForTesting()
        VectorStoreService.shared.deleteDocuments(forConversation: doomed)
        let after = try VectorStoreService.shared.documentCountsForTesting()

        XCTAssertEqual(before.parents - after.parents, 6, "one parent per message of the 3 deleted turns")
        XCTAssertGreaterThanOrEqual(before.chunks - after.chunks, 6)
        let survivorRecall = await recall(conversation: survivor, history: [], current: message(.user, Self.question, 99, in: survivor), provider: .mlx)
        XCTAssertTrue(survivorRecall?.contains("Kestrel") == true, "the other conversation's memory must survive — got: \(survivorRecall ?? "nil")")
    }

    // MARK: - WIRING: the two call sites (source guards — both live in methods too large to drive)

    /// `ActiveStreamManager` → `streamMessage`: the clean query and the Redo boundary are passed,
    /// not left out. Cutting either compiles (both are plain values) and every test above passes.
    func testTheStreamManagerHandsOverTheCleanQueryAndTheRedoBoundary() throws {
        let call = try segment(of: "Devgentic/Core/Utils/ActiveStreamManager.swift",
                               from: "backendOrchestrationService.streamMessage(", to: "onTraceUpdate:")
        XCTAssertTrue(call.contains("retrievalQuery: Self.retrievalQuery(for: userMessage, modelQuery: userQuery)"),
                      "memory is searched with the decorated model query again (RAG-19)")
        XCTAssertTrue(call.contains("regenerating: existingMessage.map { RegenerationBoundary(messageID: $0.id, timestamp: $0.timestamp) }"),
                      "a Redo no longer tells retrieval which reply it is replacing (RAG-4)")
    }

    /// `streamMessage`'s Section 3 → the tested composition, with every input the send path owns.
    func testSectionThreeFeedsTheTestedComposition() throws {
        let path = "Devgentic/Core/Backends/BackendOrchestrationService.swift"
        let call = try segment(of: path, from: "ragContextString = await Self.conversationMemoryContext(", to: "traceID: context.traceID")
        for argument in ["lexicalQuery: retrievalQuery", "originalHistory: history", "shippedHistory: conversationHistory",
                         "currentTurnFiles: files", "regenerating: regenerating"] {
            XCTAssertTrue(call.contains(argument), "Section 3 no longer passes `\(argument)`")
        }
        let rewrite = try segment(of: path, from: "if isICEnabled && hasICModel && isRAGRewritingEnabled {", to: "ragContextString = await")
        XCTAssertTrue(rewrite.contains("rewriteQuery(retrievalQuery,"), "the rewrite is fed the decorated query (RAG-19)")
        XCTAssertTrue(rewrite.contains("queryForRAG = retrievalQuery"), "the un-rewritten path searches with the decorated query (RAG-19)")
    }

    /// Section 3b indexes attachments under the turn that carried them (RAG-14).
    func testAttachmentsAreIndexedUnderTheirCarryingMessage() throws {
        let call = try segment(of: "Devgentic/Core/Backends/BackendOrchestrationService.swift",
                               from: "await RAGIndexingService.shared.indexAttachedFiles(", to: "messageTimestamp:")
        XCTAssertTrue(call.contains("messageID: carrierID"), "attachments are indexed under a synthetic id again")
        XCTAssertTrue(call.contains("messageTimestamp: carrierTimestamp"), "attachments are dated to indexing time again")
    }

    /// The text from the first line containing `start` through the first later line containing
    /// `end`, comment lines dropped.
    private func segment(of path: String, from start: String, to end: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let source = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.contains(start) }) else {
            XCTFail("`\(start)` not found in \(path) — this guard is checking nothing"); return ""
        }
        guard let last = lines[first...].firstIndex(where: { $0.contains(end) }) else {
            XCTFail("`\(end)` not found after `\(start)` — this guard is checking nothing"); return ""
        }
        return lines[first...last]
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
