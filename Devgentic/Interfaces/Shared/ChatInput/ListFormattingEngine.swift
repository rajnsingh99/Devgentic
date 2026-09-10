// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ListFormattingEngine.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import AppKit

/// Detects numbered list patterns and applies formatting in a ChatInput NSTextView.
/// Stateless utility — all context comes from method parameters.
final class ListFormattingEngine {

    // MARK: - Configuration

    struct Config {
        let font: NSFont
        let lineSpacing: CGFloat

        static let `default` = Config(
            font: .systemFont(ofSize: 14),
            lineSpacing: 4
        )
    }

    // MARK: - Pattern

    /// Matches "1. ", "2. ", "10. " etc. at the start of a line.
    /// Group 1 = the number string (e.g. "1").
    private static let numberedListPattern = try! NSRegularExpression(
        pattern: #"^(\d+)\.\s"#,
        options: []
    )

    // MARK: - Detection

    /// Returns (number, markerRange) if the given paragraph starts with a numbered list marker.
    static func detectListItem(in string: NSString, paragraphRange: NSRange) -> (number: Int, markerRange: NSRange)? {
        let match = numberedListPattern.firstMatch(
            in: string as String,
            options: [],
            range: paragraphRange
        )
        guard let match,
              let number = Int(string.substring(with: match.range(at: 1))) else {
            return nil
        }
        return (number, match.range)
    }

    /// Returns true if the paragraph contains ONLY a list marker with no user content.
    /// e.g. "3. " with nothing after it (or just trailing whitespace).
    static func isEmptyListItem(in string: NSString, paragraphRange: NSRange) -> Bool {
        guard let (_, markerRange) = detectListItem(in: string, paragraphRange: paragraphRange) else {
            return false
        }
        let afterMarkerLocation = markerRange.location + markerRange.length
        let afterMarkerLength = (paragraphRange.location + paragraphRange.length) - afterMarkerLocation
        guard afterMarkerLength > 0 else { return true }
        let trailing = string.substring(with: NSRange(location: afterMarkerLocation, length: afterMarkerLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trailing.isEmpty
    }

    // MARK: - Paragraph Style Creation

    /// Builds an NSParagraphStyle with hanging indent appropriate for a numbered list item.
    /// The `headIndent` is set so wrapped lines align with the text after "N. ".
    static func listParagraphStyle(for markerText: String, config: Config) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = config.lineSpacing
        let markerWidth = (markerText as NSString).size(withAttributes: [.font: config.font]).width
        style.headIndent = ceil(markerWidth) + 2
        style.firstLineHeadIndent = 0
        return style
    }

    /// Returns the default (non-list) paragraph style.
    static func defaultParagraphStyle(config: Config) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = config.lineSpacing
        style.headIndent = 0
        style.firstLineHeadIndent = 0
        return style
    }

    // MARK: - Enter Key Handling

    /// One marker rewrite needed to keep a list sequential after an item is inserted or
    /// removed. `range` addresses ONLY the digits — so the item's original separator
    /// (". ", ".\t", …) survives untouched — and is expressed in the ORIGINAL string's
    /// coordinates.
    struct Renumbering: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// Result of handling an Enter key press in a list context.
    ///
    /// Both mutating cases carry `renumbering`: the rewrites for the items that FOLLOW,
    /// so a mid-list edit doesn't leave duplicate or gapped numbers. The edits are
    /// ordered LAST-first and every range sits after the edit point, so a caller applies
    /// them as-is (then does its own insertion/removal) with no offset arithmetic.
    enum EnterAction {
        /// No list context — let the caller handle normally (e.g. send message).
        case passthrough
        /// Insert the next numbered item (e.g. "\n2. ") and resequence what follows.
        case continueList(insertionText: String, renumbering: [Renumbering])
        /// The list item was empty — remove the marker, end the list, resequence what follows.
        case terminateList(paragraphRange: NSRange, renumbering: [Renumbering])
    }

    /// Determines what should happen when the user presses Enter.
    static func handleEnterKey(textStorage: NSTextStorage, selectedRange: NSRange) -> EnterAction {
        let string = textStorage.string as NSString
        let cursorLocation = selectedRange.location

        let paragraphRange = string.paragraphRange(for: NSRange(location: cursorLocation, length: 0))

        guard let (number, markerRange) = detectListItem(in: string, paragraphRange: paragraphRange) else {
            return .passthrough
        }

        // Cursor must be after the marker (not editing within "1. " itself)
        if cursorLocation < markerRange.location + markerRange.length {
            return .passthrough
        }

        if isEmptyListItem(in: string, paragraphRange: paragraphRange) {
            // This item is being removed, so the items after it slide up to take its number.
            return .terminateList(
                paragraphRange: paragraphRange,
                renumbering: renumberingAfter(paragraphRange: paragraphRange, in: string, continuingFrom: number)
            )
        }

        let nextNumber = number + 1
        return .continueList(
            insertionText: "\n\(nextNumber). ",
            // The new item takes `nextNumber`, so everything after it starts one higher.
            renumbering: renumberingAfter(paragraphRange: paragraphRange, in: string, continuingFrom: nextNumber + 1)
        )
    }

    // MARK: - Renumbering

    /// Like `detectListItem`, but yields the range of just the digits — the part a
    /// renumber rewrites (leaving the separator alone).
    private static func detectNumber(in string: NSString, paragraphRange: NSRange) -> (number: Int, digitsRange: NSRange)? {
        guard let match = numberedListPattern.firstMatch(in: string as String, options: [], range: paragraphRange),
              let number = Int(string.substring(with: match.range(at: 1))) else {
            return nil
        }
        return (number, match.range(at: 1))
    }

    /// Rewrites for the contiguous numbered items FOLLOWING `paragraphRange`, so they run
    /// sequentially from `firstNumber`. Stops at the first paragraph that isn't a numbered
    /// item (blank line, prose, end of text) — that's where the list ends, and a separate
    /// list further down must not be renumbered. Items already correct produce no edit, so
    /// appending at the end of a list yields an empty array and costs nothing.
    ///
    /// Returned LAST-first: applying in that order keeps every later range valid even when
    /// a rewrite changes width (e.g. "9" → "10").
    static func renumberingAfter(paragraphRange: NSRange, in string: NSString, continuingFrom firstNumber: Int) -> [Renumbering] {
        var edits: [Renumbering] = []
        var expected = firstNumber
        var location = paragraphRange.location + paragraphRange.length

        while location < string.length {
            let para = string.paragraphRange(for: NSRange(location: location, length: 0))
            guard let (number, digitsRange) = detectNumber(in: string, paragraphRange: para) else { break }
            if number != expected {
                edits.append(Renumbering(range: digitsRange, replacement: String(expected)))
            }
            expected += 1
            let next = para.location + para.length
            guard next > location else { break }   // defensive: never spin on a zero-length paragraph
            location = next
        }

        return edits.reversed()
    }
}
