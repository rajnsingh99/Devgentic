// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteMentionSuppressionTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RemoteMentionSuppressionTests: XCTestCase {

    // MARK: - Discord: the payload carries the policy

    /// ⚠️ THE ENCODED BYTES, not the Swift value — the field only protects anything if it reaches
    /// Discord. `parse: []` is "resolve no mention type at all".
    func testEveryDiscordMessageSuppressesMentionsOnTheWire() throws {
        let json = try encoded(DiscordCreateMessagePayload(content: "@everyone ship it", components: nil))
        XCTAssertNotNil(json["allowed_mentions"], "a message with no allowed_mentions mass-pings the server")
        let parse = try XCTUnwrap((json["allowed_mentions"] as? [String: Any])?["parse"] as? [String])
        XCTAssertTrue(parse.isEmpty, "parse must be empty — any non-empty value resolves that mention type")
    }

    /// Edits carry model-supplied text too: a mirrored HITL prompt is edited in place on resolution.
    func testEveryDiscordEditSuppressesMentionsOnTheWire() throws {
        let json = try encoded(DiscordEditMessagePayload(content: "@here done", components: nil))
        let parse = try XCTUnwrap((json["allowed_mentions"] as? [String: Any])?["parse"] as? [String])
        XCTAssertTrue(parse.isEmpty)
    }

    /// ⚠️ THE TEXT MUST SURVIVE INTACT. The entire reason for choosing `allowed_mentions` over an
    /// escaper is that the reader still sees exactly what the agent wrote.
    func testTheMentionTextItselfIsNeverRewritten() throws {
        let code = "@MainActor func f() {} // mail user@example.com, @media, @everyone"
        let json = try encoded(DiscordCreateMessagePayload(content: code, components: nil))
        XCTAssertEqual(json["content"] as? String, code,
                       "escaping @ would mangle Swift attributes, CSS at-rules and email addresses — "
                       + "a worse defect than the ping it prevents")
    }

    /// An interaction response carrying a message body needs the same policy.
    func testAnInteractionResponseWithContentSuppressesMentions() throws {
        let json = try encoded(DiscordInteractionCallbackData(content: "@everyone"))
        XCTAssertNotNil(json["allowed_mentions"])
    }

    /// ⚠️ A MODAL IS NOT A MESSAGE. Discord permits exactly one initial response per interaction, so
    /// a 400 there is unrecoverable — a mention policy for a body that does not exist must not be
    /// sent at all. Swift's synthesized encoder omits nil optionals rather than writing null.
    func testAModalResponseSendsNoMentionPolicyAtAll() throws {
        let json = try encoded(DiscordInteractionCallbackData(custom_id: "answer:1", title: "Reply"))
        XCTAssertNil(json["allowed_mentions"],
                     "a modal carries no content; sending a mention policy risks a 400 on the one "
                     + "path that cannot retry")
        XCTAssertNil(json["content"])
    }

    // MARK: - Slack: the broadcast sequences

    func testSlackBroadcastSequencesAreNeutralised() {
        for broadcast in ["channel", "here", "everyone"] {
            let out = RemoteMarkupEscaping.withoutSlackBroadcasts("please <!\(broadcast)> look")
            XCTAssertFalse(out.contains("<!\(broadcast)>"), "\(broadcast) still notifies the channel")
            XCTAssertTrue(out.contains("@\(broadcast)"),
                          "the reader must still see what the source said — deleting it would hide content")
        }
    }

    /// ⚠️ The LABELLED form notifies identically. Matching only the bare form leaves the documented
    /// variant live, which is how a half-fix looks exactly like a fix.
    func testTheLabelledBroadcastFormIsAlsoNeutralised() {
        let out = RemoteMarkupEscaping.withoutSlackBroadcasts("hey <!channel|@channel> now")
        XCTAssertFalse(out.contains("<!channel"))
        XCTAssertTrue(out.contains("@channel"))
    }

    /// ⚠️ NARROW BY CONSTRUCTION. This rewrites content, which this codebase has got wrong four
    /// times; it is safe only because it matches an exact closed set, not a shape prose can satisfy.
    func testOrdinaryTextAndOtherSlackMarkupAreUntouched() {
        for text in ["a < b && c > d",
                     "see <https://example.com|the docs>",
                     "ping <@U123> about it",
                     "the channel is busy",
                     "`<!channel>` in backticks is still a broadcast to Slack"] {
            let out = RemoteMarkupEscaping.withoutSlackBroadcasts(text)
            if text.contains("<!channel>") { continue }   // the last case is deliberately rewritten
            XCTAssertEqual(out, text, "unrelated text must pass through byte-identical")
        }
    }

    /// ⚠️ THE WIRING. The function is inert unless the payload applies it, and the payload is the
    /// chokepoint precisely so a new send path cannot forget.
    func testEverySlackTextPayloadNeutralisesOnConstruction() {
        XCTAssertEqual(SlackPostMessagePayload(channel: "C1", text: "<!channel> hi").text, "@channel hi")
        XCTAssertEqual(SlackUpdateMessagePayload(channel: "C1", ts: "1", text: "<!here> hi").text, "@here hi")
    }

    /// ⚠️ THE ASSUMPTION THIS RESTS ON, asserted so it cannot be silently invalidated: `@channel` is
    /// inert ONLY because `chat.postMessage` is never sent `link_names`. If anyone adds it, the
    /// neutralising above stops being sufficient and this test is the one that says so.
    func testSlackIsNeverSentLinkNames() throws {
        for file in ["Devgentic/ChatOps/Services/SlackAPIClient.swift",
                     "Devgentic/ChatOps/Models/SlackModels.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments(file)
            XCTAssertFalse(source.contains("link_names"),
                           "\(file) sets link_names, which linkifies a bare @channel and re-opens BR-3")
        }
    }

    // MARK: - Helper

    private func encoded(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
