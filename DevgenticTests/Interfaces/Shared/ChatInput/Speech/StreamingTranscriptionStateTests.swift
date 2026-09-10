// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  StreamingTranscriptionStateTests.swift
//  DevgenticTests
//
//  Tests for StreamingTranscriptionState.fullText computation.
//

import XCTest
@testable import devgentic

final class StreamingTranscriptionStateTests: XCTestCase {

    private func makeState(
        confirmed: String = "",
        partial: String = "",
        energy: [Float] = [],
        isRecording: Bool = true,
        isSilence: Bool = false
    ) -> StreamingTranscriptionState {
        StreamingTranscriptionState(
            confirmedText: confirmed,
            partialText: partial,
            bufferEnergy: energy,
            isRecording: isRecording,
            isSilenceDetected: isSilence
        )
    }

    // MARK: - fullText

    func testFullTextCombinesConfirmedAndPartial() {
        let state = makeState(confirmed: "Hello", partial: "world")
        XCTAssertEqual(state.fullText, "Hello world")
    }

    func testFullTextWithOnlyConfirmed() {
        let state = makeState(confirmed: "Hello")
        XCTAssertEqual(state.fullText, "Hello")
    }

    func testFullTextWithOnlyPartial() {
        let state = makeState(partial: "world")
        XCTAssertEqual(state.fullText, "world")
    }

    func testFullTextBothEmpty() {
        let state = makeState()
        XCTAssertEqual(state.fullText, "")
    }

    func testFullTextCollapsesMultipleSpaces() {
        let state = makeState(confirmed: "Hello   ", partial: "  world")
        XCTAssertFalse(state.fullText.contains("  "), "Multiple spaces should be collapsed to single space")
    }

    func testFullTextTrimsWhitespace() {
        let state = makeState(confirmed: "  Hello  ", partial: "  world  ")
        let text = state.fullText
        XCTAssertFalse(text.hasPrefix(" "))
        XCTAssertFalse(text.hasSuffix(" "))
    }

    func testFullTextTrimsNewlines() {
        let state = makeState(confirmed: "\nHello\n", partial: "world\n")
        let text = state.fullText
        XCTAssertFalse(text.hasPrefix("\n"))
        XCTAssertFalse(text.hasSuffix("\n"))
    }
}
