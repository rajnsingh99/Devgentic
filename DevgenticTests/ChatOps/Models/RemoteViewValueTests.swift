// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteViewValueTests.swift
//  DevgenticTests
//
//  C2 of the ChatOps remote-interface plan: the value objects.
//
//  The strongest test here is the first one. `CallbackToken` does not define the wire grammar — it
//  types the one already shipped, whose reader is `ChatOpsCommand.parseCallbackData` and whose
//  strings are already sitting in users' chat scrollback. So the test that matters is not "does
//  `wire` look right" but "does the REAL parser still understand every token we can mint". That is
//  a wiring test: it fails the moment the two drift, in either direction.
//

import XCTest
@testable import devgentic

final class RemoteViewValueTests: XCTestCase {

    // MARK: - CallbackToken ↔ the real parser

    /// ⚠️ THE WIRING TEST. Every token is fed through the production parser, not compared against a
    /// hand-written string. A grammar change on either side turns this red.
    ///
    /// Mutation that must turn this red: change any `wire` string — e.g. `"switch:"` → `"sw:"`, or
    /// lowercasing the UUID's separator layout — or reorder `hitl:gate:<uuid>:<idx>`'s two payloads.
    func testEveryTokenRoundTripsThroughTheRealParser() {
        let conversation = UUID()
        let operation = UUID()

        switch ChatOpsCommand.parseCallbackData(CallbackToken.switchConversation(conversation).wire) {
        case .switchConversation(let id): XCTAssertEqual(id, conversation)
        case let other: XCTFail("switch token parsed as \(other)")
        }

        switch ChatOpsCommand.parseCallbackData(CallbackToken.approveHITL(operationID: operation).wire) {
        case .approveHITL(let id): XCTAssertEqual(id, operation)
        case let other: XCTFail("approve token parsed as \(other)")
        }

        switch ChatOpsCommand.parseCallbackData(CallbackToken.denyHITL(operationID: operation).wire) {
        case .denyHITL(let id): XCTAssertEqual(id, operation)
        case let other: XCTFail("deny token parsed as \(other)")
        }

        switch ChatOpsCommand.parseCallbackData(CallbackToken.gateChoice(operationID: operation, optionIndex: 3).wire) {
        case .gateChoiceHITL(let id, let index):
            XCTAssertEqual(id, operation)
            XCTAssertEqual(index, 3, "the INDEX must survive, not the option label")
        case let other: XCTFail("gate token parsed as \(other)")
        }
    }

    /// Every `action:` verb we can mint must be one the parser answers. A case here that parsed to
    /// `.unknown` would be a button that does nothing when tapped — which is exactly the live
    /// Discord `switch:` defect, in a different shape.
    ///
    /// Mutation that must turn this red: add a case to `CallbackToken.Action` that
    /// `parseCallbackData` does not handle (e.g. `help`).
    func testEveryActionVerbIsUnderstoodByTheParser() {
        for action in CallbackToken.Action.allCases {
            let parsed = ChatOpsCommand.parseCallbackData(CallbackToken.action(action).wire)
            if case .unknown = parsed {
                XCTFail("""
                    `action:\(action.rawValue)` parses to .unknown — a button emitting it would be \
                    inert. Either the parser must learn it or the case must not exist.
                    """)
            }
        }
    }

    // MARK: - Paging tokens

    /// Mutation that must turn this red: accept any `page:` payload, coercing junk to zero.
    func testAPageTokenRoundTripsAndRefusesNonsense() {
        guard case .conversationPage(let offset) = ChatOpsCommand.parseCallbackData("page:20") else {
            return XCTFail("`page:20` must decode to a paging request")
        }
        XCTAssertEqual(offset, 20)
        XCTAssertEqual(CallbackToken.conversationPage(offset: 20).wire, "page:20")

        // ⚠️ REFUSED, NOT CLAMPED. A junk or negative payload coerced to zero is a button that
        // silently jumps the user somewhere they did not ask to go; `.unknown` is visible.
        for junk in ["page:", "page:-1", "page:abc", "page:1.5", "page: 4"] {
            guard case .unknown = ChatOpsCommand.parseCallbackData(junk) else {
                return XCTFail("`\(junk)` must be refused rather than coerced to a page")
            }
        }
    }

