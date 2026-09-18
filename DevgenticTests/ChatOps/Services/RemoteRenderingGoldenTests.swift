// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteRenderingGoldenTests.swift
//  DevgenticTests
//
//  C3 of the ChatOps remote-interface plan: the renderers, pinned by their wire payloads.
//
//  ⚠️ THESE ARE THE PRIMARY PROOF THAT C5–C7 CHANGE NO OBSERVABLE OUTPUT. Because every renderer is
//  `nonisolated static` over plain values and every draft is `Encodable`, a test can assert the
//  exact JSON with no transport, no API client and no network. When each bridge is swapped onto the
//  new path, it must reproduce these bytes.
//
//  ⚠️ THE ONE ASSERTION THAT MATTERS MOST is `parse_mode == "Markdown"`.
//  `TelegramAPIClient.sendMessage` defaults it, so every BRIDGE call site inherits Markdown and
//  renders bold today, while `TelegramTransport` passes `nil` at all seven of its own sites. Hosting
//  a renderer on the transport without noticing silently turns every reply's formatting into literal
//  asterisks — on all five verbs, on the largest platform, with no error anywhere. Three of the four
//  designs reviewed for this refactor walked into exactly that.
//

import XCTest
@testable import devgentic

final class RemoteRenderingGoldenTests: XCTestCase {

    // MARK: - Fixtures

    private static let conversationA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let conversationB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    /// What `/conversations` will produce: two conversations, the first current, plus the
    /// "➕ New Conversation" extra action.
    private var conversationChooser: RemoteView {
        .chooser(Chooser(
            title: "Your Conversations:",
            options: [
                .init(label: "Deploy checklist", token: .switchConversation(Self.conversationA), isCurrent: true),
                .init(label: "Release notes", token: .switchConversation(Self.conversationB)),
            ],
            extraActions: [
                .init(label: "➕ New Conversation", token: .action(.new), intent: .primary),
            ]
        ))
    }

    /// What `/status` will produce: a field list rather than a hand-formatted blob.
    private var statusNotice: RemoteView {
        .notice(Notice(
            tone: .info,
            title: "Devgentic Status",
            body: "",
            fields: [
                .init(label: "Conversation", value: "Deploy checklist", emphasis: true),
                .init(label: "Streaming", value: "no"),
            ]
        ))
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - The parse_mode trap

    /// Mutation that must turn this red: change `parse_mode: "Markdown"` to `nil` in
    /// `TelegramRemoteRenderer` — i.e. inherit `TelegramTransport`'s deliberate `nil` instead of
    /// the bridges' inherited default.
    func testTelegramNoticesAndChoosersCarryMarkdownParseMode() throws {
        for view in [statusNotice, conversationChooser] {
            let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
            XCTAssertEqual(draft.parse_mode, "Markdown", """
                Telegram lost its parse mode. The bridges inherit `parseMode: "Markdown"` from \
                TelegramAPIClient.sendMessage's DEFAULT, so `*Your Conversations:*` renders bold \
                today. Dropping it turns every reply's formatting into literal asterisks.
                """)
        }
    }

    /// The other half of the asymmetry. ⚠️ THIS TEST WAS INVERTED AT C8.5, DELIBERATELY. At C3 it
    /// asserted that `.prompt` produced no draft at all, because the mirror still called a dedicated
    /// `sendHITLPrompt`. C8.5 moved those payloads here and deleted that method, so the correct
    /// assertion is now the opposite: prompts ARE rendered here, and they carry NO parse mode while
    /// notices and choosers carry Markdown. Recorded rather than quietly rewritten — an assertion
    /// that flips meaning is exactly the kind a later reader needs the history of.
    func testPromptsAreRenderedHereButWithoutAParseMode() throws {
        let prompt = RemoteView.prompt(operationID: UUID(), kind: .clarification(question: "Which file?"))

        let telegram = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt))
        XCTAssertNil(telegram.parse_mode, "a prompt carries model-supplied text and must not be parsed as Markdown")
        XCTAssertNotNil(DiscordRemoteRenderer.draft(for: prompt))
        XCTAssertNotNil(SlackRemoteRenderer.draft(for: prompt))

