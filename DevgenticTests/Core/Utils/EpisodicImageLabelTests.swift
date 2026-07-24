//
//  EpisodicImageLabelTests.swift
//  DevgenticTests
//
//  Covers the `<attached_images>` label in the episodic memory XML — the per-turn
//  filename hook that lets a vision model map the re-provided image bytes back to the
//  turn they belonged to. Vision-gated: labels appear only when images are actually
//  being sent (non-vision → omitted, so labeling them would be misleading).
//

import XCTest
@testable import devgentic

final class EpisodicImageLabelTests: XCTestCase {

    private let convID = UUID()

    private func userMessage(_ text: String, images: [String] = []) -> ChatMessage {
        let m = ChatMessage(conversationId: convID, sender: .user, content: .plainText(text))
        if !images.isEmpty {
            m.attachedImageFiles = images.map { name in
                AttachedImageFile(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                                  fileExtension: (name as NSString).pathExtension,
                                  binaryData: Data([0x1]), size: 1)
            }
        }
        return m
    }

    private func agentMessage(_ text: String) -> ChatMessage {
        ChatMessage(conversationId: convID, sender: .agent, content: .plainText(text))
    }

    // The scenario from the walkthrough: 2 images across 3 turns.
    private func twoImagesThreeTurns() -> [ChatMessage] {
        [
            userMessage("Describe this", images: ["chart-a.png"]),
            agentMessage("A bar chart of Q1–Q4 revenue."),
            userMessage("And this?", images: ["chart-b.png"]),
            agentMessage("A line chart of monthly active users."),
            userMessage("Which shows better growth?")   // text-only current-ish turn
        ]
    }

    // MARK: - Rendering (vision profiles)

    func testLabelsRenderedWhenEnabled() {
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: twoImagesThreeTurns(), limit: 10, includeImageNames: true
        )
        XCTAssertTrue(xml.contains("<attached_images>chart-a.png</attached_images>"),
                      "Turn 1's image must be labeled")
        XCTAssertTrue(xml.contains("<attached_images>chart-b.png</attached_images>"),
                      "Turn 2's image must be labeled")
    }

    func testLabelBelongsToTheCorrectTurn() {
        // The label must sit inside the turn whose goal it belongs to — not bleed onto
        // a text turn.
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(
            from: twoImagesThreeTurns(), limit: 10, includeImageNames: true
        )
        // "Describe this" turn carries chart-a; the block between that goal and the next
        // turn must contain the chart-a label.
        guard let describeRange = xml.range(of: "goal=\"Describe this\""),
              let andThisRange = xml.range(of: "goal=\"And this?\"") else {
            return XCTFail("expected both goals present")
        }
        let firstTurnBlock = String(xml[describeRange.lowerBound..<andThisRange.lowerBound])
        XCTAssertTrue(firstTurnBlock.contains("chart-a.png"))
        XCTAssertFalse(firstTurnBlock.contains("chart-b.png"), "chart-b belongs to a later turn")
    }

    // MARK: - Vision gate (the honesty guard)

    func testLabelsOmittedByDefault() {
        // Default (non-vision) → NO labels, because those images aren't sent. Labeling
        // an image the model won't receive would be misleading.
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: twoImagesThreeTurns(), limit: 10)
        XCTAssertFalse(xml.contains("<attached_images>"),
                       "Non-vision profiles must not advertise images they won't receive")
    }

    // MARK: - Text turns + multiple images + escaping

    func testTextOnlyTurnGetsNoLabel() {
        let history = [userMessage("just text"), agentMessage("ok")]
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10, includeImageNames: true)
        XCTAssertFalse(xml.contains("<attached_images>"))
    }

    func testMultipleImagesOnOneTurnAreCommaJoined() {
        let history = [userMessage("look", images: ["a.png", "b.jpg"]), agentMessage("ok")]
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10, includeImageNames: true)
        XCTAssertTrue(xml.contains("<attached_images>a.png, b.jpg</attached_images>"))
    }

    func testImageNameIsXMLEscaped() {
        let history = [userMessage("q", images: ["a & b <weird>.png"]), agentMessage("ok")]
        let xml = EpisodicHistoryFormatter.buildRecentHistoryString(from: history, limit: 10, includeImageNames: true)
        XCTAssertTrue(xml.contains("a &amp; b &lt;weird&gt;.png"), "Filename must be XML-escaped")
        XCTAssertFalse(xml.contains("a & b <weird>.png"))
    }

    // MARK: - Hybrid strategy parity

    func testHybridStrategyAlsoLabelsRecentImages() {
        let xml = EpisodicHistoryFormatter.buildHybridHistoryString(
            from: twoImagesThreeTurns(), inlineCount: 3, includeImageNames: true
        )
        XCTAssertTrue(xml.contains("<attached_images>chart-a.png</attached_images>"))
    }
}