    // MARK: - The 64-byte ceiling

    /// A standing probe, not a one-off calculation. Telegram caps `callback_data` at 64 bytes and
    /// the grammar is shared across all three platforms, so its limit governs every token.
    ///
    /// Mutation that must turn this red: widen any token — e.g. carry the gate's option LABEL
    /// instead of its index.
    func testEveryTokenFitsTelegramsPayloadBudget() throws {
        let id = UUID()
        var tokens: [CallbackToken] = [
            .switchConversation(id),
            .conversationPage(offset: 999_999),   // an offset far past any realistic list
            .approveHITL(operationID: id),
            .denyHITL(operationID: id),
            .gateChoice(operationID: id, optionIndex: 999),   // far past any realistic option count
            .answerClarification(operationID: id),
            .selectProfile(id),
        ]
        tokens.append(contentsOf: CallbackToken.Action.allCases.map(CallbackToken.action))

        // ⚠️ THE LIST ABOVE IS HAND-WRITTEN AND HAD ALREADY FALLEN BEHIND. `.selectProfile`
        // shipped in slice 2 and was never added, so a test named "every token" silently
        // covered six of seven for two slices. The budget it guards is the one that makes
        // Telegram reject a WHOLE message, so a token that outgrew it would have shown up as
        // buttons that simply never render. `CallbackToken` carries associated values and so
        // cannot be `CaseIterable`; completeness is therefore checked against the DECLARATION.
        XCTAssertEqual(Set(tokens.map(Self.caseName)), try Self.declaredCaseNames(),
                       "The budget probe does not cover every CallbackToken case — a token absent from `tokens` is one whose size nothing checks.")

        for token in tokens {
            let size = token.wire.utf8.count
            XCTAssertTrue(token.fits(), """
                \(token.wire) is \(size) bytes, over Telegram's \
                \(CallbackToken.telegramPayloadBudget)-byte callback_data limit. Telegram rejects \
                the whole message, so the buttons never appear at all.
                """)
        }
    }

    /// The enum case behind a token, for the completeness check above.
    private static func caseName(_ token: CallbackToken) -> String {
        switch token {
        case .switchConversation:  return "switchConversation"
        case .conversationPage:    return "conversationPage"
        case .approveHITL:         return "approveHITL"
        case .denyHITL:            return "denyHITL"
        case .gateChoice:          return "gateChoice"
        case .answerClarification: return "answerClarification"
        case .selectProfile:       return "selectProfile"
        case .action:              return "action"
        }
    }

