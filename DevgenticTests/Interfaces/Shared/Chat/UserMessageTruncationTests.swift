//
//  UserMessageTruncationTests.swift
//  DevgenticTests
//
//  CF-1 (Chat_Production_Readiness_Fresh.md): a newline-dense user message under ~850
//  characters was clipped at 10 lines with NO expand chevron. `UserMessageView`'s
//  truncation fast path reasoned purely about character count — `text.count <
//  lineLimit * max(40, width / 7)` — and never looked at newlines, so a 12-line,
//  300-character paste skipped the NSHostingView measurement, was set
//  `isTruncatable = false`, and `.lineLimit(10)` clipped it with no affordance.
//
//  The decision now lives in `UserMessageView.needsMeasurement(text:availableWidth:fontSize:lineLimit:)`
//  (nonisolated static, pure) so it can be pinned here without a view host. It may only
//  answer `false` ("definitely fits, skip measuring") when BOTH the character budget AND
//  the hard-line-break count agree. These tests fail against the old character-only rule:
//  the 12-line string is 300 characters, comfortably under any width's character budget.
//
//  Not covered here (SwiftUI plumbing, needs an on-device check): the `.onChange` re-measure
//  on width / `chatFontSize` changes that replaced the `onAppear`-only trigger.
//

import XCTest
@testable import devgentic

final class UserMessageTruncationTests: XCTestCase {

    /// The view's collapsed limit (`lineLimitCollapsed = 10`).
    private let lineLimit = 10
    /// A typical chat bubble width. At the default 14pt font the estimated per-glyph advance
    /// is 7pt, so capacity is ~85 characters per line.
    private let bubbleWidth: CGFloat = 600
    /// `ThemeManager.chatFontSize`'s default.
    private let defaultFontSize: CGFloat = 14

    /// The rule under test, with the view's own defaults filled in.
    private func needs(text: String, availableWidth: CGFloat,
                       fontSize: CGFloat? = nil, lineLimit: Int? = nil) -> Bool {
        UserMessageView.needsMeasurement(text: text, availableWidth: availableWidth,
                                         fontSize: fontSize ?? defaultFontSize,
                                         lineLimit: lineLimit ?? self.lineLimit)
    }

    /// Builds `lines` short lines joined by `separator` — short enough that the whole
    /// string stays far below the character budget at any width.
    private func tallText(lines: Int, separator: String = "\n") -> String {
        (0..<lines).map { "line \($0) of a short but tall paste" }.joined(separator: separator)
    }

    // MARK: - The CF-1 shape

