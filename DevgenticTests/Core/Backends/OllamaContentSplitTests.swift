// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaContentSplitTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class OllamaContentSplitTests: XCTestCase {

    /// Ordinary model prose that happens to contain balanced brackets. None of it is JSON.
    private let bracketedProse = [
        "I read the file but the output was [truncated] so I could not see the end of it.",
        "See [the docs](https://example.com) for details on the retry policy.",
        "This follows the approach in [1] which uses exponential backoff.",
        "Use the pattern [a-z]+ to match lowercase words in the input.",
        "The log line [INFO] startup complete confirms the service booted.",
        "The set {alpha, beta} is unordered.",
    ]

    // MARK: - Nothing is lost

    func testBracketedProseSurvivesIntact() {
        for text in bracketedProse {
            let (prose, block) = OllamaLLMProvider.splitProseAndJSON(text)
            XCTAssertEqual(prose, text, "prose was truncated at a bracket: \(text)")
            XCTAssertTrue(block.isEmpty, "ordinary prose was treated as a tool call: \(text)")
        }
    }

    /// ⚠️ THE INVARIANT, stated once rather than per-case: the split may REARRANGE the model's
    /// output, never shrink it. Counting non-whitespace characters is deliberate — it is
    /// order-independent, so it holds for the rejoin of prose-before and prose-after without the
    /// test having to know which side a fragment landed on.
    func testTheSplitNeverLosesCharacters() {
        let inputs = bracketedProse + [
            #"Reading it now. {"name":"read_file","arguments":{"path":"a.txt"}} That should do it."#,
            #"go [{"name":"ls"}] and then stop"#,
            "plain prose with no brackets at all",
        ]
        for text in inputs {
            let (prose, block) = OllamaLLMProvider.splitProseAndJSON(text)
            let before = text.filter { !$0.isWhitespace }.count
            let after = (prose + block).filter { !$0.isWhitespace }.count
            XCTAssertEqual(after, before,
                           "\(before - after) non-whitespace character(s) vanished from: \(text)")
        }
    }

    // MARK: - A real leaked tool call is still extracted

    func testALeakedToolCallIsSplitOutAndTheProseIsRejoined() {
        // The case the split exists for (G7) — and the one where the tail loss was invisible,
        // because a model usually says something after emitting a call.
        let text = #"Reading it now. {"name":"read_file","arguments":{"path":"a.txt"}} That should do it."#
        let (prose, block) = OllamaLLMProvider.splitProseAndJSON(text)

        XCTAssertEqual(block, #"{"name":"read_file","arguments":{"path":"a.txt"}}"#)
        XCTAssertTrue(prose.contains("Reading it now."), "text before the call was lost")
        XCTAssertTrue(prose.contains("That should do it."),
                      "text AFTER the call was lost — this is the tail that used to be discarded")
        XCTAssertFalse(prose.contains("read_file"),
                       "the call's JSON must not be echoed back as the model's reasoning")
    }

    func testALeakedCallIsStillFoundWhenBracketedProseComesFirst() {
        // Rejecting the bracketed word must not abandon the search — otherwise fixing the false
        // positive would create a false negative, and real tool calls would stop being recovered.
        let text = #"The output was [truncated]. Retrying: {"name":"ls","arguments":{}} ok."#
        let (prose, block) = OllamaLLMProvider.splitProseAndJSON(text)

        XCTAssertEqual(block, #"{"name":"ls","arguments":{}}"#)
        XCTAssertTrue(prose.contains("[truncated]"), "the bracketed prose belongs in the prose")
        XCTAssertTrue(prose.contains("ok."))
    }

    // MARK: - The incident, exactly

    func testTheObservedIncidentDoesNotRecur() {
        // ⚠️ THE REGRESSION GUARD. Before the fix this returned block == "[truncated]" (11 bytes),
        // the parser received those 11 bytes in place of the answer, and everything after the
        // bracket was discarded.
        let text = "I read the file but the output was [truncated] so I could not see the end of it."
        let (prose, block) = OllamaLLMProvider.splitProseAndJSON(text)

        XCTAssertNotEqual(block, "[truncated]")
        XCTAssertTrue(block.isEmpty)
        XCTAssertEqual(prose.count, text.count, "the answer must reach the user whole")
    }
}
