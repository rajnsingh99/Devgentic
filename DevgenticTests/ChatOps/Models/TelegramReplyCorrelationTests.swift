// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramReplyCorrelationTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class TelegramReplyCorrelationTests: XCTestCase {

    /// ⚠️ THE DATA WAS ALWAYS ARRIVING AND WAS ALWAYS DISCARDED. `TelegramMessage` decoded five
    /// fields and `reply_to_message` was not one of them, and `Codable` ignores unknown keys in
    /// silence — so the one thing that could correlate an answer to its question was thrown away at
    /// the parse boundary, invisibly.
    ///
    /// Mutation that must turn this red: remove `reply_to_message` from `TelegramMessage`.
    func testAReplyCarriesTheMessageItAnswers() throws {
        // Shaped like a real Telegram update, including keys this build does not model.
        let json = """
        {
          "message_id": 4321,
          "from": {"id": 99, "is_bot": false, "first_name": "Raj"},
          "chat": {"id": -100200, "type": "private"},
          "date": 1717171717,
          "text": "the second one",
          "reply_to_message": {
            "message_id": 4310,
            "from": {"id": 1, "is_bot": true, "first_name": "Devgentic"},
            "chat": {"id": -100200, "type": "private"},
            "date": 1717171700,
            "text": "💬 Agent needs clarification:\\n\\nWhich file?"
          }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(TelegramMessage.self, from: json)
        XCTAssertEqual(message.text, "the second one")
        XCTAssertEqual(message.reply_to_message?.message_id, 4310, """
            Without this id there is nothing on the wire naming WHICH clarification is being \
            answered, and correlation falls back to the provider cursor.
            """)
    }

    /// ⚠️ THE OBVIOUS SPELLING DOES NOT COMPILE. `let reply_to_message: TelegramMessage?` is a
    /// recursive value type and Swift rejects it outright, which is why a flattened reference type
    /// exists. This pins the shape so nobody "simplifies" it back into a compile error — or, worse,
    /// concludes the data is unavailable and reverts to cursor-derived correlation.
    func testTheReplyReferenceIsFlattenedRatherThanRecursive() throws {
        let json = #"{"message_id": 7}"#.data(using: .utf8)!
        let reference = try JSONDecoder().decode(TelegramReplyReference.self, from: json)
        XCTAssertEqual(reference.message_id, 7)
    }

    /// ⚠️ `selective` targets ONLY users @mentioned in the message text, or — when the bot's message
    /// is itself a reply — the original sender. A mirrored clarification prompt is neither, so
    /// `selective: true` would force the reply box for nobody and the whole affordance would
    /// silently do nothing.
    ///
    /// Mutation that must turn this red: set `selective` to true.
    func testForceReplyIsNotSelectiveOrItWouldTargetNobody() throws {
        let force = ForceReply(placeholder: "Your answer…")
        XCTAssertTrue(force.force_reply)
        XCTAssertFalse(force.selective)

        let encoded = try JSONEncoder().encode(force)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["force_reply"] as? Bool, true)
        XCTAssertEqual(object["selective"] as? Bool, false)
        XCTAssertEqual(object["input_field_placeholder"] as? String, "Your answer…")
    }

    /// Telegram caps the placeholder at 64 characters and rejects the whole send otherwise.
    func testThePlaceholderIsTruncatedToTelegramsLimit() {
        let force = ForceReply(placeholder: String(repeating: "a", count: 200))
        XCTAssertEqual(force.input_field_placeholder?.count, 64)
    }

    /// ⚠️ A `ForceReply` must survive the type-erased markup encoding as a BARE object, not wrapped
    /// in a discriminator — `SendMessagePayload.ReplyMarkup` encodes through a single-value
    /// container precisely so Telegram sees the shape it documents.
    func testForceReplyEncodesAsABareObjectOnTheWire() throws {
        let payload = SendMessagePayload(
            chat_id: 1, text: "hi", parse_mode: nil,
            reply_markup: .forceReply(ForceReply(placeholder: "Your answer…"))
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(payload)) as? [String: Any])
        let markup = try XCTUnwrap(object["reply_markup"] as? [String: Any])
        XCTAssertEqual(markup["force_reply"] as? Bool, true,
                       "Telegram reads `force_reply` off the markup object itself")
    }
}
