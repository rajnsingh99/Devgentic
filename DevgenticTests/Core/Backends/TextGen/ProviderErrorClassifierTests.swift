// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ProviderErrorClassifierTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class ProviderErrorClassifierTests: XCTestCase {

    private func assertToolsRejection(_ verdict: ProviderErrorVerdict,
                                      file: StaticString = #filePath, line: UInt = #line) {
        guard case .fatal(let reason, let category) = verdict else {
            XCTFail("Expected .fatal, got \(verdict)", file: file, line: line)
            return
        }
        XCTAssertTrue(reason.contains("doesn't support tool calling"),
                      "Reason should name the real cause, got: \(reason)", file: file, line: line)
        XCTAssertEqual(category, .providerCapabilityMissing, file: file, line: line)
    }

    // MARK: - Tools rejection (the new detection)

    func testToolsRejection_OllamaOpenAIShim() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":{"message":"registry.ollama.ai/library/gemma:2b does not support tools"}}"#
        )
        assertToolsRejection(verdict)
    }

    func testToolsRejection_OpenAIUnrecognizedArgument() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":{"message":"Unrecognized request argument supplied: tools"}}"#
        )
        assertToolsRejection(verdict)
    }

    func testToolsRejection_422NotSupported() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 422,
            rawBody: #"{"detail":"\"tools\" is not supported by this model"}"#
        )
        assertToolsRejection(verdict)
    }

    func testToolsRejection_LlamaCppJinja() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":{"message":"tools param requires --jinja flag"}}"#
        )
        assertToolsRejection(verdict)
    }

    // MARK: - Negative cases (must NOT classify as tools rejection)

    /// Tool-argument validation means tools ARE supported — generic verdict.
    func testToolArgumentValidation_StaysGenericBadRequest() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":{"message":"tools[0].function.name is invalid"}}"#
        )
        guard case .fatal(let reason, let category) = verdict else {
            return XCTFail("Expected .fatal, got \(verdict)")
        }
        XCTAssertFalse(reason.contains("doesn't support tool calling"))
        XCTAssertEqual(category, .providerBadRequest)
    }

    /// Thinking-capability 400s mention no tools — must not match.
    func testThinkingUnsupported_DoesNotMatchToolsRejection() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":"this model does not support thinking"}"#
        )
        guard case .fatal(let reason, _) = verdict else {
            return XCTFail("Expected .fatal, got \(verdict)")
        }
        XCTAssertFalse(reason.contains("doesn't support tool calling"))
    }

    // MARK: - Regressions on neighboring arms

    func testContextOverflow_StillClassified() {
        let verdict = ProviderErrorClassifier.classify(
            statusCode: 400,
            rawBody: #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        )
        guard case .fatal(let reason, let category) = verdict else {
            return XCTFail("Expected .fatal, got \(verdict)")
        }
        XCTAssertTrue(reason.contains("context window"))
        XCTAssertEqual(category, .providerCapabilityMissing)
    }

    func testThrottle_429() {
        let verdict = ProviderErrorClassifier.classify(statusCode: 429, rawBody: "", retryAfter: 30)
        XCTAssertEqual(verdict, .throttle(retryAfter: 30))
    }
}
