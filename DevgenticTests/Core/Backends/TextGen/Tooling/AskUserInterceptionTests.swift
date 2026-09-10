// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  AskUserInterceptionTests.swift
//  DevgenticTests
//
//  TDD: T8 — ask_user Interception Logic
//

import XCTest
@testable import devgentic

final class AskUserInterceptionTests: XCTestCase {

    // MARK: - T8a: ask_user with question key → returns question

    func testExtractQuestion_AskUserWithQuestion_ReturnsQuestion() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: ["question": .string("What file should I read?")]
        )
        XCTAssertEqual(result, "What file should I read?")
    }

    // MARK: - T8b: ask_user without question key → fallback

    func testExtractQuestion_AskUserNoQuestion_ReturnsFallback() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: [:]
        )
        XCTAssertEqual(result, "Please provide clarification to proceed.")
    }

    // MARK: - T8c: Non-ask_user tool → nil (not intercepted)

    func testExtractQuestion_NonAskUser_ReturnsNil() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "read_file",
            arguments: ["question": .string("What file?")]
        )
        XCTAssertNil(result)
    }

    // MARK: - T8d: ask_user with non-string question value → fallback

    func testExtractQuestion_AskUserNonStringQuestion_ReturnsFallback() {
        let result = AskUserInterceptor.extractQuestion(
            toolName: "ask_user",
            arguments: ["question": .number(42)]
        )
        XCTAssertEqual(result, "Please provide clarification to proceed.")
    }
}
