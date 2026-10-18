// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HistoryEmptyTurnAndIndexTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class HistoryEmptyTurnAndIndexTests: XCTestCase {

    private let convID = UUID()
    private var clock = Date(timeIntervalSince1970: 7_000_000)

    private func next() -> Date { clock = clock.addingTimeInterval(1); return clock }

    private func message(_ sender: SenderRole, _ content: MessageContent, images: Int = 0) -> ChatMessage {
        let m = ChatMessage(id: UUID(), conversationId: convID, timestamp: next(), sender: sender, content: content)
        if images > 0 {
            m.attachedImageFiles = (0..<images).map {
                AttachedImageFile(name: "img\($0).png", url: URL(fileURLWithPath: "/tmp/img\($0).png"),
                                  fileExtension: "png", binaryData: Data([0x89]), size: 1)
            }
        }
        return m
    }

    private func exchange(_ question: String, _ answer: String) -> [ChatMessage] {
        [message(.user, .plainText(question)), message(.agent, .plainText(answer))]
    }

    private func args(_ index: Int) throws -> ConversationHistoryTool.Arguments {
        try JSONDecoder().decode(ConversationHistoryTool.Arguments.self, from: Data("{\"index\":\(index)}".utf8))
    }

    // MARK: - CR-10: no empty turn reaches a provider

    /// Every shape that produced an empty turn, in one conversation.
    private func emptyShapes() -> [ChatMessage] {
        [
            message(.user, .plainText("draw a cat")),
            message(.agent, .mediaArtifact(MediaArtifact(kind: .image, reference: .ephemeralData(Data()), mimeType: "image/png"))),
            message(.user, .plainText("now explain the build")),
            message(.agent, .markdownText("")),                       // force-quit mid-run
            message(.user, .plainText(""), images: 2),                // image-only
            message(.agent, .plainText("Two screenshots of the error.")),
        ]
    }

    /// ⚠️⚠️ THE CR-10 PROPERTY, on every strategy and both image modes.
    func testNoStrategyEverEmitsAnEmptyTextTurn() {
        for strategy in [HistoryStrategy.recentHistory, .fullHistory, .pointer, .hybrid] {
            for includeImages in [false, true] {
                let turns = NativeHistoryConverter.build(strategy: strategy, from: emptyShapes(), charBudget: 100_000,
                                                         includeImages: includeImages, toolsAvailable: true)
                for turn in turns where turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    XCTFail("\(strategy) includeImages=\(includeImages): an empty \(turn.role) turn would be an HTTP 400")
                }
                XCTAssertEqual(turns.count, 6, "\(strategy): no exchange may be DROPPED — that renumbers every later turn")
            }
        }
    }

    /// The placeholder text is factual, not invented content.
    func testThePlaceholdersSayWhatHappened() {
        let turns = NativeHistoryConverter.build(strategy: .fullHistory, from: emptyShapes(), charBudget: 100_000,
                                                 includeImages: false, toolsAvailable: true)
        XCTAssertTrue(turns[1].text.contains("image"), turns[1].text)
        XCTAssertEqual(turns[3].text, "(No response recorded)")
        XCTAssertEqual(turns[4].text, "(The user sent 2 images.)")
    }

    /// With images included, the image-only turn still carries its images.
    func testAnImageOnlyTurnKeepsItsImagesWhenTheyAreIncluded() {
        let turns = NativeHistoryConverter.build(strategy: .fullHistory, from: emptyShapes(), charBudget: 100_000,
                                                 includeImages: true, toolsAvailable: true)
        XCTAssertEqual(turns[4].imageMedia.count, 2)
    }

    /// The control: ordinary text is untouched.
    func testOrdinaryTextIsUnchanged() {
        let turns = NativeHistoryConverter.build(strategy: .fullHistory, from: exchange("Q?", "A."), charBudget: 100_000,
                                                 toolsAvailable: true)
        XCTAssertEqual(turns.map(\.text), ["Q?", "A."])
    }

    // MARK: - CR-11: the tool returns the turn the skeleton numbered

    /// Two compacted turns, a checkpoint, then two live turns. Compacted rows are never deleted.
    private func compactedConversation() -> [ChatMessage] {
        exchange("OLD question one", "old answer one")
            + exchange("OLD question two", "old answer two")
            + [message(.agent, .checkpoint(summary: "Earlier: two questions about the build."))]
            + exchange("NEW question A", "new answer A")
            + exchange("NEW question B", "new answer B")
    }

    /// ⚠️⚠️ THE CR-11 DEFECT. The skeleton's (0) is "NEW question A"; the tool returned "OLD question one".
    func testAfterACompactionIndexZeroIsTheFirstTurnAfterTheCheckpoint() async throws {
        let history = compactedConversation()

        let skeleton = EpisodicHistoryFormatter.buildPointerHistoryString(from: history)
        XCTAssertTrue(skeleton.contains("get_conversation_history(0)"), "precondition: the skeleton offers (0)")

        let tool = ConversationHistoryTool(chatHistory: history)
        let zero = try await tool.call(arguments: args(0))
        XCTAssertTrue(zero.contains("NEW question A"), "get_conversation_history(0) returned the wrong turn:\n\(zero)")
        XCTAssertFalse(zero.contains("OLD question"))
        let one = try await tool.call(arguments: args(1))
        XCTAssertTrue(one.contains("NEW question B"), one)
    }

    /// The native pointer skeleton numbers the same turns the tool returns.
    func testTheNativeSkeletonAndTheToolAgreeOnEveryIndex() async throws {
        let history = compactedConversation()
        let native = NativeHistoryConverter.buildPointerTurns(from: history, toolsAvailable: true)
        let pointers = native.filter { $0.role == .assistant && $0.text.contains("get_conversation_history(") }
        XCTAssertEqual(pointers.count, 2)
        let tool = ConversationHistoryTool(chatHistory: history)
        for (index, _) in pointers.enumerated() {
            XCTAssertTrue(pointers[index].text.contains("get_conversation_history(\(index))"))
            let userTurnBefore = native[native.firstIndex(where: { $0.text == pointers[index].text })! - 1]
            let retrieved = try await tool.call(arguments: args(index))
            XCTAssertTrue(retrieved.contains(userTurnBefore.text), "(\(index)): skeleton says '\(userTurnBefore.text)', tool returned:\n\(retrieved)")
        }
    }

    /// The smaller drift: an UNREADABLE row was skipped by one pairing and not the other.
    func testAnUnreadableRowDoesNotShiftTheIndices() async throws {
        let unreadable = message(.agent, .unknown(type: "fromTheFuture", payload: .object([:])))
        let history = exchange("first", "a1") + [message(.user, .plainText("orphaned")), unreadable] + exchange("last", "a2")

        let nativePairs = NativeHistoryConverter.buildPointerTurns(from: history, toolsAvailable: true)
            .filter { $0.role == .assistant }.count
        XCTAssertEqual(EpisodicHistoryFormatter.retrievableTurns(from: history).count, nativePairs,
                       "the two pairings must agree on how many turns exist")
        let tool = ConversationHistoryTool(chatHistory: history)
        let lastIndex = nativePairs - 1
        let retrieved = try await tool.call(arguments: args(lastIndex))
        XCTAssertTrue(retrieved.contains("last"), "(\(lastIndex)) returned:\n\(retrieved)")
    }
}
