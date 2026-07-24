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
        if case .continueList(let text, let renumbering) = result {
            XCTAssertEqual(text, "\n2. ", "Should insert next numbered item")
            XCTAssertTrue(renumbering.isEmpty, "Appending at the end of a list renumbers nothing")
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
        if case .continueList(let text, _) = result {
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
        if case .terminateList(let range, _) = result {
            XCTAssertTrue(range.length > 0, "Should return the paragraph range to remove")
        } else {
            XCTFail("Expected .terminateList for empty list item, got \(result)")
        }
    }

    // MARK: - Renumbering (C5)
    //
    // Enter used to derive the next number from the CURRENT paragraph alone, so inserting
    // mid-list produced a duplicate ("1. a / 2. NEW / 2. b") and left everything after it
    // stale. `handleEnterKey` now also returns the rewrites for the items that follow.

    /// Applies an EnterAction the way the Coordinator does — renumber edits first
    /// (last-first, original coordinates, all after the edit point), then insert/remove.
    private func applyEnter(_ text: String, at cursor: Int) -> String {
        let storage = NSTextStorage(string: text)
        switch ListFormattingEngine.handleEnterKey(textStorage: storage, selectedRange: NSRange(location: cursor, length: 0)) {
        case .passthrough:
            return text
        case .continueList(let insertion, let renumbering):
            for e in renumbering { storage.replaceCharacters(in: e.range, with: e.replacement) }
            storage.replaceCharacters(in: NSRange(location: cursor, length: 0), with: insertion)
        case .terminateList(let paragraphRange, let renumbering):
            for e in renumbering { storage.replaceCharacters(in: e.range, with: e.replacement) }
            storage.replaceCharacters(in: paragraphRange, with: "")
        }
        return storage.string
    }

    func testInsertingMidListResequencesFollowingItems() {
        XCTAssertEqual(applyEnter("1. a\n2. b\n3. c", at: 4), "1. a\n2. \n3. b\n4. c")
    }

    func testInsertingIntoTheMiddleOfALongerRun() {
        XCTAssertEqual(applyEnter("1. a\n2. b\n3. c\n4. d", at: 9), "1. a\n2. b\n3. \n4. c\n5. d")
    }

    /// A rewrite that WIDENS the marker (9 → 10) shifts everything after it. Edits are
    /// applied last-first precisely so the earlier ranges stay valid through that.
    func testRenumberingHandlesWidthChange() {
        XCTAssertEqual(applyEnter("8. h\n9. i", at: 4), "8. h\n9. \n10. i")
    }

    /// A blank line ends the list — a separate list below must keep its own numbering.
    func testRenumberingStopsAtBlankLineAndLeavesTheNextListAlone() {
        XCTAssertEqual(applyEnter("1. a\n2. b\n\n1. other", at: 4), "1. a\n2. \n3. b\n\n1. other")
    }

    func testRenumberingStopsAtProse() {
        XCTAssertEqual(applyEnter("1. a\n2. b\nplain text", at: 4), "1. a\n2. \n3. b\nplain text")
    }

    /// Terminating an empty item in the MIDDLE closes the gap it would otherwise leave.
    func testTerminatingMidListClosesTheNumberingGap() {
        XCTAssertEqual(applyEnter("1. a\n2. \n3. b", at: 8), "1. a\n2. b")
    }

    /// Already-sequential items need no rewriting at all — the common append case stays free.
    func testNoEditsWhenListIsAlreadySequential() {
        let storage = NSTextStorage(string: "1. a\n2. b")
        let edits = ListFormattingEngine.renumberingAfter(
            paragraphRange: (storage.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)),
            in: storage.string as NSString,
            continuingFrom: 2
        )
        XCTAssertTrue(edits.isEmpty)
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