    /// The register's exact failure: 12 lines, ~300 characters. The character heuristic
    /// says "short"; the newline count says "taller than the limit". Must measure.
    func test_twelveShortLines_needsMeasurement_despiteBeingUnderTheCharacterBudget() {
        let text = tallText(lines: 12)
        XCTAssertLessThan(text.count, lineLimit * max(40, Int(bubbleWidth / 7)),
                          "fixture must sit inside the character budget or it does not exercise the fast path")
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth),
                      "a 12-line paste can only be clipped at 10 lines if it is never measured")
    }

    /// The fast path is still a fast path: a single 300-character line cannot reach 10
    /// lines at 600pt, so it must NOT trigger the two NSHostingView measurements.
    func test_singleLine300Chars_doesNotNeedMeasurement() {
        let text = String(repeating: "x", count: 300)
        XCTAssertFalse(needs(text: text, availableWidth: bubbleWidth))
    }

    /// Long-by-characters text needs measuring regardless of newlines — the character
    /// half of the rule is unchanged from before.
    func test_oneLongParagraph_needsMeasurement() {
        let text = String(repeating: "word ", count: 400) // 2,000 chars, zero newlines
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth))
    }

    // MARK: - Boundary at the line limit

    /// `lineLimit - 1` hard breaks is exactly `lineLimit` lines — it fits, no measurement.
    func test_lineLimitMinusOneBreaks_doesNotNeedMeasurement() {
        let text = tallText(lines: lineLimit) // 10 lines ⇒ 9 newlines
        XCTAssertEqual(text.filter(\.isNewline).count, lineLimit - 1)
        XCTAssertFalse(needs(text: text, availableWidth: bubbleWidth))
    }

    /// `lineLimit` hard breaks is `lineLimit + 1` lines — one over, must measure.
    func test_lineLimitBreaks_needsMeasurement() {
        let text = tallText(lines: lineLimit + 1) // 11 lines ⇒ 10 newlines
        XCTAssertEqual(text.filter(\.isNewline).count, lineLimit)
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth))
    }

    /// Trailing newline pastes are common: 10 lines plus a trailing "\n" is 10 hard breaks.
    /// Whether Text renders that as an 11th (empty) line is the measurement's call — the
    /// rule's job is only to send it to measurement.
    func test_trailingNewline_countsAsABreak() {
        let text = tallText(lines: lineLimit) + "\n"
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth))
    }

    // MARK: - Line-ending and width edge cases

    /// Windows line endings: "\r\n" is ONE `Character` and one break, not two. 12 lines
    /// with CRLF must still need measuring; 10 lines with CRLF must still not.
    func test_crlfLineEndings_countOneBreakPerLine() {
        XCTAssertTrue(needs(text: tallText(lines: 12, separator: "\r\n"),
                                                       availableWidth: bubbleWidth, lineLimit: lineLimit))
        XCTAssertFalse(needs(text: tallText(lines: lineLimit, separator: "\r\n"),
                                                        availableWidth: bubbleWidth, lineLimit: lineLimit))
    }

    /// A degenerate width must fail SAFE. Capacity floors at 1 character per line, so almost
    /// anything is assumed tall and gets measured — the expensive answer, but never the wrong
    /// one. (The old rule floored the *budget* at 40 chars/line and returned "fits" for a
    /// 300-character line at width 0, i.e. it guessed in the direction that clips content.)
    func test_zeroWidth_failsSafeTowardMeasuring() {
        XCTAssertTrue(needs(text: String(repeating: "x", count: 300), availableWidth: 0))
        XCTAssertFalse(needs(text: "short", availableWidth: 0),
                       "Still under the limit at one character per line: 5 characters is 5 lines.")
    }

    /// Empty text is trivially not truncatable.
    func test_emptyText_doesNotNeedMeasurement() {
        XCTAssertFalse(needs(text: "", availableWidth: bubbleWidth))
    }

    // MARK: - Wrapping and font size (the second CF-1 pass)

    /// ⚠️ The case the first fix missed. Eight 100-character lines: 807 characters (inside the
    /// old 850-character budget) and 7 hard breaks (inside the 10-line limit), so BOTH halves of
    /// the old rule said "fits" — while the text actually lays out as ~16 lines and was clipped
    /// with no chevron. Only per-segment wrapping catches it.
    func test_fewLongLines_needMeasurement_becauseEachSegmentWraps() {
        let text = (0..<8).map { _ in String(repeating: "x", count: 100) }.joined(separator: "\n")
        XCTAssertEqual(text.count, 807)
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth),
                      "85 chars/line ⇒ each 100-char segment is 2 lines ⇒ 16 lines, past the 10-line limit.")
    }

    /// The register's own aggravation, now actually pinned: raising the chat font makes a message
    /// that fitted at 14pt no longer fit. Same text, same width, different answer — which is what
    /// makes the view's `.onChange(of: chatFontSize)` re-measure worth having.
    func test_raisingTheFontSize_turnsAFittingMessageIntoATallOne() {
        let text = String(repeating: "x", count: 700)
        XCTAssertFalse(needs(text: text, availableWidth: bubbleWidth, fontSize: 14),
                       "600/7 = 85 per line ⇒ ~9 lines ⇒ fits.")
        XCTAssertTrue(needs(text: text, availableWidth: bubbleWidth, fontSize: 22),
                      "600/11 = 54 per line ⇒ ~13 lines ⇒ must measure.")
    }

    /// A segment exactly filling its line must not be rounded up to two.
    func test_segmentExactlyFillingTheLine_countsAsOneLine() {
        let perLine = Int(bubbleWidth / 7)          // 85
        let text = (0..<9).map { _ in String(repeating: "x", count: perLine) }.joined(separator: "\n")
        XCTAssertFalse(needs(text: text, availableWidth: bubbleWidth),
                       "Nine segments of exactly one line each is nine lines, inside the limit.")
    }

    /// Empty segments still occupy a line — ten blank lines is ten lines.
    func test_blankLinesOccupyLines() {
        XCTAssertTrue(needs(text: String(repeating: "\n", count: 10), availableWidth: bubbleWidth))
        XCTAssertFalse(needs(text: String(repeating: "\n", count: 8), availableWidth: bubbleWidth))
    }
}