        // …while a notice on the same platform still does.
        let notice = RemoteView.notice(Notice(tone: .info, body: "hello"))
        XCTAssertEqual(try XCTUnwrap(TelegramRemoteRenderer.draft(for: notice)).parse_mode, "Markdown")
    }

    // MARK: - Golden payloads

    func testTelegramChooserGoldenPayload() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: conversationChooser))
        XCTAssertEqual(try json(draft), """
            {"parse_mode":"Markdown","reply_markup":{"inline_keyboard":[[{"callback_data":"switch:11111111-1111-1111-1111-111111111111","text":"⭐ Deploy checklist"}],[{"callback_data":"switch:22222222-2222-2222-2222-222222222222","text":"Release notes"}],[{"callback_data":"action:new","text":"➕ New Conversation"}]]},"text":"*Your Conversations:*"}
            """)
    }

    func testDiscordChooserGoldenPayload() throws {
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: conversationChooser))
        // Three options fit one ActionRow (Discord packs 5 per row).
        XCTAssertEqual(try json(draft), """
            {"components":[{"components":[{"custom_id":"switch:11111111-1111-1111-1111-111111111111","label":"⭐ Deploy checklist","style":2,"type":2},{"custom_id":"switch:22222222-2222-2222-2222-222222222222","label":"Release notes","style":2,"type":2},{"custom_id":"action:new","label":"➕ New Conversation","style":1,"type":2}],"type":1}],"content":"**Your Conversations:**"}
            """)
    }

    func testSlackChooserGoldenPayload() throws {
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: conversationChooser))
        // One section block, then ONE actions block — Slack has no per-row concept.
        XCTAssertEqual(try json(draft), """
            {"blocks":[{"text":{"text":"*Your Conversations:*","type":"mrkdwn"},"type":"section"},{"elements":[{"action_id":"switch:11111111-1111-1111-1111-111111111111","text":{"emoji":true,"text":"⭐ Deploy checklist","type":"plain_text"},"type":"button","value":"switch:11111111-1111-1111-1111-111111111111"},{"action_id":"switch:22222222-2222-2222-2222-222222222222","text":{"emoji":true,"text":"Release notes","type":"plain_text"},"type":"button","value":"switch:22222222-2222-2222-2222-222222222222"},{"action_id":"action:new","style":"primary","text":{"emoji":true,"text":"➕ New Conversation","type":"plain_text"},"type":"button","value":"action:new"}],"type":"actions"}],"text":"*Your Conversations:*"}
            """)
    }

    func testStatusNoticeRendersAsAFieldListOnEveryPlatform() throws {
        let telegram = try XCTUnwrap(TelegramRemoteRenderer.draft(for: statusNotice))
        XCTAssertEqual(telegram.text, "*Devgentic Status*\nConversation: *Deploy checklist*\nStreaming: no")

        let discord = try XCTUnwrap(DiscordRemoteRenderer.draft(for: statusNotice))
        XCTAssertEqual(discord.content, "**Devgentic Status**\nConversation: **Deploy checklist**\nStreaming: no")

        let slack = try XCTUnwrap(SlackRemoteRenderer.draft(for: statusNotice))
        XCTAssertEqual(slack.text, "*Devgentic Status*\nConversation: *Deploy checklist*\nStreaming: no")
        XCTAssertEqual(slack.blocks?.count, 1, "a notice is one section block")
    }

    // MARK: - Escaping closes a live bug

    /// ⚠️ A conversation title is auto-derived from the user's own first message, and the bridges
    /// interpolate it into a `parse_mode: Markdown` reply. An unbalanced `*` or `_` makes Telegram
    /// reject the WHOLE message with a 400 — swallowed by `_ = try? await`, so the remote user
    /// simply receives nothing.
    ///
    /// Mutation that must turn this red: drop the `RemoteMarkupEscaping` call from the notice path.
    func testAUserControlledTitleCannotBreakTelegramsMarkdownParser() throws {
        let hostile = "fix *bold and _italic and `code"
        let view = RemoteView.notice(Notice(tone: .success, body: "Switched to:", fields: [.init(value: hostile)]))

        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertTrue(draft.text.contains(#"fix \*bold and \_italic and \`code"#), """
            The hostile title reached Telegram unescaped: \(draft.text). Telegram 400s the whole \
            message, and every bridge send site is `try?`, so the user receives nothing at all.
            """)
    }

    func testSlackEscapesTheThreeEntitiesItRequiresAndInTheRightOrder() {
        XCTAssertEqual(RemoteMarkupEscaping.slack("a & b < c > d"), "a &amp; b &lt; c &gt; d")
        XCTAssertEqual(RemoteMarkupEscaping.slack("&lt;"), "&amp;lt;",
                       "`&` must be escaped FIRST or the entities it introduces are re-escaped")
    }

    // MARK: - Shape rules

    /// Three options at 5-per-row is one ActionRow; six is two. Pinned because Discord rejects a
    /// row of more than five and the failure is a 400 the mirror logs and swallows.
    func testDiscordPacksFiveButtonsPerActionRow() throws {
        let options = (0..<6).map { index in
            Chooser.Option(label: "Conversation \(index)", token: .switchConversation(UUID()))
        }
        let view = RemoteView.chooser(Chooser(title: "Pick", options: options))
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: view))
        XCTAssertEqual(draft.components?.count, 2)
        XCTAssertEqual(draft.components?.first?.components?.count, 5)
        XCTAssertEqual(draft.components?.last?.components?.count, 1)
    }

    /// ⚠️ Slack has no "secondary" style — the ABSENCE of a style is the default button. Emitting a
    /// literal would restyle every existing button.
    func testSlackNeutralButtonsCarryNoStyleAtAll() {
        XCTAssertNil(SlackRemoteRenderer.style(for: .neutral))
        XCTAssertEqual(SlackRemoteRenderer.style(for: .primary), SlackBlockElement.primaryStyle)
        XCTAssertEqual(SlackRemoteRenderer.style(for: .destructive), SlackBlockElement.dangerStyle)
    }

    /// Labels are truncated to each platform's own limit, so a long title is not clipped to the
    /// shortest common length.
    func testEachPlatformTruncatesLabelsToItsOwnLimit() throws {
        let long = String(repeating: "x", count: 200)
        let view = RemoteView.chooser(Chooser(title: "Pick", options: [.init(label: long, token: .action(.new))]))

        let telegram = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertEqual(inlineKeyboard(telegram.reply_markup)?.first?.first?.text.count, 60)

        let discord = try XCTUnwrap(DiscordRemoteRenderer.draft(for: view))
        XCTAssertEqual(discord.components?.first?.components?.first?.label?.count, 80)

        let slack = try XCTUnwrap(SlackRemoteRenderer.draft(for: view))
        XCTAssertEqual(slack.blocks?.last?.elements?.first?.text?.text.count, 75)
    }

    /// An empty chooser must not produce an empty keyboard on any platform.
    func testAnEmptyChooserProducesNoButtonsAnywhere() throws {
        let view = RemoteView.chooser(Chooser(title: "Nothing here", options: []))

        XCTAssertNil(try XCTUnwrap(TelegramRemoteRenderer.draft(for: view)).reply_markup)
        XCTAssertNil(try XCTUnwrap(DiscordRemoteRenderer.draft(for: view)).components)
        XCTAssertEqual(try XCTUnwrap(SlackRemoteRenderer.draft(for: view)).blocks?.count, 1)
    }

    /// A `.silent` view posts nothing on every platform — the drop is logged, not rendered.
    func testSilentViewsProduceNoDraftAnywhere() {
        let view = RemoteView.silent(.unrecognized("/nope"))
        XCTAssertNil(TelegramRemoteRenderer.draft(for: view))
        XCTAssertNil(DiscordRemoteRenderer.draft(for: view))
        XCTAssertNil(SlackRemoteRenderer.draft(for: view))
    }

    /// `isCurrent` becomes the star at RENDER time, on every platform, rather than being baked into
    /// the label by the command. That is what leaves Slack's native `initial_option` reachable.
    func testTheCurrentMarkerIsAppliedByTheRendererNotTheView() throws {
        let view = RemoteView.chooser(Chooser(title: "Pick", options: [
            .init(label: "Current one", token: .action(.new), isCurrent: true),
        ]))
        let telegram = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertEqual(inlineKeyboard(telegram.reply_markup)?.first?.first?.text, "⭐ Current one")
    }
}

// MARK: - The real shipping literals

/// ⚠️ THE TESTS THAT DECIDE WHETHER C5 CAN BE BEHAVIOUR-PRESERVING.
///
/// Every string below is transcribed character for character from `ChatOpsBridge.swift` as it ships
/// today. C5 replaces those handlers with a service returning `RemoteView`; if the vocabulary cannot
/// reproduce these bytes, the swap is a silent restyling of the five most-used replies rather than a
/// refactor. An adversarial pass against an earlier draft found SIX literals it could not express —
/// `Notice.icon`, `Field.inline`, `Field.labelEmphasis` and `Field.spacer` each exist for one of
/// them, and this is where that is proved rather than asserted.
final class ShippingLiteralGoldenTests: XCTestCase {

    private func telegramText(_ view: RemoteView) throws -> String {
        try XCTUnwrap(TelegramRemoteRenderer.draft(for: view)).text
    }

    /// `ChatOpsBridge.handleSwitchConversation` :349-352 — inline bold after a colon, then a BLANK
    /// line. The most common reply in the subsystem and the one the vocabulary nearly could not say.
    func testSwitchConversationSuccessMatchesTheShippingLiteral() throws {
        let view = RemoteView.notice(Notice(
            tone: .success,
            body: "✅ Switched to:",
            fields: [
                .init(value: "Deploy checklist", emphasis: true, inline: true),
                .spacer,
                .init(value: "Just type your message to continue."),
            ]
        ))
        XCTAssertEqual(try telegramText(view), """
        ✅ Switched to: *Deploy checklist*

        Just type your message to continue.
        """)
    }

    /// `ChatOpsBridge.handleStatus` :274-282 — emoji-outside-bold heading, blank line, five
    /// emoji-labelled fields.
    func testStatusMatchesTheShippingLiteral() throws {
        let view = RemoteView.notice(Notice(
            tone: .info,
            icon: "📊",
            title: "Devgentic Status",
            fields: [
                .spacer,
                .init(label: "🗣 Active Conversation", value: "None"),
                .init(label: "⚡ Agent Streaming", value: "No"),
                .init(label: "🔐 Security Tier", value: "Read Only"),
                .init(label: "⏳ HITL Pending", value: "No"),
                .init(label: "📋 Total Conversations", value: "3"),
            ]
        ))
        XCTAssertEqual(try telegramText(view), """
        📊 *Devgentic Status*

        🗣 Active Conversation: None
        ⚡ Agent Streaming: No
        🔐 Security Tier: Read Only
        ⏳ HITL Pending: No
        📋 Total Conversations: 3
        """)
    }

    /// `ChatOpsBridge.handleHelp` :313-329 — three whole-line bold runs, two blank lines, and a bold
    /// LABEL with a plain value on the last line.
    func testHelpMatchesTheShippingLiteral() throws {
        let view = RemoteView.notice(Notice(
            tone: .info,
            icon: "🤖",
            title: "Devgentic ChatOps",
            fields: [
                .spacer,
                .init(value: "Commands:", emphasis: true),
                .init(value: "/conversations — List your conversations"),
                .init(value: "/new — Start a new conversation"),
                .init(value: "/status — Current agent status"),
                .init(value: "/cancel — Stop the active agent"),
                .init(value: "/help — Show this message"),
                .spacer,
                .init(value: "How it works:", emphasis: true),
                .init(value: "1. Use /conversations to pick a conversation"),
                .init(value: "2. Type your message — it routes to the agent"),
                .init(value: "3. The agent responds right here"),
                .spacer,
                .init(label: "Security Tier", value: "Read Only", labelEmphasis: true),
            ]
        ))
        XCTAssertEqual(try telegramText(view), """
        🤖 *Devgentic ChatOps*

        *Commands:*
        /conversations — List your conversations
        /new — Start a new conversation
        /status — Current agent status
        /cancel — Stop the active agent
        /help — Show this message

        *How it works:*
        1. Use /conversations to pick a conversation
        2. Type your message — it routes to the agent
        3. The agent responds right here

        *Security Tier:* Read Only
        """)
    }

    /// `ChatOpsBridge.handleConversations` :206-210 — the emoji is outside the bold here too.
    func testConversationListHeaderMatchesTheShippingLiteral() throws {
        let view = RemoteView.chooser(Chooser(
            icon: "📋",
            title: "Your Conversations:",
            options: [.init(label: "Deploy checklist", token: .action(.new))]
        ))
        XCTAssertEqual(try telegramText(view), "📋 *Your Conversations:*")
    }

    /// ⚠️ An empty chooser renders the HEADING and nothing else — it is NOT the empty-state sentence.
    /// `RemoteChooserLayout.Plan.notice`'s doc comment used to claim otherwise, and
    /// `testAnEmptyChooserProducesNoButtonsAnywhere` asserted only that no buttons appeared, so a
    /// command service handing over an empty chooser would have silently replaced
    /// "No conversations yet. Use /new to create one." with a bare header — green all the way.
    /// Producing the sentence is the COMMAND's job; this pins what the renderer actually does.
    func testAnEmptyChooserRendersOnlyItsHeadingOnEveryPlatform() throws {
        let view = RemoteView.chooser(Chooser(icon: "📋", title: "Your Conversations:", options: []))

        XCTAssertEqual(try telegramText(view), "📋 *Your Conversations:*")
        XCTAssertEqual(try XCTUnwrap(DiscordRemoteRenderer.draft(for: view)).content, "📋 **Your Conversations:**")
        XCTAssertEqual(try XCTUnwrap(SlackRemoteRenderer.draft(for: view)).text, "📋 *Your Conversations:*")
    }

    /// ⚠️ Button labels are NOT markup on any platform, so they must reach the wire UNESCAPED — the
    /// mirror of the hostile-title test for notices. Escaping them "for consistency" would put
    /// visible backslashes in every conversation title containing `_ * ` [`.
    func testChooserButtonLabelsAreNotEscaped() throws {
        let hostile = "fix *bold and _italic"
        let view = RemoteView.chooser(Chooser(
            title: "Pick",
            options: [.init(label: hostile, token: .action(.new))]
        ))
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: view))
        XCTAssertEqual(inlineKeyboard(draft.reply_markup)?.first?.first?.text, hostile,
                       "button text is not parsed as markup — escaping it ships visible backslashes")
    }
}

// MARK: - HITL prompts (C8.5)

/// ⚠️ These twelve payloads (4 kinds × 3 platforms) were MOVED out of the three
/// `sendHITLPrompt` implementations, not retyped — every string literal was verified byte-identical
/// against the originals before that method was deleted. These fixtures pin the result so a future
/// edit cannot drift them apart again.
final class HITLPromptGoldenTests: XCTestCase {

    private static let operation = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private var approve: String { "hitl:approve:\(Self.operation.uuidString)" }
    private var deny: String { "hitl:deny:\(Self.operation.uuidString)" }
    private func prompt(_ kind: HITLType) -> RemoteView { .prompt(operationID: Self.operation, kind: kind) }

    // MARK: Telegram

    /// ⚠️ `parse_mode` is nil on EVERY prompt arm, unlike notices and choosers. The text carries
    /// model-supplied tool names and parameters; parsing those as Markdown is the 400 that makes a
    /// reply vanish entirely.
    func testEveryTelegramPromptPassesNoParseMode() throws {
        let kinds: [HITLType] = [
            .toolConfirmation(toolName: "write_file", params: "{}"),
            .clarification(question: "Which file?"),
            .planReview(subtaskDescriptions: ["a"]),
            .gate(prompt: "Proceed?", options: ["Yes"]),
        ]
        for kind in kinds {
            let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt(kind)))
            XCTAssertNil(draft.parse_mode, "a HITL prompt must not be parsed as Markdown")
        }
    }

    func testTelegramToolConfirmationMatchesTheShippedPayload() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt(
            .toolConfirmation(toolName: "write_file", params: "{\"path\":\"a.txt\"}"))))
        XCTAssertEqual(draft.text, """
        ⚠️ Tool Approval Required

        Tool: write_file
        Params: {"path":"a.txt"}

        Tap to approve or deny:
        """)
        let row = try XCTUnwrap(inlineKeyboard(draft.reply_markup)?.first)
        XCTAssertEqual(row.map(\.text), ["✅ Approve", "❌ Deny"])
        XCTAssertEqual(row.map { $0.callback_data ?? "" }, [approve, deny])
    }

    func testTelegramClarificationForcesAReplySoTheAnswerCanBeCorrelated() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt(.clarification(question: "Which file?"))))
        // ⚠️ "Reply to this message" replaced "Reply with your answer" in slice 4, and the wording
        // is load-bearing rather than cosmetic: only a REPLY carries `reply_to_message`, which is
        // the sole thing on the wire naming which clarification is being answered.
        XCTAssertEqual(draft.text, """
        💬 Agent needs clarification:

        Which file?

        Reply to this message with your answer, or type /skip to skip.
        """)
        // ⚠️ INVERTED IN SLICE 4, DELIBERATELY. This asserted `XCTAssertNil(draft.reply_markup,
        // "the clarification prompt has never had buttons")` and it was true: clarification was the
        // ONE HITL kind rendered with no affordance at all on every platform, which is exactly why
        // an answer could only be correlated by a provider-wide cursor. It now carries a
        // `ForceReply` — still not buttons, but the thing that makes the reply carry
        // `reply_to_message` and therefore name the operation it answers.
        guard case .forceReply(let force)? = draft.reply_markup else {
            return XCTFail("a clarification must force a reply so the answer can be correlated")
        }
        XCTAssertTrue(force.force_reply)
        XCTAssertFalse(force.selective, """
            `selective` targets only @mentioned users, or the sender of a message the bot replied \
            to. A mirrored prompt is neither, so `true` would force the reply box for NOBODY and \
            the affordance would silently do nothing.
            """)
    }

    /// ⚠️ ONE BUTTON PER ROW on Telegram — Discord chunks by 5 and Slack by 5. Three platforms,
    /// three shapes, all deliberate.
    func testTelegramGatePutsOneOptionPerRow() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt(
            .gate(prompt: "Proceed?", options: ["Yes", "No", "Ask again"]))))
        let keyboard = try XCTUnwrap(inlineKeyboard(draft.reply_markup))
        XCTAssertEqual(keyboard.map { $0.count }, [1, 1, 1])
        XCTAssertEqual(keyboard.map { $0[0].callback_data ?? "" },
                       (0..<3).map { "hitl:gate:\(Self.operation.uuidString):\($0)" })
    }

    // MARK: Discord

    func testDiscordToolConfirmationUsesSuccessAndDangerStyles() throws {
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: prompt(
            .toolConfirmation(toolName: "write_file", params: "{}"))))
        XCTAssertTrue(draft.content.hasPrefix("⚠️ **Tool Approval Required**"))
        let row = try XCTUnwrap(draft.components?.first?.components)
        XCTAssertEqual(row.map { $0.style ?? -1 }, [DiscordComponent.successStyle, DiscordComponent.dangerStyle])
        XCTAssertEqual(row.map { $0.custom_id ?? "" }, [approve, deny])
    }

    /// ⚠️ Discord chunks gate options by 5 — an ActionRow's hard limit — which is NOT the chooser
    /// path's shape.
    func testDiscordGateChunksOptionsByFive() throws {
        let options = (0..<7).map { "option \($0)" }
        let draft = try XCTUnwrap(DiscordRemoteRenderer.draft(for: prompt(.gate(prompt: "Pick", options: options))))
        XCTAssertEqual(draft.components?.map { $0.components?.count ?? 0 }, [5, 2])
    }

    // MARK: Slack

    /// ⚠️ The clarification prompt posts TEXT ONLY — no blocks. Adding a section block here would
    /// change the rendering of every clarification on Slack.
    /// ⚠️ INVERTED IN SLICE 4.3, DELIBERATELY. This asserted `XCTAssertNil(draft.blocks)` under the
    /// name `testSlackClarificationPostsTextWithNoBlocks`, and the renderer carried a matching note
    /// that adding a block "would change the rendering of every clarification prompt on Slack". It
    /// does, and that is the change: without a button there is no `trigger_id`, and without a
    /// `trigger_id` there is no `views.open` — so a text-only prompt made Slack's structured input
    /// permanently unreachable.
    func testSlackClarificationOffersTheButtonItsModalNeeds() throws {
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: prompt(.clarification(question: "Which file?"))))
        XCTAssertEqual(draft.text, "💬 *Agent needs clarification:*\n\nWhich file?\n\nTap *Answer* to reply, or type /skip to skip.")

        let blocks = try XCTUnwrap(draft.blocks)
        XCTAssertEqual(draft.text, blocks.first?.text?.text,
                       "the fallback text mirrors the section block, as the other prompt kinds do")
        let actions = try XCTUnwrap(blocks.first { $0.type == SlackBlock.actions })
        XCTAssertEqual(actions.elements?.first?.action_id,
                       CallbackToken.answerClarification(operationID: Self.operation).wire)
    }

    func testSlackToolConfirmationCarriesTheOperationScopedBlockID() throws {
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: prompt(
            .toolConfirmation(toolName: "write_file", params: "{}"))))
        let blocks = try XCTUnwrap(draft.blocks)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last?.block_id, "hitl_\(Self.operation.uuidString)")
        XCTAssertEqual(blocks.last?.elements?.map { $0.style ?? "" },
                       [SlackBlockElement.primaryStyle, SlackBlockElement.dangerStyle])
        XCTAssertEqual(draft.text, blocks.first?.text?.text, "the fallback text mirrors the section block")
    }

    /// ⚠️⚠️ Slack's GATE path chunks by 5 while its CHOOSER path puts up to 25 in one actions block.
    /// The two shipping comments about Slack's limit contradict each other; both BEHAVIOURS are
    /// preserved because changing either is a visible rendering change.
    func testSlackGateChunksByFiveUnlikeTheChooserPath() throws {
        let options = (0..<7).map { "option \($0)" }
        let draft = try XCTUnwrap(SlackRemoteRenderer.draft(for: prompt(.gate(prompt: "Pick", options: options))))
        let blocks = try XCTUnwrap(draft.blocks)
        XCTAssertEqual(blocks.first?.type, SlackBlock.section)
        XCTAssertEqual(blocks.dropFirst().map { $0.elements?.count ?? 0 }, [5, 2])
        XCTAssertEqual(blocks.dropFirst().map { $0.block_id ?? "" },
                       ["hitl_\(Self.operation.uuidString)_0", "hitl_\(Self.operation.uuidString)_5"])

        // The chooser path, by contrast, keeps all seven in ONE block.
        let chooser = RemoteView.chooser(Chooser(title: "Pick", options: options.map {
            .init(label: $0, token: .action(.new))
        }))
        let chooserDraft = try XCTUnwrap(SlackRemoteRenderer.draft(for: chooser))
        XCTAssertEqual(chooserDraft.blocks?.dropFirst().map { $0.elements?.count ?? 0 }, [7])
    }

    /// Every prompt button carries a token the real parser understands — an inert HITL button would
    /// leave a run parked forever.
    func testEveryPromptButtonRoundTripsThroughTheRealParser() throws {
        let draft = try XCTUnwrap(TelegramRemoteRenderer.draft(for: prompt(
            .gate(prompt: "Proceed?", options: ["Yes", "No"]))))
        for row in try XCTUnwrap(inlineKeyboard(draft.reply_markup)) {
            for button in row {
                let parsed = ChatOpsCommand.parseCallbackData(button.callback_data ?? "")
                if case .unknown = parsed { XCTFail("\(button.callback_data ?? "") is an inert HITL button") }
            }
        }
    }
}

/// The inline keyboard, when the markup IS one.
///
/// ⚠️ `Draft.reply_markup` became type-erased in slice 4 so that Telegram's `ForceReply` — the
/// platform's only structured-input affordance — could be expressed at all. These fixtures still
/// care about buttons, so they unwrap; asserting the KIND is now itself meaningful.
private func inlineKeyboard(_ markup: SendMessagePayload.ReplyMarkup?) -> [[InlineKeyboardButton]]? {
    guard case .inline(let keyboard)? = markup else { return nil }
    return keyboard.inline_keyboard
}
