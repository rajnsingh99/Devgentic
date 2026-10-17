// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SendPathPerformanceTests.swift
//  devgenticTests
//
//  Batch 6 of the RAG readiness register, the
//  SwiftData send-path costs. Measured first (`SendPathHistoryBenchmarkTests`, `-O`):
//    RAG-7  — the request's 300-message history decode: 60 ms (Code, 15 tools/turn) to 125 ms
//             (40 tools/turn) on the MAIN actor, ~90% timeline JSON. Now decoded off-main.
//    RAG-6  — the context gauge paid that same resolve 3–4× per send and once per scroll-back
//             page, with every screenshot's bytes. Now: one resolve per burst, none on paging, no
//             image bytes, off-main.
//    RAG-26 — the background-task history scan on open: 18–28 ms per 300 messages, unbounded,
//             on main. Now off-main.
//    RAG-28 — every streaming flush rewrote `conversation.timestamp`, re-sorting the sidebar.
//             Now an insert moves it; an update moves it at most once a minute.
//

import XCTest
import SwiftData
@testable import devgentic

/// Records which history read each caller makes. Overrides `fetchContextHistory` — which only
/// reaches this type if it is a protocol REQUIREMENT (an extension-only method would be statically
/// dispatched to the default, and `contextCalls` would stay empty).
@MainActor
private final class HistoryReadSpy: ChatPersistenceProtocol {
    let conversationID: UUID
    private(set) var contextCalls: [Bool] = []
    private(set) var pagedFetches = 0
    private let backing: [ChatMessage]   // newest-first, like the store

    init(conversationID: UUID, count: Int = 120) {
        self.conversationID = conversationID
        backing = (0..<count).map { i in
            ChatMessage(conversationId: conversationID, timestamp: Date(timeIntervalSince1970: TimeInterval(1_000_000 - i)),
                        sender: i.isMultiple(of: 2) ? .agent : .user, content: .markdownText("Message \(i)"))
        }
    }

    func fetchMessages(for conversationId: UUID, offset: Int, limit: Int) async -> [ChatMessage] {
        pagedFetches += 1
        guard offset < backing.count else { return [] }
        return Array(backing[offset ..< min(offset + limit, backing.count)])
    }

    func fetchContextHistory(for conversationId: UUID, limit: Int, omittingImageBytes: Bool) async -> [ChatMessage] {
        contextCalls.append(omittingImageBytes)
        return Array(backing.prefix(limit))
    }

    func addConversation(from conversation: Conversation) {}
    func addMessage(_ message: ChatMessage, toConversation conversationId: UUID) async {}
    func addMessages(_ messages: [ChatMessage], toConversation conversationId: UUID) async {}
    func getConversation(withId id: UUID) -> ConversationSD? { nil }
    func deleteConversation(with id: UUID) {}
    func updateBackendForConversation(id: UUID, backendEntityId: UUID?) {}
    func updateProfileType(for conversationId: UUID, profileTypeRaw: String) {}
    func togglePinStatus(for conversationId: UUID) {}
}

