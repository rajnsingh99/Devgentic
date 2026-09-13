// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatMessageObservableTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Tests ChatMessage's @Observable migration — verifies property changes
//  are tracked correctly, Codable conformance survives the macro,
//  Equatable still works, and transient state behaves as expected.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatMessageObservableTests: XCTestCase {

    // MARK: - Helpers

    private func makeUserMessage(text: String = "Hello") -> ChatMessage {
        ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText(text)
        )
    }

    private func makeAgentMessage(text: String = "Response") -> ChatMessage {
        ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(text),
            backendEntityId: UUID()
        )
    }

    // MARK: - Basic Construction

    func testUserMessageConstruction() {
        let msg = makeUserMessage(text: "Test")
        XCTAssertEqual(msg.sender, .user)
        XCTAssertEqual(msg.content, .plainText("Test"))
        XCTAssertFalse(msg.isStreaming)
        XCTAssertNil(msg.agentResponse)
    }

    func testAgentMessageConstructionCreatesAgentResponse() {
        let msg = makeAgentMessage(text: "Hi")
        XCTAssertEqual(msg.sender, .agent)
        XCTAssertNotNil(msg.agentResponse)
        XCTAssertEqual(msg.agentResponse?.variants.count, 1)
        XCTAssertEqual(msg.agentResponse?.selectedVariantIndex, 0)
        XCTAssertEqual(msg.currentAgentContent?.textContent, "Hi")
    }

    // MARK: - Property Mutation

    func testContentMutation() {
        let msg = makeUserMessage(text: "Original")
        msg.content = .markdownText("Updated")
        XCTAssertEqual(msg.content.textContent, "Updated")
    }

    func testStreamingStateMutation() {
        let msg = makeAgentMessage()
        XCTAssertFalse(msg.isStreaming)
        msg.isStreaming = true
        XCTAssertTrue(msg.isStreaming)
    }

    func testAgentStateMutation() {
        let msg = makeAgentMessage()
        XCTAssertEqual(msg.agentState, .idle)

        msg.agentState = .thinking(.reasoning)
        XCTAssertEqual(msg.agentState, .thinking(.reasoning))

        msg.agentState = .acting(.tool(name: "bash"))
        XCTAssertEqual(msg.agentState, .acting(.tool(name: "bash")))
    }

    // `testThinkingHeadlineMutation` removed 2026-07-17 with `ChatMessage.thinkingHeadline`
    // — the field existed only to feed ThinkingDynamicIsland, which no longer exists.

    // MARK: - Timeline Events

    func testAppendTimelineEvent() {
        let msg = makeAgentMessage()
        XCTAssertTrue(msg.timelineEvents.isEmpty)

        let thoughtId = UUID()
        msg.appendTimelineEvent(.thought(id: thoughtId, text: "Hmm..."))
        XCTAssertEqual(msg.timelineEvents.count, 1)

        let toolId = UUID()
        msg.appendTimelineEvent(.toolExecution(
            ToolExecutionData(id: toolId, name: "bash", params: "{}", output: "ok", isSuccess: true, isExecuting: false)
        ))
        XCTAssertEqual(msg.timelineEvents.count, 2)
    }

    // MARK: - ToolExecutionData Struct

    func testToolExecutionDataMutation() {
        var data = ToolExecutionData(id: UUID(), name: "bash", params: "{\"cmd\":\"ls\"}", output: nil, isSuccess: nil, isExecuting: true)
        XCTAssertTrue(data.isExecuting)
        XCTAssertNil(data.output)

        data.output = "file.txt"
        data.isSuccess = true
        data.isExecuting = false

        XCTAssertFalse(data.isExecuting)
        XCTAssertEqual(data.output, "file.txt")
        XCTAssertEqual(data.isSuccess, true)
    }

    func testToolExecutionDataInTimelineUpdate() {
        let msg = makeAgentMessage()
        let toolId = UUID()
        msg.timelineEvents = [
            .toolExecution(ToolExecutionData(id: toolId, name: "bash", params: "{}", output: nil, isSuccess: nil, isExecuting: true))
        ]

        // Simulate ActiveStreamManager tool output update pattern
        if case .toolExecution(var data) = msg.timelineEvents[0] {
            data.output = "result"
            data.isSuccess = true
            data.isExecuting = false
            msg.timelineEvents[0] = .toolExecution(data)
        }

        if case .toolExecution(let data) = msg.timelineEvents[0] {
            XCTAssertEqual(data.id, toolId, "ID should be preserved after update")
            XCTAssertEqual(data.name, "bash", "Name should be preserved after update")
            XCTAssertEqual(data.output, "result")
            XCTAssertEqual(data.isSuccess, true)
            XCTAssertFalse(data.isExecuting)
        } else {
            XCTFail("Expected toolExecution event")
        }
    }

    func testToolExecutionDataCodableRoundTrip() throws {
        let original = ToolExecutionData(id: UUID(), name: "read_file", params: "{\"path\":\"/tmp/x\"}", output: "file contents", isSuccess: true, isExecuting: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ToolExecutionData.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testToolExecutionDataEquatable() {
        let id = UUID()
        let a = ToolExecutionData(id: id, name: "bash", params: "{}", output: nil, isSuccess: nil, isExecuting: true)
        let b = ToolExecutionData(id: id, name: "bash", params: "{}", output: nil, isSuccess: nil, isExecuting: true)
        XCTAssertEqual(a, b)

        var c = a
        c.output = "done"
        XCTAssertNotEqual(a, c)
    }

    func testThoughtsComputedProperty() {
        let msg = makeAgentMessage()
        let id1 = UUID()
        let id2 = UUID()
        msg.timelineEvents = [
            .thought(id: id1, text: "First thought"),
            .toolExecution(ToolExecutionData(id: UUID(), name: "bash", params: "{}", output: nil, isSuccess: nil, isExecuting: true)),
            .thought(id: id2, text: "Second thought")
        ]

        XCTAssertEqual(msg.thoughts.count, 2)
        XCTAssertEqual(msg.thoughts[0].text, "First thought")
        XCTAssertEqual(msg.thoughts[1].text, "Second thought")
    }

    // `ChatMessage.artifacts` (a computed view of completed .toolExecution events) was
    // removed 2026-07-17 with the dynamic island: `ToolArtifactsRow` was its only consumer
    // and was gated on the island variant, so nothing read it once the island went. The
    // timeline surfaces the same tool executions as its own action rows.

    // [HITL/P6] The `ChatMessage.pendingInteraction` property + its deprecated shims were removed in the
    // P6 cutover; pending HITL now lives solely in `InteractionCenter`. The tests for that removed API
    // were deleted here.

    // MARK: - AgentResponse Variant Management

    func testVariantSelection() {
        let msg = makeAgentMessage(text: "First variant")

        let secondVariant = ResponseMessageVariant(
            content: .markdownText("Second variant"),
            backendEntityId: UUID()
        )
        msg.agentResponse?.variants.append(secondVariant)
        msg.agentResponse?.selectedVariantIndex = 1

        XCTAssertEqual(msg.currentAgentContent?.textContent, "Second variant")
    }

    func testGenerationAttemptsIncrement() {
        let msg = makeAgentMessage()
        XCTAssertEqual(msg.agentResponse?.generationAttempts, 1)

        msg.agentResponse?.generationAttempts += 1
        XCTAssertEqual(msg.agentResponse?.generationAttempts, 2)
    }

    // MARK: - Codable Conformance

    func testEncodeDecodeRoundTrip() throws {
        let original = makeAgentMessage(text: "Codable test")
        original.traceID = "trace-xyz"
        original.timelineEvents = [
            .thought(id: UUID(), text: "A thought"),
            .toolExecution(ToolExecutionData(id: UUID(), name: "search", params: "{}", output: "found", isSuccess: true, isExecuting: false))
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.conversationId, original.conversationId)
        XCTAssertEqual(decoded.sender, original.sender)
        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.traceID, "trace-xyz")
        XCTAssertEqual(decoded.timelineEvents.count, 2)
    }

    func testDecodedTransientPropertiesReset() throws {
        let original = makeAgentMessage()
        original.agentState = .thinking(.planning)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.agentState, .idle)
    }

    // MARK: - Schema Versioning

    func testEncodeIncludesSchemaVersion() throws {
        // [P5] Was a documented known-failure for months: asserted 2 while the impl
        // moved to 4. The constant tags the full-object JSON envelope ONLY (no
        // production path round-trips it; the store persists version-less per-field
        // blobs) — see the scope note at `currentSchemaVersion`.
        let msg = makeUserMessage(text: "envelope test")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["schemaVersion"] as? Int, 4)
    }

    func testV2EncodeDoesNotIncludeLegacyKeys() throws {
        let msg = makeAgentMessage(text: "Clean encode")
        msg.timelineEvents = [.thought(id: UUID(), text: "Think")]
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["thoughts"], "v2 should not encode legacy 'thoughts' key")
        XCTAssertNil(json["artifacts"], "v2 should not encode legacy 'artifacts' key")
        XCTAssertNil(json["agentState"], "v2 should not encode transient 'agentState' key")
    }

    func testV2DecodeReadsTimelineEvents() throws {
        let original = makeAgentMessage(text: "v2")
        let thoughtId = UUID()
        original.timelineEvents = [
            .thought(id: thoughtId, text: "Reasoning step"),
            .toolExecution(ToolExecutionData(id: UUID(), name: "bash", params: "{}", output: "ok", isSuccess: true, isExecuting: false))
        ]

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.timelineEvents.count, 2)
        if case .thought(let id, let text) = decoded.timelineEvents[0] {
            XCTAssertEqual(id, thoughtId)
            XCTAssertEqual(text, "Reasoning step")
        } else {
            XCTFail("Expected thought event")
        }
    }

    func testLegacyV1KeysAreIgnoredAfterMigrationRemoval() throws {
        // [P5] The v1 thoughts/artifacts migration was DELETED 2026-07-19: it was
        // unreachable in production (repo-verified — no durable v1 envelope exists
        // anywhere; the store persists per-field blobs, and every ephemeral encode
        // stamps the current version). This pins the new contract: legacy keys are
        // ignored, the message still decodes cleanly.
        let v1JSON: [String: Any] = [
            "id": UUID().uuidString,
            "conversationId": UUID().uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "sender": "user",
            "content": ["type": "plainText", "text": "Hello"],
            "isStreaming": false,
            "thoughts": [
                ["id": UUID().uuidString, "text": "Legacy — ignored"]
            ],
            "artifacts": [
                ["id": UUID().uuidString, "toolName": "bash", "output": "done", "isSuccess": true]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: v1JSON)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertTrue(decoded.timelineEvents.isEmpty, "Legacy keys no longer reconstruct events")
        XCTAssertEqual(decoded.content.textContent, "Hello", "The message itself still decodes")
    }

    func testV1WithTimelineEventsAlreadyPresent() throws {
        // v1 JSON that already has timelineEvents — migration should use them, not legacy fields
        let thoughtId = UUID()
        let v1JSON: [String: Any] = [
            "id": UUID().uuidString,
            "conversationId": UUID().uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "sender": "user",
            "content": ["type": "plainText", "text": "Hello"],
            "isStreaming": false,
            "timelineEvents": [
                ["thought": ["id": thoughtId.uuidString, "text": "From timeline"]]
            ],
            "thoughts": [
                ["id": UUID().uuidString, "text": "Should be ignored"]
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: v1JSON)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.timelineEvents.count, 1)
        if case .thought(_, let text) = decoded.timelineEvents[0] {
            XCTAssertEqual(text, "From timeline", "Should use timelineEvents, not legacy thoughts")
        } else {
            XCTFail("Expected thought from timelineEvents, not legacy")
        }
    }

    func testV1EmptyLegacyDataProducesEmptyTimeline() throws {
        let v1JSON: [String: Any] = [
            "id": UUID().uuidString,
            "conversationId": UUID().uuidString,
            "timestamp": Date().timeIntervalSinceReferenceDate,
            "sender": "user",
            "content": ["type": "plainText", "text": "Empty"],
            "isStreaming": false
        ]

        let data = try JSONSerialization.data(withJSONObject: v1JSON)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertTrue(decoded.timelineEvents.isEmpty)
    }

    func testReencodePreservesSchemaVersion() throws {
        let msg = makeUserMessage(text: "Round trip")
        let data1 = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data1)
        let data2 = try JSONEncoder().encode(decoded)
        let json = try JSONSerialization.jsonObject(with: data2) as! [String: Any]

        XCTAssertEqual(json["schemaVersion"] as? Int, 4, "Re-encode stamps the current envelope version")
    }

    // MARK: - Equatable

    func testEqualityBySameId() {
        let id = UUID()
        let convId = UUID()
        let msg1 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))
        let msg2 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))
        XCTAssertEqual(msg1, msg2)
    }

    func testInequalityByDifferentContent() {
        let id = UUID()
        let convId = UUID()
        let msg1 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))
        let msg2 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("B"))
        XCTAssertNotEqual(msg1, msg2)
    }

    func testInequalityByStreamingState() {
        let id = UUID()
        let convId = UUID()
        let msg1 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"))
        let msg2 = ChatMessage(id: id, conversationId: convId, sender: .user, content: .plainText("A"), isStreaming: true)
        XCTAssertNotEqual(msg1, msg2)
    }

    // MARK: - Token Count Estimate



    // MARK: - Markdown Cache

    func testMarkdownCacheInvalidation() {
        let msg = makeUserMessage(text: "# Title")
        _ = msg.getOrCreateMarkdownBlocks(from: "# Title")
        XCTAssertNotNil(msg.cachedMarkdownBlocks)

        msg.invalidateMarkdownCache()
        XCTAssertNil(msg.cachedMarkdownBlocks)
    }

    // MARK: - MessageSource (Transient)

    func testMessageSourceDefaultsToLocalUI() {
        let msg = makeUserMessage()
        XCTAssertEqual(msg.messageSource, .localUI)
    }

    func testMessageSourceCanBeSetToRemote() {
        let msg = makeUserMessage()
        msg.messageSource = .telegram
        XCTAssertEqual(msg.messageSource, .telegram)
    }
}
