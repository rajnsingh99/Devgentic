// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  OllamaOptionMappingTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class OllamaOptionMappingTests: XCTestCase {

    // MARK: - The rule

    /// ⚠️ THE ASSERTION THAT MATTERS MOST, and the one that fails on the old code.
    func testEmptyStopListIsOmittedEntirelyRatherThanSentAsAnEmptyArray() {
        let mapped = OllamaLLMProvider.mapToOllamaOptions(["stop": .array([])])

        XCTAssertNil(mapped["stop"],
                     "an empty `stop` must never reach the wire — Ollama treats it as an empty stop "
                     + "list that REPLACES the model's Modelfile stops, disabling them. Got: \(mapped)")
        XCTAssertTrue(mapped.isEmpty, "nothing else should be invented: \(mapped)")
    }

    /// The inverse, so "drop `stop` always" cannot pass the test above. A user's real stop
    /// sequences must still be honoured — that is the whole point of the option existing.
    func testNonEmptyStopListIsForwarded() {
        let mapped = OllamaLLMProvider.mapToOllamaOptions([
            "stop": .array([.string("<|im_end|>"), .string("[TOOL_CALLS]")])
        ])

        let stops = mapped["stop"] as? [Any]
        XCTAssertEqual(stops?.count, 2, "user stop sequences must reach the wire. Got: \(mapped)")
        XCTAssertEqual(stops?.first as? String, "<|im_end|>")
    }

    /// A single non-array `stop` is passed through untouched — the emptiness rule is about an
    /// empty COLLECTION, and this arm must not start reshaping values it was not measured against.
    func testNonArrayStopIsPassedThroughUnchanged() {
        let mapped = OllamaLLMProvider.mapToOllamaOptions(["stop": .string("<|im_end|>")])
        XCTAssertEqual(mapped["stop"] as? String, "<|im_end|>")
    }

    /// ⚠️ The rule is scoped to `stop` on purpose: the empty-collection-overrides semantics was
    /// verified for that key and not assumed for the rest of Ollama's option surface. If a future
    /// change generalises it to "drop every empty array", this test should be the deliberate edit.
    func testOtherEmptyCollectionsAreNotSilentlyDropped() {
        let mapped = OllamaLLMProvider.mapToOllamaOptions(["someFutureArrayOption": .array([])])
        XCTAssertNotNil(mapped["someFutureArrayOption"],
                        "only `stop` is filtered — this key was never measured: \(mapped)")
    }

    // MARK: - Regression guard on the rest of the mapping

    /// The `stop` arm sits in the same switch as the renames; a careless edit there is the obvious
    /// way to break them.
    func testKeyRenamesStillApply() {
        let mapped = OllamaLLMProvider.mapToOllamaOptions([
            "numCtx": .number(8192),
            "topP": .number(0.6),
            "topK": .number(40),
            "repeatPenalty": .number(1.1),
            "temperature": .number(0.1),
            "seed": .number(42),
        ])

        XCTAssertEqual(mapped["num_ctx"] as? Double, 8192)
        XCTAssertEqual(mapped["top_p"] as? Double, 0.6)
        XCTAssertEqual(mapped["top_k"] as? Double, 40)
        XCTAssertEqual(mapped["repeat_penalty"] as? Double, 1.1)
        // Unrenamed keys pass through under their own name.
        XCTAssertEqual(mapped["temperature"] as? Double, 0.1)
        XCTAssertEqual(mapped["seed"] as? Double, 42)
        // The app-side spellings must NOT also appear.
        XCTAssertNil(mapped["numCtx"]); XCTAssertNil(mapped["topP"])
        XCTAssertNil(mapped["topK"]);   XCTAssertNil(mapped["repeatPenalty"])
    }

    /// The exact preset from the failing 2026-09-13 log, end to end.
    func testTheShippedAgentPresetNoLongerStripsTheModelsStops() {
        let preset: [String: JSONValue] = [
            "repeatPenalty": .number(1.1),
            "stop": .array([]),
            "topP": .number(0.6),
            "numCtx": .number(8192),
            "seed": .number(42),
            "topK": .number(40),
            "temperature": .number(0.1),
        ]

        let mapped = OllamaLLMProvider.mapToOllamaOptions(preset)

        XCTAssertNil(mapped["stop"], "the default agent preset must not disable the model's stops")
        XCTAssertEqual(mapped.count, 6, "every other option still ships: \(mapped)")
    }

    // MARK: - Wiring

    /// ⚠️ DRIFT TEST over real source. The rule lives in one function, so it is only enforced while
    /// every request actually goes through that function. A body assembled inline at one call site
    /// would restore the defect for that path alone, and every test above would stay green.
    func testEveryOptionsBodyGoesThroughTheMapper() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = repoRoot.appendingPathComponent("Devgentic/Core/Backends/OllamaLLMProvider.swift")

        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("source not reachable — running outside a checkout")
        }
        let assignments = try String(contentsOf: source, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("body[\"options\"]") && !$0.hasPrefix("//") }

        XCTAssertGreaterThanOrEqual(assignments.count, 3,
                                    "expected the known options call sites — the scan found \(assignments.count), "
                                    + "so it may no longer be matching anything")
        for line in assignments {
            XCTAssertTrue(
                line.contains("mapToOllamaOptions("),
                "an options body bypasses the mapper (`\(line)`) — the empty-`stop` rule would not "
                + "apply on that path, and the model's Modelfile stops would be disabled again."
            )
        }
    }
}
