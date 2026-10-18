// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteTextBudgetTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RemoteTextBudgetTests: XCTestCase {

    /// A transcript line the size `/history` really produces: a 200-character preview, its ellipsis,
    /// and the sender icon.
    private func transcriptLine(_ index: Int) -> Notice.Field {
        Notice.Field(value: "👤 " + String(repeating: "x", count: 200) + "…")
    }

    private func history(turns: Int) -> Notice {
        Notice(
            tone: .info,
            icon: "🕘",
            title: "Last \(turns) message(s):",
            fields: [.spacer] + (0..<turns).map(transcriptLine)
        )
    }

    // MARK: - The defect

    /// ⚠️⚠️ THE REGRESSION TEST FOR THE ACTUAL BUG. `/history 20` is the documented maximum and it
    /// exceeded every platform's cap. Each renderer must now produce something the platform will
    /// accept, on its OWN limit — Discord's 2000 is less than half Telegram's 4096, and a single
    /// shared bound would have hidden that.
    ///
    /// Mutation that must turn this red: drop `limit:` from any `NoticeText.build` call site, or
    /// return `joined` unconditionally from `RemoteTextBudget.fit(lines:limit:)`.
    func testTheDocumentedHistoryMaximumFitsEveryPlatform() {
        let notice = history(turns: ChatOpsCommandService.historyMaxCount)

        let telegram = TelegramRemoteRenderer.draft(for: .notice(notice))?.text ?? ""
        let discord = DiscordRemoteRenderer.draft(for: .notice(notice))?.content ?? ""
        let slack = SlackRemoteRenderer.draft(for: .notice(notice))?.text ?? ""

        XCTAssertLessThanOrEqual(telegram.utf16.count, RemoteCapabilities.telegram.maxMessageLength,
                                 "Telegram rejects the whole message above 4096 — the reply would not arrive")
        XCTAssertLessThanOrEqual(discord.utf16.count, RemoteCapabilities.discord.maxMessageLength,
                                 "Discord's content cap is 2000, and ten 200-character turns already clear it")
        XCTAssertLessThanOrEqual(slack.utf16.count, RemoteCapabilities.slack.maxMessageLength,
                                 "a section block's text cap is 3000, not chat.postMessage's 40000")
    }

    /// ⚠️ THE SLACK BLOCK, NOT JUST THE FALLBACK TEXT. Slack puts the same string in both, and the
    /// block is the one with the tighter limit — bounding only `text` would still be rejected.
    func testSlackBoundsTheBlockAndNotOnlyTheFallbackText() throws {
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: .notice(history(turns: 20))))
        let blocks = try XCTUnwrap(draft.blocks)
        let encoded = try JSONEncoder().encode(blocks)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        // The section text travels inside the block; if it were unbounded the encoded blob would
        // carry the full ~4100 characters even though `draft.text` was trimmed.
        XCTAssertLessThan(json.utf16.count, RemoteCapabilities.slack.maxMessageLength + 500,
                          "the section block still carries the untrimmed transcript")
    }

    // MARK: - How it degrades

    /// ⚠️ WHOLE LINES, AND THE USER IS TOLD. Cutting mid-sentence reads as corruption; a transcript
    /// silently missing its oldest turns reads as "that is all there is".
    ///
    /// Mutation that must turn this red: drop the marker line from `fit(lines:limit:)`.
    func testDroppedLinesAreCountedInTheMessage() {
        let lines = (0..<40).map { _ in String(repeating: "y", count: 100) }
        let fitted = RemoteTextBudget.fit(lines: lines, limit: 1000)

        XCTAssertLessThanOrEqual(fitted.utf16.count, 1000)
        XCTAssertTrue(fitted.contains("did not fit"), "a silent truncation is the lie this replaces")
        XCTAssertTrue(fitted.contains("more lines"), "the count of what went is part of the message")
        // Kept lines are intact, never half a line.
        for line in fitted.components(separatedBy: "\n") where line.hasPrefix("y") {
            XCTAssertEqual(line.count, 100, "a kept line was cut in half")
        }
    }

    /// Nothing is touched when it already fits — the common case must stay byte-identical.
    ///
    /// Mutation that must turn this red: always append the marker.
    func testTextThatFitsIsUnchanged() {
        let lines = ["one", "two", "three"]
        XCTAssertEqual(RemoteTextBudget.fit(lines: lines, limit: 4096), "one\ntwo\nthree")
        XCTAssertEqual(RemoteTextBudget.fit("short", limit: 4096), "short")
    }

    /// ⚠️ ONE LINE CAN EXCEED THE WHOLE BUDGET — a single long agent reply. There is then nothing to
    /// keep, and the line-dropping path must fall back to a hard bound rather than returning the
    /// oversized text or an empty string.
    func testASingleOversizedLineIsStillBounded() {
        let fitted = RemoteTextBudget.fit(lines: [String(repeating: "z", count: 9000)], limit: 2000)
        XCTAssertLessThanOrEqual(fitted.utf16.count, 2000)
        XCTAssertFalse(fitted.isEmpty, "the reply must still say something")
    }

    /// ⚠️ MEASURED IN UTF-16, because the platforms do not count graphemes. An emoji-dense
    /// transcript measures 1 per emoji under `String.count` and 2 under UTF-16; using the former
    /// would let a message that Telegram rejects pass this floor.
    func testEmojiAreMeasuredTheWayThePlatformCountsThem() {
        let emoji = String(repeating: "🕘", count: 3000)   // 3000 graphemes, 6000 UTF-16 units
        XCTAssertLessThanOrEqual(RemoteTextBudget.fit(emoji, limit: 4096).utf16.count, 4096)
    }

    // MARK: - The prompt arms

    /// ⚠️ THE ARM THAT MATTERS MOST. A `planReview` list is model-generated and unbounded, and a
    /// prompt the platform rejects leaves the run PARKED with no buttons anywhere remote — worse
    /// than a truncated prompt, because the buttons are what resolve it.
    ///
    /// Mutation that must turn this red: remove `fit(...)` from any prompt arm.
    func testAnOversizedPlanReviewStillPostsItsButtons() throws {
        let subtasks = (0..<200).map { "Step \($0): " + String(repeating: "w", count: 120) }
        let kind = HITLType.planReview(subtaskDescriptions: subtasks)
        let operationID = UUID()

        let telegram = TelegramRemoteRenderer.promptDraft(operationID: operationID, kind: kind)
        let discord = DiscordRemoteRenderer.promptDraft(operationID: operationID, kind: kind)
        let slack = SlackRemoteRenderer.promptDraft(operationID: operationID, kind: kind)

        XCTAssertLessThanOrEqual(telegram.text.utf16.count, RemoteCapabilities.telegram.maxMessageLength)
        XCTAssertLessThanOrEqual(discord.content.utf16.count, RemoteCapabilities.discord.maxMessageLength)
        XCTAssertLessThanOrEqual(slack.text.utf16.count, RemoteCapabilities.slack.maxMessageLength)

        XCTAssertNotNil(telegram.reply_markup, "the approve/reject buttons must survive the trim")
        XCTAssertFalse(discord.components?.isEmpty ?? true)
        XCTAssertFalse(slack.blocks?.isEmpty ?? true)
    }

    /// A gate's prompt is user- and model-supplied too, and its options are what answer it.
    func testAnOversizedGatePromptStillPostsItsOptions() {
        let kind = HITLType.gate(prompt: String(repeating: "g", count: 8000), options: ["yes", "no"])
        let draft = DiscordRemoteRenderer.promptDraft(operationID: UUID(), kind: kind)
        XCTAssertLessThanOrEqual(draft.content.utf16.count, RemoteCapabilities.discord.maxMessageLength)
        XCTAssertFalse(draft.components?.isEmpty ?? true, "the option buttons are the whole point")
    }

    /// ⚠️ A CHOOSER HEADING CARRIES USER TEXT — `/search <query>` puts the query in it verbatim, and
    /// a rejected heading takes the entire button list with it.
    func testALongSearchQueryDoesNotSinkItsResults() throws {
        let chooser = Chooser(
            icon: "🔍",
            title: "Matching “" + String(repeating: "q", count: 5000) + "”:",
            options: [Chooser.Option(label: "A conversation", token: .switchConversation(UUID()))]
        )
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: .chooser(chooser)))
        XCTAssertLessThanOrEqual(draft.content.utf16.count, RemoteCapabilities.discord.maxMessageLength)
        XCTAssertFalse(draft.components?.isEmpty ?? true, "the results must survive a long query")
    }

    // MARK: - The button capacity

    private func chooser(options: Int, extras: Int) -> Chooser {
        Chooser(
            icon: "📋",
            title: "Your Conversations:",
            options: (0..<options).map { Chooser.Option(label: "Conversation \($0)", token: .switchConversation(UUID())) },
            extraActions: (0..<extras).map { Chooser.Option(label: "Extra \($0)", token: .action(.new)) }
        )
    }

    /// ⚠️⚠️ `exceedsCapacity` HAD TESTS AND NO PRODUCTION CALLER — a policy proven correct in
    /// isolation while nothing consulted it, which is the shape that ships a dead feature behind a
    /// green suite. This is the test that fails if the renderers stop asking.
    ///
    /// Discord accepts at most 5 ActionRows of 5, and rejects the message outright above them — so
    /// an untrimmed 40-option chooser did not render 40 buttons, it rendered NOTHING.
    ///
    /// Mutation that must turn this red: go back to `chooser.options + chooser.extraActions`.
    func testAnOversizedChooserIsTrimmedToWhatThePlatformAccepts() throws {
        let big = chooser(options: 40, extras: 3)

        let discord = try XCTUnwrap(DiscordRemoteRenderer.draft(for: .chooser(big)))
        let buttons = (discord.components ?? []).reduce(0) { $0 + ($1.components?.count ?? 0) }
        XCTAssertLessThanOrEqual(buttons, RemoteCapabilities.discord.maxButtons,
                                 "Discord rejects a message above 5 ActionRows — an untrimmed chooser arrives as nothing at all")

        let slack = try XCTUnwrap(SlackRemoteRenderer.draft(for: .chooser(big)))
        let elements = (slack.blocks ?? []).reduce(0) { total, block in
            let encoded = (try? JSONEncoder().encode(block)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return total + encoded.components(separatedBy: "\"type\":\"button\"").count - 1
        }
        XCTAssertLessThanOrEqual(elements, RemoteCapabilities.slack.maxButtons)
    }

    /// ⚠️⚠️ THE EXTRAS SURVIVE, THE OPTIONS ARE TRIMMED. `extraActions` holds "◂ Previous",
    /// "Next ▸" and "➕ New Conversation" — the controls that reach the very rows being dropped.
    /// Trimming uniformly would take away the route along with the destination.
    ///
    /// Mutation that must turn this red: trim `all` after concatenating, instead of trimming
    /// options and appending extras.
    func testPagingControlsSurviveTheTrim() throws {
        let big = chooser(options: 40, extras: 3)
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: .chooser(big)))
        let encoded = try JSONEncoder().encode(draft.components)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        for extra in ["Extra 0", "Extra 1", "Extra 2"] {
            XCTAssertTrue(json.contains(extra), "\(extra) was trimmed away — the user cannot reach the dropped rows")
        }
    }

    /// ⚠️ AND THE USER IS TOLD. A list silently showing 22 of 40 reads as "that is all there is" —
    /// the same lie `/search`'s scan bound and the transcript budget both disclose.
    ///
    /// Mutation that must turn this red: return `nil` for the note in `ChooserContent.resolve`.
    func testTheTrimIsDisclosedInTheHeading() throws {
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: .chooser(chooser(options: 40, extras: 3))))
        XCTAssertTrue(draft.content.contains("did not fit"),
                      "a silently truncated list reads as a complete one")
        XCTAssertTrue(draft.content.contains("of 40"), "the real total must appear, not just the shown count")
    }

    /// A chooser that already fits must be untouched — every shipped list is ten or fewer, so this
    /// is the path that actually runs in production.
    ///
    /// Mutation that must turn this red: always append the note.
    func testAChooserThatFitsIsUnchanged() throws {
        let small = chooser(options: 10, extras: 3)
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: .chooser(small)))
        XCTAssertFalse(draft.content.contains("did not fit"), "a list that fits must not claim it was trimmed")
        let buttons = (draft.components ?? []).reduce(0) { $0 + ($1.components?.count ?? 0) }
        XCTAssertEqual(buttons, 13, "every option and extra must render when they fit")
    }

    /// ⚠️ TELEGRAM ALLOWS 100 BUTTONS, so the same chooser must NOT be trimmed there. A single
    /// shared cap would have quietly degraded the platform with the most headroom.
    func testTelegramIsNotTrimmedToDiscordsLimit() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: .chooser(chooser(options: 40, extras: 3))))
        guard case .inline(let keyboard)? = draft.reply_markup else {
            return XCTFail("expected an inline keyboard")
        }
        XCTAssertEqual(keyboard.inline_keyboard.reduce(0) { $0 + $1.count }, 43,
                       "Telegram accepts 100 buttons; trimming it to Discord's 25 loses actions for no reason")
        XCTAssertFalse(draft.text.contains("did not fit"))
    }
}
