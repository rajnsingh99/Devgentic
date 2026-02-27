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

    /// Result of handling an Enter key press in a list context.
    enum EnterAction {
        /// No list context — let the caller handle normally (e.g. send message).
        case passthrough
        /// Insert the next numbered item (e.g. "\n2. ").
        case continueList(insertionText: String)
        /// The list item was empty — remove the marker and end the list.
        case terminateList(paragraphRange: NSRange)
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
            return .terminateList(paragraphRange: paragraphRange)
        }

        let nextNumber = number + 1
        return .continueList(insertionText: "\n\(nextNumber). ")
    }
}
