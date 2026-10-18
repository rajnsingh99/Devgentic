// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PersistenceBatch6Tests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class PersistenceBatch6Tests: XCTestCase {

    private func onDiskURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("b6-\(tag)-\(UUID().uuidString).store")
    }

    private func layout(notes: Int) -> WorkflowLayout {
        WorkflowLayout(nodes: [], edges: [], annotations: (0..<notes).map {
            StickyNote(position: CGPoint(x: Double($0), y: 0), text: "note \($0)")
        })
    }

    // MARK: - Characterisation: what a main context sees after a throwaway context commits

    func testProbe_MainContextSeesAThrowawayContextsDeleteOfARowItAlreadyLoaded() throws {
        let url = onDiskURL("probe-del")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]), configurations: ModelConfiguration(url: url))
        let id = UUID()
        container.mainContext.insert(WorkflowLayoutSD(workflowProfileID: id, layout: layout(notes: 1)))
        try container.mainContext.save()
        let loaded = try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>())
        XCTAssertEqual(loaded.count, 1)

        let scratch = ModelContext(container)
        let row = try XCTUnwrap(try scratch.fetch(FetchDescriptor<WorkflowLayoutSD>(predicate: #Predicate { $0.workflowProfileID == id })).first)
        scratch.delete(row)
        try scratch.save()

        let after = try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>())
        print("PROBE delete: main sees \(after.count) row(s) after scratch delete")
        XCTAssertEqual(after.count, 0, "PROBE")
    }

    func testProbe_MainContextSeesAThrowawayContextsUpdateOfARowItAlreadyLoaded() throws {
        let url = onDiskURL("probe-upd")
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]), configurations: ModelConfiguration(url: url))
        let id = UUID()
        container.mainContext.insert(WorkflowLayoutSD(workflowProfileID: id, layout: layout(notes: 1)))
        try container.mainContext.save()
        let loaded = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        XCTAssertEqual(loaded.layout.annotations.count, 1)

        let scratch = ModelContext(container)
        let row = try XCTUnwrap(try scratch.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        row.layout = layout(notes: 4)
        try scratch.save()

        let after = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<WorkflowLayoutSD>()).first)
        print("PROBE update: main sees nodeCount-annotations=\(after.annotationCount) layout=\(after.layout.annotations.count) same-instance=\(after === loaded)")
        XCTAssertEqual(after.annotationCount, 4, "PROBE")
    }

    // MARK: - CR-62: no rollback of the shared context

    private static let garbage = Data("{{{ not a layout".utf8)

    /// Seeds an on-disk store with an UNREADABLE layout for `unreadable` (it once held 3 notes)
    /// and a readable 1-note layout for each id in `readable`.
    private func seedLayouts(at url: URL, unreadable: UUID?, readable: [UUID]) throws {
        let seeding = try ModelContainer(for: Schema([WorkflowLayoutSD.self]), configurations: ModelConfiguration(url: url))
        let context = ModelContext(seeding)
        if let unreadable {
            let row = WorkflowLayoutSD(workflowProfileID: unreadable, layout: layout(notes: 3))
            context.insert(row)
            row.layoutData = Self.garbage
        }
        for id in readable { context.insert(WorkflowLayoutSD(workflowProfileID: id, layout: layout(notes: 1))) }
        try context.save()
    }

    private func readOnlyContainer(_ url: URL) throws -> ModelContainer {
        try ModelContainer(for: Schema([WorkflowLayoutSD.self]),
                           configurations: ModelConfiguration(url: url, allowsSave: false))
    }

    private func row(_ id: UUID, in context: ModelContext) throws -> WorkflowLayoutSD? {
        try context.fetch(FetchDescriptor<WorkflowLayoutSD>(predicate: #Predicate { $0.workflowProfileID == id })).first
    }

    /// A FAILED repair must leave the canvas exactly as unreadable as it was, and must not touch
    /// another subsystem's pending change. `rollback()` did neither: SwiftData does not restore a
    /// changed value after a failed save (`SharedContextCommitTests`), so the "failed" repair stayed
    /// in memory, read as a healthy canvas, and could be committed by the next unrelated save.
    func testCR62_FailedRepairPutsBackOnlyItsOwnRow() throws {
        let url = onDiskURL("repair-fail")
        defer { try? FileManager.default.removeItem(at: url) }
        let broken = UUID(), other = UUID()
        try seedLayouts(at: url, unreadable: broken, readable: [other])
        let container = try readOnlyContainer(url)
        WorkflowLayoutStore.shared.configureContainer(container)

        // Another subsystem's edit, pending on the shared context.
        try XCTUnwrap(try row(other, in: container.mainContext)).layout = layout(notes: 2)

        let outcome = WorkflowLayoutStore.shared.repairUnreadableLayout(layout(notes: 9), for: broken, reason: "test")

        guard case .failed = outcome else { return XCTFail("precondition: a read-only store fails the save, got \(outcome)") }
        XCTAssertTrue(WorkflowLayoutStore.shared.isLayoutUnreadable(for: broken),
                      "a failed repair must leave the canvas reported unreadable (and saves refused)")
        XCTAssertEqual(try row(broken, in: container.mainContext)?.layoutData, Self.garbage,
                       "the stored bytes must be back in the row, not the failed repair's")
        XCTAssertEqual(try row(other, in: container.mainContext)?.layout.annotations.count, 2,
                       "another subsystem's pending change must survive a failed repair")
    }

    /// A FAILED delete must leave nothing pending on the shared context, or the next unrelated save
    /// deletes the layout after the store reported failure.
    func testCR62_FailedDeleteLeavesNothingPendingOnTheSharedContext() throws {
        let url = onDiskURL("delete-fail")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        try seedLayouts(at: url, unreadable: nil, readable: [id])
        let container = try readOnlyContainer(url)
        WorkflowLayoutStore.shared.configureContainer(container)
        _ = WorkflowLayoutStore.shared.load(for: id)   // the canvas has it loaded, as in the app

        WorkflowLayoutStore.shared.delete(for: id)

        XCTAssertTrue(container.mainContext.deletedModelsArray.isEmpty,
                      "no delete may be left pending on the shared context")
        XCTAssertNotNil(try row(id, in: container.mainContext), "the row is still there")
    }

    /// The success paths still reach the canvas: a repair is what `load` returns next (the main
    /// context's decoded cache included), and a delete is gone from the main context.
    func testCR62_SuccessfulRepairAndDeleteAreVisibleToTheSharedContext() throws {
        let url = onDiskURL("ok")
        defer { try? FileManager.default.removeItem(at: url) }
        let id = UUID()
        try seedLayouts(at: url, unreadable: id, readable: [])
        let container = try ModelContainer(for: Schema([WorkflowLayoutSD.self]), configurations: ModelConfiguration(url: url))
        WorkflowLayoutStore.shared.configureContainer(container)
        XCTAssertTrue(WorkflowLayoutStore.shared.isLayoutUnreadable(for: id))

        XCTAssertEqual(WorkflowLayoutStore.shared.repairUnreadableLayout(layout(notes: 4), for: id, reason: "test").didPersist, true)
        XCTAssertEqual(WorkflowLayoutStore.shared.load(for: id).annotations.count, 4)
        XCTAssertFalse(WorkflowLayoutStore.shared.isLayoutUnreadable(for: id))

        WorkflowLayoutStore.shared.delete(for: id)
        XCTAssertNil(try row(id, in: container.mainContext), "the delete must be visible to the shared context")
    }

    // MARK: - CR-63: an unreadable token-usage blob is not erased

    private func chatContainer() throws -> ModelContainer {
        try ModelContainer(for: ConversationSD.self, ChatMessageSD.self, AttachedTextFileSD.self, AttachedImageFileSD.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// Load a message whose usage blob cannot be decoded, write it straight back (what the history
    /// reconcile write-back, a resume or an in-flight flush does): the stored bytes must survive.
    func testCR63_ReWritingAMessageWithAnUnreadableUsageBlobKeepsTheBytes() async throws {
        let container = try chatContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)
        let conversationID = UUID()
        store.addConversation(from: Conversation(id: conversationID, messages: [], timestamp: Date(), backendEntityId: nil))
        let original = ChatMessage(id: UUID(), conversationId: conversationID, timestamp: Date(), sender: .agent, content: .plainText("answer"))
        original.tokenUsage = TokenUsage(inputTokens: 10, outputTokens: 5, isEstimated: false)
        await store.addMessage(original, toConversation: conversationID)

        let unreadable = Data("{\"inputTokens\": \"lots\"".utf8)
        let stored = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<ChatMessageSD>()).first)
        stored.tokenUsageData = unreadable
        try container.mainContext.save()

        let loaded = await store.fetchMessages(for: conversationID, offset: 0, limit: 10)
        let message = try XCTUnwrap(loaded.first)
        XCTAssertNil(message.tokenUsage, "precondition: the blob does not decode")
        XCTAssertTrue(message.tokenUsageDecodeFailed)
        XCTAssertFalse(message.canPersistTokenUsage)

        await store.addMessages([message], toConversation: conversationID)

        let after = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<ChatMessageSD>()).first)
        XCTAssertEqual(after.tokenUsageData, unreadable, "the stored usage must not be nulled by the failed read's nil")
    }

    /// A message that later gets REAL usage still writes it: the guard protects the placeholder only.
    func testCR63_RealUsageReplacesAnUnreadableBlob() {
        let message = ChatMessage(id: UUID(), conversationId: UUID(), timestamp: Date(), sender: .agent, content: .plainText("x"))
        message.tokenUsageDecodeFailed = true
        XCTAssertFalse(message.canPersistTokenUsage)
        message.tokenUsage = TokenUsage(inputTokens: 1, outputTokens: 1, isEstimated: false)
        XCTAssertTrue(message.canPersistTokenUsage)
    }

    // MARK: - CR-64: "Save unverified" keeps unreadable tool schemas

    private func mcpItem(toolBlob: Data, in container: ModelContainer) throws -> MCPToolItem {
        let item = MCPToolItem(id: UUID(), serverName: "Acme",
                               mcpConfigData: try JSONEncoder().encode(ServerDefinition(command: "npx", args: ["acme"], envKeys: nil)))
        item.tools = [MCPToolDefinitionModel(name: "search", toolDescription: "Search", parametersData: toolBlob,
                                             iconsData: Data("not json".utf8))]
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    /// The reported path: the loaded (placeholder) tools are handed straight back to `updateTool`,
    /// which used to re-encode the empty schema over the stored one.
    func testCR64_SaveUnverifiedHandsBackPlaceholders_AndTheStoredBlobsSurvive() throws {
        let container = try ModelContainer(for: MCPToolItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MCPToolStore.shared.configureContainer(container)
        let unreadable = Data("not json at all".utf8)
        let item = try mcpItem(toolBlob: unreadable, in: container)

        let loadedTools = item.toToolSource().tools
        XCTAssertEqual(loadedTools.first?.parameters, MCPToolDefinitionModel.placeholderParameters, "precondition: it loads as the placeholder")

        MCPToolStore.shared.updateTool(id: item.id, serverName: "Acme renamed",
                                       serverDefinition: ServerDefinition(command: "npx", args: ["acme", "--v2"], envKeys: nil),
                                       secrets: MCPRuntimeSecrets(), newTools: loadedTools)

        let saved = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<MCPToolItem>()).first?.tools.first)
        XCTAssertEqual(saved.parametersData, unreadable, "the stored schema must not be replaced by the empty placeholder")
        XCTAssertEqual(saved.iconsData, Data("not json".utf8), "nor the icons by nil")
    }

    /// A REAL incoming schema still wins: the guard protects only the placeholder.
    func testCR64_ARealSchemaReplacesAnUnreadableOne() throws {
        let container = try ModelContainer(for: MCPToolItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        MCPToolStore.shared.configureContainer(container)
        let item = try mcpItem(toolBlob: Data("not json at all".utf8), in: container)
        let real = ToolParameters(type: "object", properties: [:], required: ["query"])

        MCPToolStore.shared.updateTool(id: item.id, serverName: "Acme",
                                       serverDefinition: ServerDefinition(command: "npx", args: ["acme"], envKeys: nil),
                                       secrets: MCPRuntimeSecrets(),
                                       newTools: [ToolDefinition(name: "search", description: "Search", category: "Acme", parameters: real)])

        let saved = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<MCPToolItem>()).first?.tools.first)
        XCTAssertEqual(saved.parametersData.flatMap { try? JSONDecoder().decode(ToolParameters.self, from: $0) }, real)
    }

    // MARK: - CR-65: media lives exactly as long as its conversation

    private func mediaStore() -> (MediaStore, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("b6-media-\(UUID().uuidString)", isDirectory: true)
        return (MediaStore(baseDirectory: base), base)
    }

    func testCR65_EvictRemovesOnlyThatConversationsMedia() async throws {
        let (media, base) = mediaStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let gone = UUID(), kept = UUID()
        _ = try await media.store(data: Data([1, 2, 3]), mimeType: "image/png", conversationID: gone)
        guard case .diskPath(let keptFile) = try await media.store(data: Data([4]), mimeType: "image/png", conversationID: kept) else {
            return XCTFail("expected a disk path")
        }

        let removed = await media.evict(conversationID: gone)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(gone.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))
    }

    func testCR65_OrphanSweepRemovesDeadConversationsOnly_AndRefusesAnEmptyList() async throws {
        let (media, base) = mediaStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let dead = UUID(), live = UUID()
        _ = try await media.store(data: Data([1]), mimeType: "image/png", conversationID: dead)
        _ = try await media.store(data: Data([2]), mimeType: "image/png", conversationID: live)
        let foreign = base.appendingPathComponent("not-a-conversation", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)

        let refused = await media.removeOrphanedConversations(liveConversationIDs: [])
        XCTAssertEqual(refused, 0, "an empty listing must never read as 'delete every conversation's images'")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent(dead.uuidString).path))

        let removed = await media.removeOrphanedConversations(liveConversationIDs: [live])

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(dead.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent(live.uuidString).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "a folder not named by a conversation id is left alone")
    }

    /// The wiring: deleting a conversation through the real store evicts its media.
    func testCR65_DeletingAConversationEvictsItsMedia() async throws {
        let container = try chatContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)
        let id = UUID()
        store.addConversation(from: Conversation(id: id, messages: [], timestamp: Date(), backendEntityId: nil))
        guard case .diskPath(let file) = try await MediaStore.shared.store(data: Data([9]), mimeType: "image/png", conversationID: id) else {
            return XCTFail("expected a disk path")
        }

        store.deleteConversation(with: id)

        for _ in 0..<200 where FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the deleted conversation's image must be evicted")
    }

    /// The test host must never point the shared store at the user's real media folder: the launch
    /// sweep compares it against the TEST database and would delete every real image.
    func testCR65_SharedStoreIsRedirectedUnderTheTestHost() async {
        let base = await MediaStore.shared.baseDirectory.path
        XCTAssertFalse(base.contains("Application Support"), "got \(base)")
    }

    // MARK: - CR-68: emptiness without faulting the relationship

    func testCR68_RowsReportEmptinessFromTheIndexedCount() async throws {
        let container = try chatContainer()
        let store = ChatPersistenceStore.shared
        store.configureContainer(container)
        let empty = UUID(), full = UUID()
        store.addConversation(from: Conversation(id: empty, messages: [], timestamp: Date(), backendEntityId: nil))
        store.addConversation(from: Conversation(id: full, messages: [], timestamp: Date().addingTimeInterval(1), backendEntityId: nil))
        await store.addMessage(ChatMessage(id: UUID(), conversationId: full, timestamp: Date(), sender: .user, content: .plainText("hi")), toConversation: full)

        let rows = try store.conversationRows(limit: 10, offset: 0)
        XCTAssertEqual(rows.first { $0.id == empty }?.isEmpty, true)
        XCTAssertEqual(rows.first { $0.id == full }?.isEmpty, false)
        XCTAssertEqual(try store.conversationRow(id: full)?.isEmpty, false)
        XCTAssertEqual(try store.reusableEmptyConversationID(preferring: full), empty, "/new must not reuse a conversation with messages")
        XCTAssertEqual(store.recentConversations(limit: 5).map(\.id), [full], "recents lists non-empty conversations only")
    }

    // The CR-68 MEASUREMENT (200 conversations × 50 messages: 15.5 ms relationship fault vs 5.3 ms
    // indexed count, 2026-10-12) was a one-off and is recorded in the readiness doc. It was removed
    // from the suite on 2026-10-13: adding 10,000 messages through the real store schedules 10,000
    // delayed RAG indexing jobs, which flooded the shared test vector store and broke
    // `RAGRetrievalScopeTests` (its count deltas) and slowed it from <1 s to 218 s.

}
