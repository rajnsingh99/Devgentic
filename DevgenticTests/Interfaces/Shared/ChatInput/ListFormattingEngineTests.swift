//
//  ListFormattingEngineTests.swift
//  DevgenticTests
//
//  Tests for ListFormattingEngine — numbered list detection, empty item check,
//  enter-key state machine, and paragraph style creation.
//

import XCTest
import AppKit
@testable import devgentic

final class ListFormattingEngineTests: XCTestCase {

    // MARK: - detectListItem

    func testDetectsSimpleNumberedItem() {
        let string: NSString = "1. Hello world"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.number, 1)
    }

    func testDetectsDoubleDigitNumber() {
        let string: NSString = "42. Some item"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.number, 42)
    }

    func testRejectsTextWithoutListMarker() {
        let string: NSString = "Hello world"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNil(result)
    }

    func testRejectsMissingSpaceAfterDot() {
        let string: NSString = "1.Hello"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNil(result, "Pattern requires space after the dot")
    }

    func testRejectsDotWithoutNumber() {
        let string: NSString = ". Hello"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNil(result)
    }

    func testDetectsItemInMiddleOfTextStorage() {
        let string: NSString = "Intro paragraph\n5. Fifth item\nAfter"
        // Paragraph range for "5. Fifth item" — starts at 16, length 13 (without newline)
        let paragraphStart = 16
        let paragraphLength = 13
        let range = NSRange(location: paragraphStart, length: paragraphLength)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.number, 5)
    }

    func testDetectsZeroAsListNumber() {
        let string: NSString = "0. Item zero"
        let range = NSRange(location: 0, length: string.length)
        let result = ListFormattingEngine.detectListItem(in: string, paragraphRange: range)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.number, 0)
    }

    // MARK: - isEmptyListItem

    func testEmptyListItemWithOnlyMarker() {
        let string: NSString = "3. "
        let range = NSRange(location: 0, length: string.length)
        XCTAssertTrue(ListFormattingEngine.isEmptyListItem(in: string, paragraphRange: range))
    }

    func testEmptyListItemWithTrailingWhitespace() {
        let string: NSString = "3.   "
        let range = NSRange(location: 0, length: string.length)
        XCTAssertTrue(ListFormattingEngine.isEmptyListItem(in: string, paragraphRange: range))
    }

    func testNonEmptyListItem() {
        let string: NSString = "3. some content"
        let range = NSRange(location: 0, length: string.length)
        XCTAssertFalse(ListFormattingEngine.isEmptyListItem(in: string, paragraphRange: range))
    }

    func testNonListItemIsNotEmpty() {
        let string: NSString = "plain text"
        let range = NSRange(location: 0, length: string.length)
        XCTAssertFalse(ListFormattingEngine.isEmptyListItem(in: string, paragraphRange: range))
    }

    // MARK: - handleEnterKey

    func testPassthroughForNonListText() {
        let storage = NSTextStorage(string: "Just regular text")
        let result = ListFormattingEngine.handleEnterKey(
            textStorage: storage,
            selectedRange: NSRange(location: 17, length: 0)
        )
        if case .passthrough = result {
            // Expected
        } else {
            XCTFail("Expected .passthrough for non-list text, got \(result)")
        }
    }

    func testContinueListInsertsNextNumber() {
        let storage = NSTextStorage(string: "1. First item")
        let result = ListFormattingEngine.handleEnterKey(
            textStorage: storage,
            selectedRange: NSRange(location: 13, length: 0) // cursor at end
        )
        if case .continueList(let text) = result {
            XCTAssertEqual(text, "\n2. ", "Should insert next numbered item")
        } else {
            XCTFail("Expected .continueList, got \(result)")
        }
    }

    func testContinueListIncrementsHighNumbers() {
        let storage = NSTextStorage(string: "99. Ninety nine")
        let result = ListFormattingEngine.handleEnterKey(
            textStorage: storage,
            selectedRange: NSRange(location: 15, length: 0)
        )
        if case .continueList(let text) = result {
            XCTAssertEqual(text, "\n100. ")
        } else {
            XCTFail("Expected .continueList for item 99")
        }
    }

    func testTerminateListOnEmptyItem() {
        let storage = NSTextStorage(string: "1. First\n2. ")
        let cursorLocation = 12 // after "2. "
        let result = ListFormattingEngine.handleEnterKey(
            textStorage: storage,
            selectedRange: NSRange(location: cursorLocation, length: 0)
        )
        if case .terminateList(let range) = result {
            XCTAssertTrue(range.length > 0, "Should return the paragraph range to remove")
        } else {
            XCTFail("Expected .terminateList for empty list item, got \(result)")
        }
    }

    func testPassthroughWhenCursorInsideMarker() {
        let storage = NSTextStorage(string: "1. Hello")
        // Cursor inside the "1. " marker (before the space)
        let result = ListFormattingEngine.handleEnterKey(
            textStorage: storage,
            selectedRange: NSRange(location: 1, length: 0)
        )
        if case .passthrough = result {
            // Expected: cursor before marker end, so passthrough
        } else {
            XCTFail("Expected .passthrough when cursor is inside the marker")
        }
    }

    // MARK: - Paragraph Style Creation

    func testListParagraphStyleHasHangingIndent() {
        let config = ListFormattingEngine.Config.default
        let style = ListFormattingEngine.listParagraphStyle(for: "1. ", config: config)
        XCTAssertGreaterThan(style.headIndent, 0, "List style should have a hanging indent")
        XCTAssertEqual(style.firstLineHeadIndent, 0)
        XCTAssertEqual(style.lineSpacing, config.lineSpacing)
    }

    func testDefaultParagraphStyleHasNoIndent() {
        let config = ListFormattingEngine.Config.default
        let style = ListFormattingEngine.defaultParagraphStyle(config: config)
        XCTAssertEqual(style.headIndent, 0)
        XCTAssertEqual(style.firstLineHeadIndent, 0)
        XCTAssertEqual(style.lineSpacing, config.lineSpacing)
    }

    func testLargerMarkerProducesLargerIndent() {
        let config = ListFormattingEngine.Config.default
        let smallStyle = ListFormattingEngine.listParagraphStyle(for: "1. ", config: config)
        let largeStyle = ListFormattingEngine.listParagraphStyle(for: "999. ", config: config)
        XCTAssertGreaterThan(largeStyle.headIndent, smallStyle.headIndent,
                             "Wider marker text should produce larger headIndent")
    }
}
