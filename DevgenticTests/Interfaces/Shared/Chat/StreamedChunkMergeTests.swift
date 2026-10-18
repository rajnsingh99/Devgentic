// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StreamedChunkMergeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class StreamedChunkMergeTests: XCTestCase {

    private let errorContent = MessageContent.error(
        title: "Execution Failed",
        details: "[Research Node] Connection refused by the model endpoint",
        category: .providerStreamError,
        suggestion: "Check that the endpoint is reachable and retry."
    )

    // MARK: - ASM-1: error then content

    func testErrorThenContentStartsFreshAnswer() {
        let merged = ChatMessage.resolveStreamedChunkMerge(current: errorContent, chunk: "Here is the summary you asked for.")

        XCTAssertEqual(merged?.content, .markdownText("Here is the summary you asked for."),
                       "Prose streamed after a mid-run error card must start fresh — gluing it onto the card's text laundered the error into the answer's opening words (ASM-1).")
    }

    func testErrorThenContentDemotesToTimelineWarning() {
        let merged = ChatMessage.resolveStreamedChunkMerge(current: errorContent, chunk: "Answer.")

        guard case .warning(_, let category, let text)? = merged?.demotedError else {
            XCTFail("The superseded error card must be demoted to a timeline warning, not silently discarded — it was the only record of the failure. Got: \(String(describing: merged?.demotedError))")
            return
        }
        XCTAssertEqual(category, .midRunError)
        XCTAssertTrue(text.contains("Execution Failed"), "Demoted text must keep the error title")
        XCTAssertTrue(text.contains("Connection refused"), "Demoted text must keep the error details")
    }

    func testErrorSuggestionSurvivesInDemotedText() {
        let merged = ChatMessage.resolveStreamedChunkMerge(current: errorContent, chunk: "Answer.")

        guard case .warning(_, _, let text)? = merged?.demotedError else {
            XCTFail("Expected a demoted warning event")
            return
        }
        XCTAssertTrue(text.contains("Check that the endpoint is reachable"),
                      "The suggestion affordance was part of what ASM-1 destroyed — it must survive the demotion.")
    }

    func testErrorNilTitleUsesErrorFallback() {
        let untitled = MessageContent.error(title: nil, details: "boom", category: nil, suggestion: nil)

        let merged = ChatMessage.resolveStreamedChunkMerge(current: untitled, chunk: "Answer.")

        guard case .warning(_, _, let text)? = merged?.demotedError else {
            XCTFail("Expected a demoted warning event")
            return
        }
        XCTAssertTrue(text.hasPrefix("Error: boom"),
                      "Matches MessageContent.textContent's established (deliberately unlocalized) fallback")
    }

    // MARK: - Controls / pins (prove the harness CAN append — and that normal streaming is untouched)

    func testMarkdownAppendsWithNoDemotion() {
        let merged = ChatMessage.resolveStreamedChunkMerge(current: .markdownText("Hello "), chunk: "world")

        XCTAssertEqual(merged?.content, .markdownText("Hello world"))
        XCTAssertNil(merged?.demotedError, "Ordinary streaming must not fabricate timeline events")
    }

    func testPlainTextAppendConvertsToMarkdown() {
        // Pin of pre-existing behavior: the first chunk onto a .plainText seed
        // rewrites as .markdownText.
        let merged = ChatMessage.resolveStreamedChunkMerge(current: .plainText(""), chunk: "Hi")

        XCTAssertEqual(merged?.content, .markdownText("Hi"))
        XCTAssertNil(merged?.demotedError)
    }

    func testMediaArtifactChunkLeavesContentUntouched() {
        // Pin of the parked media+text decision: content without a text
        // representation drops the chunk (nil = caller leaves content alone).
        let artifact = MediaArtifact(kind: .image, reference: .ephemeralData(Data([0x89])), mimeType: "image/png", label: nil)

        let merged = ChatMessage.resolveStreamedChunkMerge(current: .mediaArtifact(artifact), chunk: "text after image")

        XCTAssertNil(merged, "Media content has no text to merge into — parked decision, must stay a no-op")
    }
}
