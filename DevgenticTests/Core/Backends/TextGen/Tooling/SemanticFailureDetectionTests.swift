//
//  SemanticFailureDetectionTests.swift
//  DevgenticTests
//
//  TDD: T1 — Semantic Failure Detection
//

import XCTest
@testable import devgentic

final class SemanticFailureDetectionTests: XCTestCase {

    // MARK: - T1a: Empty String

    func testIsSemanticFailure_EmptyString_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure(""))
    }

    // MARK: - T1b: Short Valid Output "OK"

    func testIsSemanticFailure_OK_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("OK"), "\"OK\" is valid output, should not be flagged as failure")
    }

    // MARK: - T1c: Literal "null"

    func testIsSemanticFailure_Null_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("null"))
    }

    // MARK: - T1d: Normal Success Output

    func testIsSemanticFailure_SuccessMessage_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("Successfully listed 5 files"))
    }

    // MARK: - T1e: Error Prefix

    func testIsSemanticFailure_ErrorPrefix_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("Error: file not found"))
    }

    // MARK: - T1f: "error" Embedded (Not Prefix)

    func testIsSemanticFailure_ErrorEmbedded_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("The error rate was 0.5%"), "\"error\" in middle of string should not trigger hasPrefix check")
    }

    // MARK: - T1g: Whitespace-Only

    func testIsSemanticFailure_WhitespaceOnly_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("   \n  \t  "))
    }

    // MARK: - T1h: Literal "nil"

    func testIsSemanticFailure_Nil_ReturnsTrue() {
        XCTAssertTrue(ToolExecutionMediator.isSemanticFailure("nil"))
    }

    // MARK: - T1i: Short Valid Output "No"

    func testIsSemanticFailure_No_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("No"), "\"No\" is valid output, should not be flagged as failure")
    }

    // MARK: - T1j: Short Numeric Output "42"

    func testIsSemanticFailure_NumericOutput_ReturnsFalse() {
        XCTAssertFalse(ToolExecutionMediator.isSemanticFailure("42"), "Numeric output should not be flagged as failure")
    }
}