/// Thread-safe sink for the store's DEBUG off-main observer.
private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ onMain: Bool) { lock.lock(); values.append(onMain); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
final class SendPathPerformanceTests: XCTestCase {

    private let conversationID = UUID()
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var container: ModelContainer?

    override func tearDown() async throws {
        ChatPersistenceStore.offMainReadObserver = nil
        container = nil
    }

    // MARK: - Which read each caller makes (wiring)

    /// RAG-7: the REQUEST resolves through the off-main requirement, WITH image bytes — it ships
    /// history images, so omitting them would silently drop screenshots from the prompt.
    func testTheRequestPathReadsContextHistoryWithImageBytes() async {
        let spy = HistoryReadSpy(conversationID: conversationID)
        let user = ChatMessage(conversationId: conversationID, timestamp: Date(timeIntervalSince1970: 2_000_000),
                               sender: .user, content: .markdownText("next question"))
        let history = await ActiveStreamManager.deriveHistory(userMessage: user, before: nil, persistence: spy)

        XCTAssertEqual(spy.contextCalls, [false], "the request must read via fetchContextHistory, keeping image bytes")
        XCTAssertEqual(spy.pagedFetches, 0, "the request fell back to the main-actor fetchMessages")
        XCTAssertFalse(history.isEmpty)
    }

    /// RAG-6: the GAUGE reads the same history WITHOUT image bytes — it only counts images.
    func testTheGaugeReadsContextHistoryWithoutImageBytes() async {
        let spy = HistoryReadSpy(conversationID: conversationID)
        let viewModel = ChatHistoryViewModel(
            persistenceService: spy,
            activeStreamManager: ActiveStreamManager(persistenceService: spy, fileProcessorService: FileProcessorService())
        )
        _ = await viewModel.resolveContextHistory(for: conversationID)
        XCTAssertEqual(spy.contextCalls, [true])
    }

    /// RAG-6: scroll-back paging changes the render window, never the request, so it must not
    /// move the gauge's trigger key. A real turn still does.
    func testScrollBackPagingDoesNotMoveTheGaugeKey() async {
        let spy = HistoryReadSpy(conversationID: conversationID)
        let viewModel = ChatHistoryViewModel(
            persistenceService: spy,
            activeStreamManager: ActiveStreamManager(persistenceService: spy, fileProcessorService: FileProcessorService())
        )
        await viewModel.loadConversation(id: conversationID)
        let opened = viewModel.contextGaugeTurnKey
        let residentBefore = viewModel.currentChatMessages.count

        for _ in 0..<3 { await viewModel.loadMoreMessages() }
        XCTAssertGreaterThan(viewModel.currentChatMessages.count, residentBefore, "sanity: pages were loaded")
        XCTAssertEqual(viewModel.contextGaugeTurnKey, opened, "a scroll-back page re-triggered the gauge's 300-message resolve")

        viewModel.currentChatMessages.insert(
            ChatMessage(conversationId: conversationID, sender: .user, content: .markdownText("new turn")), at: 0)
        XCTAssertEqual(viewModel.contextGaugeTurnKey, opened + 1, "a new turn must still move the key")

        await viewModel.loadConversation(id: conversationID)
        XCTAssertEqual(viewModel.contextGaugeTurnKey, viewModel.currentChatMessages.count, "a reload resets the paging tally")
    }

    /// RAG-6: both composers debounce BEFORE resolving and key on the paging-insensitive count.
    /// Source guard — the recompute lives in two large SwiftUI bodies.
    func testBothComposersSettleBeforeResolvingAndIgnorePaging() throws {
        for path in ["Devgentic/Interfaces/Shared/ChatInput/ChatInputAreaView.swift",
                     "Devgentic/Interfaces/QuickAccess/Views/QuickAccessContentView.swift"] {
            let source = try sourceText(path)
            let recompute = try XCTUnwrap(source.range(of: "private func recomputeContextGauge()"), path)
            let body = source[recompute.upperBound...]
            let settle = try XCTUnwrap(body.range(of: "try? await Task.sleep(for: ChatHistoryViewModel.contextGaugeSettle)"),
                                       "\(path): the recompute no longer waits out its trigger burst")
            let check = try XCTUnwrap(body.range(of: "guard !Task.isCancelled else { return }", range: settle.upperBound..<body.endIndex), path)
            let resolve = try XCTUnwrap(body.range(of: "resolveContextHistory(for: conversationID)"), path)
            XCTAssertLessThan(check.upperBound, resolve.lowerBound, "\(path): the cancellation check must come BEFORE the resolve")
            XCTAssertTrue(source.contains("contextGaugeTurnKey"), "\(path): the gauge trigger is keyed on the raw window count again")
            XCTAssertFalse(source.contains("currentChatMessages.count)|"), "\(path): paging re-triggers the gauge")
            XCTAssertFalse(source.contains("onChange(of: session.chatHistoryViewModel.currentChatMessages.count)"), path)
        }
    }

    // MARK: - The SwiftData store's off-main reads

    private func configureStore() throws -> ChatPersistenceStore {
        let c = try ModelContainer(for: ConversationSD.self, ChatMessageSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = c
        let store = ChatPersistenceStore.shared
        store.configureContainer(c)
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: epoch,
                                                 userDefinedTitle: "perf", isPinned: false, backendEntityId: nil))
        return store
    }

    private func seed(_ store: ChatPersistenceStore) async -> [ChatMessage] {
        let image = AttachedImageFile(name: "shot.png", url: URL(fileURLWithPath: "/tmp/shot.png"), fileExtension: "png",
                                      binaryData: Data(repeating: 0xCD, count: 2_048), size: 2_048)
        let user = ChatMessage(conversationId: conversationID, timestamp: epoch, sender: .user,
                               content: .markdownText("look at this"), attachedImageFiles: [image])
        let agent = ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(1), sender: .agent,
                                content: .markdownText("I read the file."))
        agent.timelineEvents = [.toolExecution(ToolExecutionData(id: UUID(), name: "fs_read_file", params: "{\"path\":\"a.swift\"}",
                                                                 output: "let a = 1", isSuccess: true, isExecuting: false, stepId: 0))]
        let task = BackgroundTaskData(id: UUID(), taskID: "bg_1", name: "Build", command: "xcodebuild", workingDirectory: "/tmp",
                                      startedAt: epoch, finishedAt: epoch, status: .running, exitCode: 0,
                                      logPath: "/tmp/bg_1.log", outputTail: "", logCharacterCount: 0)
        let runner = ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(2), sender: .agent,
                                 content: .markdownText("Started the build."))
        runner.timelineEvents = [.backgroundTask(task)]
        let messages = [user, agent, runner]
        await store.addMessages(messages, toConversation: conversationID)
        return messages
    }

    /// RAG-7: same rows, same order, same timelines and image bytes as `fetchMessages` — decoded
    /// on a background thread.
    func testContextHistoryMatchesTheMainActorFetchAndIsDecodedOffMain() async throws {
        let store = try configureStore()
        _ = await seed(store)
        let threads = ThreadLog()
        ChatPersistenceStore.offMainReadObserver = { threads.record($0) }

        let offMain = await store.fetchContextHistory(for: conversationID, limit: 300, omittingImageBytes: false)
        let onMain = await store.fetchMessages(for: conversationID, offset: 0, limit: 300)

        XCTAssertEqual(threads.all, [false], "the context-history decode ran on the main thread (or not through the reader)")
        XCTAssertEqual(offMain.map(\.id), onMain.map(\.id), "different rows or order (both newest-first)")
        XCTAssertEqual(offMain.map(\.timelineEvents), onMain.map(\.timelineEvents), "timelines differ — the request reads tool executions from them")
        XCTAssertEqual(offMain.last?.attachedImageFiles?.first?.binaryData.count, 2_048, "the request ships history images — bytes must be kept")
    }

    func testContextHistoryCanOmitImageBytesAndKeepTheImageEntry() async throws {
        let store = try configureStore()
        _ = await seed(store)
        let history = await store.fetchContextHistory(for: conversationID, limit: 300, omittingImageBytes: true)
        let image = try XCTUnwrap(history.last?.attachedImageFiles?.first, "the gauge counts image ENTRIES — keep them")
        XCTAssertEqual(image.name, "shot.png")
        XCTAssertTrue(image.binaryData.isEmpty)
    }

    /// Committed-rows semantics: a message written through the store is visible to the very next
    /// background read, because every chat write saves before it returns.
    func testAWriteIsVisibleToTheNextBackgroundRead() async throws {
        let store = try configureStore()
        _ = await seed(store)
        let late = ChatMessage(conversationId: conversationID, timestamp: epoch.addingTimeInterval(10), sender: .user,
                               content: .markdownText("just sent"))
        await store.addMessage(late, toConversation: conversationID)
        let history = await store.fetchContextHistory(for: conversationID, limit: 300, omittingImageBytes: false)
        XCTAssertEqual(history.first?.id, late.id)
    }

    /// RAG-26: the task-history scan still finds the rows, and no longer runs on main.
    func testBackgroundTaskScanFindsRowsOffMain() async throws {
        let store = try configureStore()
        _ = await seed(store)
        let threads = ThreadLog()
        ChatPersistenceStore.offMainReadObserver = { threads.record($0) }

        let rows = await store.fetchBackgroundTaskRows(for: conversationID)
        XCTAssertEqual(rows.map(\.taskID), ["bg_1"])
        XCTAssertEqual(threads.all, [false], "the task-history scan ran on the main thread")
    }

    // MARK: - RAG-28: conversation timestamp

    func testAFlushOfAnExistingRowDoesNotMoveTheConversationWithinTheResolution() async throws {
        let store = try configureStore()
        let seeded = await seed(store)
        let conversation = try XCTUnwrap(store.getConversation(withId: conversationID))

        let recent = Date().addingTimeInterval(-(ChatPersistenceStore.activityTimestampResolution / 2))
        conversation.timestamp = recent
        let agent = seeded[1]
        agent.content = .markdownText("I read the file, and more.")
        await store.addMessages([agent], toConversation: conversationID)
        XCTAssertEqual(conversation.timestamp, recent, "a streaming flush re-sorted the sidebar")

        let stale = Date().addingTimeInterval(-(ChatPersistenceStore.activityTimestampResolution * 2))
        conversation.timestamp = stale
        await store.addMessages([agent], toConversation: conversationID)
        XCTAssertGreaterThan(conversation.timestamp, stale.addingTimeInterval(ChatPersistenceStore.activityTimestampResolution),
                             "a long run's activity must still reach the timestamp")
    }

    func testANewMessageMovesTheConversationAtOnce() async throws {
        let store = try configureStore()
        _ = await seed(store)
        let conversation = try XCTUnwrap(store.getConversation(withId: conversationID))
        let recent = Date().addingTimeInterval(-5)
        conversation.timestamp = recent
        await store.addMessage(ChatMessage(conversationId: conversationID, sender: .user, content: .markdownText("again")),
                               toConversation: conversationID)
        XCTAssertGreaterThan(conversation.timestamp, recent, "a new turn must re-sort the sidebar immediately")
    }

    /// RAG-28: the sidebar builds its profile lookup only for legacy rows. Source guard — the
    /// partition is a private computed property of a view.
    func testTheSidebarFetchesProfilesOnlyOnDemand() throws {
        let source = try sourceText("Devgentic/Interfaces/Main/Views/Conversation/ConversationSidebarView.swift")
        let partition = try XCTUnwrap(source.range(of: "private var partitioned: PartitionedConversations {"))
        let loop = try XCTUnwrap(source.range(of: "for conversation in conversations {", range: partition.upperBound..<source.endIndex))
        let prelude = source[partition.upperBound..<loop.lowerBound]
        let lazy = try XCTUnwrap(prelude.range(of: "func profileType(for id: UUID) -> ProfileType? {"), "the lazy lookup is gone")
        let fetch = try XCTUnwrap(prelude.range(of: "fetchProfiles()"), "sanity")
        XCTAssertGreaterThan(fetch.lowerBound, lazy.upperBound, "profiles are fetched eagerly on every partition again")
        XCTAssertTrue(source[loop.upperBound...].contains("profileType(for: profileID)"))
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
