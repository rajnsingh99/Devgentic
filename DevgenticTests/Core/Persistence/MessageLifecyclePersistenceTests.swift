// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  MessageLifecyclePersistenceTests.swift
//  DevgenticTests
//
//  G1 Piece 1 — in-flight persistence. Validates that the lifecycle marker, the parked-HITL
//  operationID join key, the run-identity stamp (provider/model/dialect), and ToolExecutionData.stepId
//  survive the ChatMessage ⇄ ChatMessageSD ⇄ Codable round-trips, and that legacy rows / payloads
//  (written before these fields existed) decode safely to `.final` / nil.
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class MessageLifecyclePersistenceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: ConversationSD.self, ChatMessageSD.self,
            AttachedTextFileSD.self, AttachedImageFileSD.self,
            configurations: config
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - MessageLifecycleState enum semantics

    func testRawKindAndParkedOperationID() {
        let opID = UUID()
        XCTAssertEqual(MessageLifecycleState.final.rawKind, "final")
        XCTAssertEqual(MessageLifecycleState.streaming.rawKind, "streaming")
        XCTAssertEqual(MessageLifecycleState.parkedHITL(operationID: opID).rawKind, "parkedHITL")

        XCTAssertNil(MessageLifecycleState.final.parkedOperationID)
        XCTAssertNil(MessageLifecycleState.streaming.parkedOperationID)
        XCTAssertEqual(MessageLifecycleState.parkedHITL(operationID: opID).parkedOperationID, opID)
    }

    func testIsInterrupted() {
        XCTAssertFalse(MessageLifecycleState.final.isInterrupted)
        XCTAssertTrue(MessageLifecycleState.streaming.isInterrupted)
        XCTAssertTrue(MessageLifecycleState.parkedHITL(operationID: UUID()).isInterrupted)
    }

    func testRestoreFromPersistedPair() {
        let opID = UUID()
        // Happy paths
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: "streaming", parkedOperationID: nil), .streaming)
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: "parkedHITL", parkedOperationID: opID), .parkedHITL(operationID: opID))
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: "final", parkedOperationID: nil), .final)

        // Legacy row (no column) and unknown kind → .final
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: nil, parkedOperationID: nil), .final)
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: "wat", parkedOperationID: nil), .final)

        // Parked but the operationID was lost → degrade to .streaming (interrupted, not resumable)
        XCTAssertEqual(MessageLifecycleState.restore(rawKind: "parkedHITL", parkedOperationID: nil), .streaming)
    }

    // MARK: - ChatMessageSD round-trip (the persistence path)

    func testSDRoundTripPersistsParkedLifecycleAndRunIdentity() throws {
        let convID = UUID()
        let opID = UUID()
        let original = ChatMessage(
            conversationId: convID,
            sender: .agent,
            content: .markdownText("partial answer…"),
            backendEntityId: UUID()
        )
        original.lifecycleState = .parkedHITL(operationID: opID)
        original.apiProvider = "Anthropic"
        original.modelName = "claude-opus-4-8"
        original.modelDialect = "nativeJSON"

        let sd = ChatMessageSD.from(original)
        context.insert(sd)
        try context.save()

        // Fetch back through SwiftData to prove the new columns actually persist.
        let fetched = try context.fetch(FetchDescriptor<ChatMessageSD>()).first
        let decoded = try XCTUnwrap(fetched).toChatMessage()

        XCTAssertEqual(decoded.lifecycleState, .parkedHITL(operationID: opID))
        XCTAssertEqual(decoded.lifecycleState.parkedOperationID, opID, "The HITL join key must survive persistence.")
        XCTAssertEqual(decoded.apiProvider, "Anthropic")
        XCTAssertEqual(decoded.modelName, "claude-opus-4-8")
        XCTAssertEqual(decoded.modelDialect, "nativeJSON")
    }

    func testSDRoundTripStreamingLifecycle() {
        let original = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("…"), backendEntityId: UUID())
        original.lifecycleState = .streaming

        let decoded = ChatMessageSD.from(original).toChatMessage()
        XCTAssertEqual(decoded.lifecycleState, .streaming)
        XCTAssertNil(decoded.lifecycleState.parkedOperationID)
    }

    func testSDDefaultMessageIsFinal() {
        // A normal message (lifecycleState defaults to .final) round-trips as .final.
        let original = ChatMessage(conversationId: UUID(), sender: .user, content: .plainText("hi"))
        let decoded = ChatMessageSD.from(original).toChatMessage()
        XCTAssertEqual(decoded.lifecycleState, .final)
        XCTAssertFalse(decoded.lifecycleState.isInterrupted)
    }

    func testLegacySDRowDecodesAsFinal() throws {
        // Simulate a row written before these columns existed: construct the SD entity via its
        // init WITHOUT the new args, so lifecycleStateRaw / parkedOperationID / run-identity are nil.
        let contentData = try JSONEncoder().encode(MessageContent.markdownText("legacy"))
        let sd = ChatMessageSD(
            id: UUID(),
            conversationId: UUID(),
            timestamp: Date(),
            senderType: SenderRole.agent.rawValue,
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: nil
        )

        let decoded = sd.toChatMessage()
        XCTAssertEqual(decoded.lifecycleState, .final, "Legacy rows (no lifecycle column) must read as finished, not interrupted.")
        XCTAssertNil(decoded.apiProvider)
        XCTAssertNil(decoded.modelName)
        XCTAssertNil(decoded.modelDialect)
    }

    // MARK: - ToolExecutionData.stepId

    func testToolExecutionDataStepIdRoundTrip() throws {
        let original = ToolExecutionData(id: UUID(), name: "write_file", params: "{\"path\":\"/tmp/x\"}", output: "ok", isSuccess: true, isExecuting: false, stepId: 4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: data)
        XCTAssertEqual(decoded.stepId, 4)
        XCTAssertEqual(decoded, original)
    }

    func testLegacyToolExecutionDataHasNilStepId() throws {
        // A timeline event persisted before `stepId` existed (key absent) must decode to nil, not throw.
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"read_file","params":"{}","output":"contents","isSuccess":true,"isExecuting":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: legacyJSON)
        XCTAssertNil(decoded.stepId)
        XCTAssertEqual(decoded.name, "read_file")
    }

    // MARK: - ChatMessage Codable (whole-message)

    func testChatMessageCodableRoundTripWithLifecycleAndStepId() throws {
        let opID = UUID()
        let original = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("answer"), backendEntityId: UUID())
        original.lifecycleState = .parkedHITL(operationID: opID)
        original.apiProvider = "OpenAI"
        original.modelName = "gpt-x"
        original.modelDialect = "nativeJSON"
        original.timelineEvents = [
            .toolExecution(ToolExecutionData(id: UUID(), name: "list_directory", params: "{}", output: "a,b", isSuccess: true, isExecuting: false, stepId: 2))
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.lifecycleState, .parkedHITL(operationID: opID))
        XCTAssertEqual(decoded.apiProvider, "OpenAI")
        XCTAssertEqual(decoded.modelName, "gpt-x")
        XCTAssertEqual(decoded.modelDialect, "nativeJSON")
        if case .toolExecution(let tool) = decoded.timelineEvents.first {
            XCTAssertEqual(tool.stepId, 2)
        } else {
            XCTFail("Expected a toolExecution timeline event to survive encoding")
        }
    }

    func testChatMessageCodableLegacyPayloadDecodesAsFinal() throws {
        // Encode a current message, then strip the new keys to emulate a payload from an older build.
        let original = ChatMessage(conversationId: UUID(), sender: .agent, content: .markdownText("legacy"), backendEntityId: UUID())
        original.lifecycleState = .streaming
        original.apiProvider = "Anthropic"

        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "lifecycleState")
        object.removeValue(forKey: "apiProvider")
        object.removeValue(forKey: "modelName")
        object.removeValue(forKey: "modelDialect")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ChatMessage.self, from: stripped)
        XCTAssertEqual(decoded.lifecycleState, .final, "Absent lifecycle key must default to .final.")
        XCTAssertNil(decoded.apiProvider)
    }
}
