// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatMessageSDTests.swift
//  DevgenticTests
//
//  Created on 03/04/26.
//
//  Tests ChatMessageSD ↔ ChatMessage round-trip mapping fidelity.
//  Validates that all fields survive the encode → persist → decode cycle,
//  including complex nested types (AgentResponse, TimelineEvent, attachments).
//

import XCTest
import SwiftData
@testable import devgentic

@MainActor
final class ChatMessageSDTests: XCTestCase {

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

    // MARK: - Basic Round-Trip

    func testPlainTextMessageRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText("Hello, world!")
        )

        let sd = ChatMessageSD.from(original)
        context.insert(sd)
        try? context.save()

        let decoded = sd.toChatMessage()
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.conversationId, original.conversationId)
        XCTAssertEqual(decoded.sender, .user)
        XCTAssertEqual(decoded.content, .plainText("Hello, world!"))
    }

    func testMarkdownTextRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText("# Title\n\nSome **bold** text."),
            backendEntityId: UUID()
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        // Agent messages store content in agentResponse variant
        let expectedContent = decoded.currentAgentContent ?? decoded.content
        XCTAssertEqual(expectedContent.textContent, "# Title\n\nSome **bold** text.")
        XCTAssertEqual(decoded.sender, .agent)
    }

    func testCodeBlockRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .codeBlock(language: "swift", code: "print(\"hi\")"),
            backendEntityId: UUID()
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()
        let content = decoded.currentAgentContent ?? decoded.content

        if case .codeBlock(let lang, let code) = content {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "print(\"hi\")")
        } else {
            XCTFail("Expected codeBlock content, got \(content)")
        }
    }

    func testErrorContentRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .error(title: "Timeout", details: "Model timed out after 60s"),
            backendEntityId: UUID()
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()
        let content = decoded.currentAgentContent ?? decoded.content

        if case .error(let title, let details, _, _) = content {
            XCTAssertEqual(title, "Timeout")
            XCTAssertEqual(details, "Model timed out after 60s")
        } else {
            XCTFail("Expected error content")
        }
    }

    // MARK: - AgentResponse Round-Trip

    func testAgentResponseVariantsRoundTrip() {
        let convId = UUID()
        let original = ChatMessage(
            conversationId: convId,
            sender: .agent,
            content: .markdownText("First attempt"),
            backendEntityId: UUID()
        )

        // Simulate regeneration: add a second variant
        let secondVariant = ResponseMessageVariant(
            content: .markdownText("Second attempt"),
            backendEntityId: UUID()
        )
        original.agentResponse?.variants.append(secondVariant)
        original.agentResponse?.selectedVariantIndex = 1
        original.agentResponse?.generationAttempts = 2

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertNotNil(decoded.agentResponse)
        XCTAssertEqual(decoded.agentResponse?.variants.count, 2)
        XCTAssertEqual(decoded.agentResponse?.selectedVariantIndex, 1)
        XCTAssertEqual(decoded.agentResponse?.generationAttempts, 2)
        XCTAssertEqual(decoded.currentAgentContent?.textContent, "Second attempt")
    }

    // MARK: - Timeline Events Round-Trip

    func testTimelineEventsRoundTrip() {
        let convId = UUID()
        let original = ChatMessage(
            conversationId: convId,
            sender: .agent,
            content: .markdownText("Result"),
            backendEntityId: UUID()
        )

        let thoughtId = UUID()
        let toolId = UUID()
        original.timelineEvents = [
            .thought(id: thoughtId, text: "Let me think about this..."),
            .toolExecution(ToolExecutionData(id: toolId, name: "bash", params: "{\"cmd\": \"ls\"}", output: "file.txt", isSuccess: true, isExecuting: false))
        ]

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.timelineEvents.count, 2)

        if case .thought(let id, let text) = decoded.timelineEvents[0] {
            XCTAssertEqual(id, thoughtId)
            XCTAssertEqual(text, "Let me think about this...")
        } else {
            XCTFail("Expected thought event")
        }

        if case .toolExecution(let data) = decoded.timelineEvents[1] {
            XCTAssertEqual(data.id, toolId)
            XCTAssertEqual(data.name, "bash")
            XCTAssertEqual(data.params, "{\"cmd\": \"ls\"}")
            XCTAssertEqual(data.output, "file.txt")
            XCTAssertEqual(data.isSuccess, true)
            XCTAssertEqual(data.isExecuting, false)
        } else {
            XCTFail("Expected toolExecution event")
        }
    }

    func testCapabilityMilestoneRoundTrip() {
        let convId = UUID()
        let original = ChatMessage(
            conversationId: convId,
            sender: .agent,
            content: .markdownText("Done"),
            backendEntityId: UUID()
        )

        let milestoneId = UUID()
        original.timelineEvents = [
            .capabilityMilestone(id: milestoneId, kind: .planGenerated, detail: "Planned 3 subtasks")
        ]

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.timelineEvents.count, 1)
        if case .capabilityMilestone(let id, let kind, let detail) = decoded.timelineEvents[0] {
            XCTAssertEqual(id, milestoneId)
            XCTAssertEqual(kind, .planGenerated)
            XCTAssertEqual(detail, "Planned 3 subtasks")
        } else {
            XCTFail("Expected capabilityMilestone event")
        }
    }

    func testEmptyTimelineEventsRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText("No events")
        )

        let sd = ChatMessageSD.from(original)
        XCTAssertNil(sd.timelineEventsData, "Empty timeline should produce nil data")

        let decoded = sd.toChatMessage()
        XCTAssertTrue(decoded.timelineEvents.isEmpty)
    }

    // MARK: - Attached Files Round-Trip

    func testTextFileAttachmentRoundTrip() {
        let convId = UUID()
        let textFile = AttachedTextFile(
            name: "main.swift",
            url: URL(string: "file:///tmp/main.swift")!,
            fileExtension: "swift",
            content: "import Foundation\nprint(\"Hello\")",
            size: 32
        )
        let original = ChatMessage(
            conversationId: convId,
            sender: .user,
            content: .plainText("Check this file"),
            attachedTextFiles: [textFile]
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.attachedTextFiles?.count, 1)
        let file = decoded.attachedTextFiles!.first!
        XCTAssertEqual(file.name, "main.swift")
        XCTAssertEqual(file.fileExtension, "swift")
        XCTAssertEqual(file.content, "import Foundation\nprint(\"Hello\")")
        XCTAssertEqual(file.size, 32)
    }

    func testImageFileAttachmentRoundTrip() {
        let convId = UUID()
        let imageData = Data(repeating: 0xFF, count: 64)
        let imageFile = AttachedImageFile(
            name: "screenshot.png",
            url: URL(string: "file:///tmp/screenshot.png")!,
            fileExtension: "png",
            binaryData: imageData,
            size: 64
        )
        let original = ChatMessage(
            conversationId: convId,
            sender: .user,
            content: .plainText("See image"),
            attachedImageFiles: [imageFile]
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.attachedImageFiles?.count, 1)
        let file = decoded.attachedImageFiles!.first!
        XCTAssertEqual(file.name, "screenshot.png")
        XCTAssertEqual(file.binaryData, imageData)
        XCTAssertEqual(file.size, 64)
    }

    func testNoAttachmentsRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText("No files")
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertNil(decoded.attachedTextFiles)
        XCTAssertNil(decoded.attachedImageFiles)
    }

    // MARK: - TraceID Round-Trip

    func testTraceIDRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText("Traced"),
            backendEntityId: UUID()
        )
        original.traceID = "trace-abc-123"

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.traceID, "trace-abc-123")
    }

    func testNilTraceIDRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText("No trace")
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertNil(decoded.traceID)
    }

    // MARK: - Transient Properties Not Persisted

    func testTransientPropertiesResetAfterRoundTrip() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText("Thinking..."),
            backendEntityId: UUID()
        )
        // Set transient state
        original.agentState = .thinking(.reasoning)
        original.isStreaming = true

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        // Transient properties should be reset
        XCTAssertEqual(decoded.agentState, .idle)
        XCTAssertFalse(decoded.isStreaming)
    }

    // MARK: - Timestamp Fidelity

    func testTimestampPrecision() {
        let now = Date()
        let original = ChatMessage(
            conversationId: UUID(),
            timestamp: now,
            sender: .user,
            content: .plainText("Timed")
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       now.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Edge Cases

    func testEmptyStringContent() {
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText("")
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.content.textContent, "")
    }

    func testVeryLongContent() {
        let longText = String(repeating: "A", count: 100_000)
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .agent,
            content: .markdownText(longText),
            backendEntityId: UUID()
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()
        let content = decoded.currentAgentContent ?? decoded.content

        XCTAssertEqual(content.textContent?.count, 100_000)
    }

    func testUnicodeContent() {
        let unicodeText = "🚀 Swift is 素晴らしい! Ñoño → αβγ"
        let original = ChatMessage(
            conversationId: UUID(),
            sender: .user,
            content: .plainText(unicodeText)
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.content.textContent, unicodeText)
    }

    func testMultipleAttachmentFiles() {
        let convId = UUID()
        let textFiles = (0..<3).map { i in
            AttachedTextFile(
                name: "file\(i).swift",
                url: URL(string: "file:///tmp/file\(i).swift")!,
                fileExtension: "swift",
                content: "// file \(i)",
                size: Int64(10 + i)
            )
        }
        let imageFiles = (0..<2).map { i in
            AttachedImageFile(
                name: "img\(i).png",
                url: URL(string: "file:///tmp/img\(i).png")!,
                fileExtension: "png",
                binaryData: Data(repeating: UInt8(i), count: 8),
                size: 8
            )
        }

        let original = ChatMessage(
            conversationId: convId,
            sender: .user,
            content: .plainText("Multiple files"),
            attachedTextFiles: textFiles,
            attachedImageFiles: imageFiles
        )

        let sd = ChatMessageSD.from(original)
        let decoded = sd.toChatMessage()

        XCTAssertEqual(decoded.attachedTextFiles?.count, 3)
        XCTAssertEqual(decoded.attachedImageFiles?.count, 2)
    }

    // MARK: - Corrupted Data Handling

    func testCorruptedContentDataFallsBack() {
        let sd = ChatMessageSD(
            id: UUID(),
            conversationId: UUID(),
            timestamp: Date(),
            senderType: "user",
            traceID: nil,
            contentData: Data("not valid json".utf8),
            agentResponseData: nil,
            timelineEventsData: nil
        )

        let decoded = sd.toChatMessage()
        // Should fall back to error content
        if case .error(let title, _, _, _) = decoded.content {
            XCTAssertEqual(title, "Decode Error")
        } else {
            XCTFail("Expected error content for corrupted data")
        }
    }

    func testCorruptedAgentResponseDataIgnored() {
        let contentData = try! JSONEncoder().encode(MessageContent.plainText("OK"))
        let sd = ChatMessageSD(
            id: UUID(),
            conversationId: UUID(),
            timestamp: Date(),
            senderType: "agent",
            traceID: nil,
            contentData: contentData,
            agentResponseData: Data("bad json".utf8),
            timelineEventsData: nil
        )

        let decoded = sd.toChatMessage()
        // Should decode content but skip agent response
        XCTAssertNil(decoded.agentResponse)
        XCTAssertEqual(decoded.content.textContent, "OK")
    }

    func testCorruptedTimelineEventsDataIgnored() {
        let contentData = try! JSONEncoder().encode(MessageContent.plainText("OK"))
        let sd = ChatMessageSD(
            id: UUID(),
            conversationId: UUID(),
            timestamp: Date(),
            senderType: "user",
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: Data("bad json".utf8)
        )

        let decoded = sd.toChatMessage()
        XCTAssertTrue(decoded.timelineEvents.isEmpty, "Corrupted timeline data should produce empty array")
    }

    // MARK: - SenderRole Mapping

    func testUnknownSenderRoleDefaultsToUser() {
        let contentData = try! JSONEncoder().encode(MessageContent.plainText("Unknown sender"))
        let sd = ChatMessageSD(
            id: UUID(),
            conversationId: UUID(),
            timestamp: Date(),
            senderType: "unknown_role",
            traceID: nil,
            contentData: contentData,
            agentResponseData: nil,
            timelineEventsData: nil
        )

        let decoded = sd.toChatMessage()
        XCTAssertEqual(decoded.sender, .user, "Unknown sender type should default to .user")
    }
}