    /// The cases `CallbackToken` actually declares, read from source.
    ///
    /// ⚠️ Four-space `case ` declarations only. The nested `Action` enum's cases and the `wire`
    /// switch's arms are both indented deeper, so this picks out the top-level grammar and nothing
    /// else.
    private static func declaredCaseNames() throws -> Set<String> {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("Devgentic/ChatOps/Models/CallbackToken.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("CallbackToken.swift not reachable — running outside a checkout")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let names = source.split(separator: "\n")
            .filter { $0.hasPrefix("    case ") }
            .map { $0.dropFirst("    case ".count) }
            .map { String($0.prefix { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
        XCTAssertFalse(names.isEmpty, "the source scan found no cases — it is checking nothing")
        return Set(names)
    }

    /// Records the ceiling that shapes every future feature, with the arithmetic rather than a
    /// claim: a canonical UUID is 36 bytes, so a token carrying TWO cannot exist.
    ///
    /// This is why per-node workflow approval — which must carry `(operationID, nodeID)` — needs
    /// base64url (16 raw bytes → 22 chars) and therefore a legacy-decode window, rather than being
    /// bolted onto the current grammar.
    func testATwoUUIDTokenCannotFitWhichIsWhyThereIsNotOne() {
        let hypothetical = "use:\(UUID().uuidString):\(UUID().uuidString)"
        XCTAssertGreaterThan(
            hypothetical.utf8.count, CallbackToken.telegramPayloadBudget,
            "if this ever fits, the ceiling recorded in CallbackToken's header has changed"
        )

        let base64url = { (id: UUID) -> String in
            var bytes = id.uuid
            let data = withUnsafeBytes(of: &bytes) { Data($0) }
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let compact = "use:\(base64url(UUID())):\(base64url(UUID()))"
        XCTAssertLessThanOrEqual(
            compact.utf8.count, CallbackToken.telegramPayloadBudget,
            "base64url is the documented escape hatch; if it stops fitting the plan needs revisiting"
        )
    }

    // MARK: - Chooser layout

    /// ⚠️ A chooser with nothing in it must become a NOTICE. All three bridges already send
    /// "No conversations yet. Use /new to create one." rather than an empty keyboard; making it a
    /// distinct plan is what stops a renderer forgetting.
    ///
    /// Mutation that must turn this red: drop the `optionCount > 0` guard.
    func testAnEmptyChooserBecomesANoticeNeverAnEmptyKeyboard() {
        for capabilities in Self.allCapabilities {
            XCTAssertEqual(RemoteChooserLayout.plan(optionCount: 0, capabilities: capabilities), .notice)
        }
    }

    /// ⚠️ THE INVARIANT. Losing DECORATION is acceptable degradation; losing an ACTION is not. A
    /// truncated list looks complete to the user while hiding conversations they cannot otherwise
    /// reach.
    ///
    /// Mutation that must turn this red: add a `.prefix(capabilities.maxButtons)` anywhere in
    /// `plan` — i.e. the silent truncation found in the shipping Slack bridge.
    func testNoOptionIsEverDroppedAtAnyCountOnAnyPlatform() {
        for capabilities in Self.allCapabilities {
            for count in 0...30 {
                guard case .buttons(let rows) = RemoteChooserLayout.plan(optionCount: count, capabilities: capabilities) else {
                    XCTAssertEqual(count, 0, "only an empty chooser may plan to a notice")
                    continue
                }
                let covered = rows.flatMap { $0 }
                XCTAssertEqual(
                    covered, Array(0..<count),
                    "count \(count) at \(capabilities.buttonsPerRow)/row lost or reordered options: \(covered)"
                )
            }
        }
    }

    /// Row chunking is transcribed from the shipping bridges: Telegram full-width rows, Discord
    /// ActionRows of 5, Slack one actions block.
    func testRowChunkingMatchesEachPlatformsCurrentBehaviour() {
        guard case .buttons(let telegram) = RemoteChooserLayout.plan(optionCount: 10, capabilities: .telegram) else {
            return XCTFail("expected buttons")
        }
        XCTAssertEqual(telegram.count, 10, "Telegram renders one full-width button per row")
        XCTAssertTrue(telegram.allSatisfy { $0.count == 1 })

        guard case .buttons(let discord) = RemoteChooserLayout.plan(optionCount: 10, capabilities: .discord) else {
            return XCTFail("expected buttons")
        }
        XCTAssertEqual(discord.map(\.count), [5, 5], "Discord packs 5 buttons per ActionRow")

        guard case .buttons(let slack) = RemoteChooserLayout.plan(optionCount: 10, capabilities: .slack) else {
            return XCTFail("expected buttons")
        }
        XCTAssertEqual(slack.count, 1, "Slack has no per-row concept — one actions block holds them all")
        XCTAssertEqual(slack.first?.count, 10)
    }

    /// Slice 1 caps every list at ten, so nothing exceeds capacity today. Pinned so the day a list
    /// can grow, the renderer has something to check other than its own judgement.
    func testCapacityIsNotExceededAtSliceOneListSizes() {
        for capabilities in Self.allCapabilities {
            XCTAssertFalse(RemoteChooserLayout.exceedsCapacity(optionCount: 10, capabilities: capabilities))
        }
        XCTAssertTrue(RemoteChooserLayout.exceedsCapacity(optionCount: 26, capabilities: .discord))
        XCTAssertTrue(RemoteChooserLayout.exceedsCapacity(optionCount: 26, capabilities: .slack))
    }

    // MARK: - Codable, which is the secretlessness mechanism

    /// ⚠️ `Codable` on `RemoteView` is a SAFETY property, not a convenience. A remote view is posted
    /// to a third-party service, so it must not be able to carry a secret — and
    /// `BackendProfileSnapshot` is deliberately non-`Codable` because its `details` getter injects
    /// the decrypted provider API key from the Keychain. Requiring the conformance means the
    /// compiler refuses any view that reaches for one.
    ///
    /// Mutation that must turn this red: remove `Codable` from `RemoteView` — this file stops
    /// compiling, which is the intended signal.
    func testEveryViewCaseSurvivesACodableRoundTrip() throws {
        let cases: [RemoteView] = [
            .silent(.unrecognized("/nope")),
            .notice(Notice(tone: .warning, title: "Status", body: "Idle",
                           fields: [.init(label: "Tier", value: "Standard", emphasis: true)])),
            .chooser(Chooser(
                title: "Your Conversations",
                options: [.init(label: "Deploy checklist", token: .switchConversation(UUID()), isCurrent: true)],
                extraActions: [.init(label: "➕ New Conversation", token: .action(.new), intent: .primary)]
            )),
            .prompt(operationID: UUID(), kind: .gate(prompt: "Proceed?", options: ["Yes", "No"])),
        ]

        for view in cases {
            let data = try JSONEncoder().encode(view)
            let decoded = try JSONDecoder().decode(RemoteView.self, from: data)
            XCTAssertEqual(decoded, view, "\(view) did not survive the round trip C3's golden fixtures depend on")
        }
    }

    /// `isCurrent` must stay a flag. All three bridges bake `"⭐ "` into the label today, which
    /// forecloses Slack's native `initial_option` forever.
    ///
    /// Mutation that must turn this red: change `isCurrent: Bool` to a prefixed label.
    func testCurrentSelectionIsAFlagNotABakedInLabelPrefix() {
        let option = Chooser.Option(label: "Deploy checklist", token: .action(.new), isCurrent: true)
        XCTAssertTrue(option.isCurrent)
        XCTAssertFalse(option.label.contains("⭐"), """
            The current-selection marker is baked into the label. Keeping it a Bool is what lets \
            Slack render a pre-selected dropdown while Telegram renders a star.
            """)
    }

    // MARK: - Channel

    /// One mapping, in one place. Today each bridge passes its own `.telegram` / `.discord` /
    /// `.slack` literal at its own `submitRemoteMessage` call site — three places that must agree,
    /// with no way to notice when they stop.
    func testEveryProviderMapsToItsMessageSource() {
        XCTAssertEqual(RemoteChannel.Provider.telegram.messageSource, .telegram)
        XCTAssertEqual(RemoteChannel.Provider.discord.messageSource, .discord)
        XCTAssertEqual(RemoteChannel.Provider.slack.messageSource, .slack)
        XCTAssertEqual(RemoteChannel.Provider.allCases.count, 3, "a new provider needs a MessageSource case too")
    }

    func testTelegramChannelsCarryTheirNumericIDAsAString() {
        XCTAssertEqual(RemoteChannel(telegramChatID: -1_001_234_567_890).channelID, "-1001234567890")
    }

    // MARK: - Helpers

    private static let allCapabilities: [RemoteCapabilities] = [.telegram, .discord, .slack]
}
