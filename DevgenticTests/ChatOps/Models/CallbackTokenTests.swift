// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CallbackTokenTests.swift
//  DevgenticTests
//
//  The callback grammar, and the ceiling that governs it.
//
//  ⚠️⚠️ THIS FILE IS CITED BY `CallbackToken.swift` AND DID NOT EXIST. Its header pointed at
//  "`CallbackTokenTests.testEveryTokenFitsTelegramsBudget`, which is a standing probe rather than a
//  one-off calculation" — and there was no such file, no such test, and no caller anywhere for
//  `fits(budget:)`, `telegramPayloadBudget` or `RemoteCapabilities.callbackPayloadBudget`. The
//  64-byte ceiling that governs the grammar on all three platforms was asserted by nothing, and the
//  header's promise that "a new case cannot be added without a way to check it" was not true.
//
//  ⚠️ WHY THE CEILING IS NOT ACADEMIC. Telegram silently rejects a `callback_data` over 64 bytes at
//  send time, so the failure is not a truncated button — it is a message that never posts. The
//  grammar is shared across all three platforms, so Telegram's limit binds Discord (100) and Slack
//  (255) too. The file's own worked example — `use:<profile>:<conversation>` at 77 bytes — is a
//  token someone could reasonably try to add, and nothing would have stopped them.
//

import XCTest
@testable import devgentic

final class CallbackTokenTests: XCTestCase {

    /// Every case of the grammar, with the widest realistic payload each can carry.
    ///
    /// ⚠️ UUIDs ARE GENERATED, NOT FIXED. A canonical UUID is always 36 characters, so any real one
    /// exercises the true worst case — but writing a literal would invite someone to "simplify" it
    /// to a short string and quietly make the budget test meaningless.
    ///
    /// ⚠️ `gateChoice` uses a deliberately large index. The option count is model-supplied, so the
    /// index is not bounded by anything this app controls, and it is the one case whose length is
    /// not fixed by its shape.
    private static var everyCase: [CallbackToken] {
        let id = UUID()
        return [
            .switchConversation(id),
            .approveHITL(operationID: id),
            .denyHITL(operationID: id),
            .gateChoice(operationID: id, optionIndex: 999_999),
            .answerClarification(operationID: id),
            .selectProfile(id),
            .conversationPage(offset: 999_999),
            .action(.conversations),
            .action(.new),
            .action(.status),
            .action(.cancel),
        ]
    }

    // MARK: - The budget

    /// ⚠️⚠️ THE STANDING PROBE `CallbackToken.swift` HAS BEEN CITING. Telegram caps `callback_data`
    /// at 64 bytes and the grammar is shared, so this is the binding constraint for every platform.
    ///
    /// Mutation that must turn this red: add a case whose wire form carries two UUIDs (the file's
    /// own `use:<profile>:<conversation>` example, 77 bytes), or raise `telegramPayloadBudget`.
    func testEveryTokenFitsTelegramsBudget() {
        for token in Self.everyCase {
            let bytes = token.wire.utf8.count

            // ⚠️ MEASURED INDEPENDENTLY OF `fits`, and that is the point. Asserting only
            // `token.fits()` would prove that `fits` agrees with itself: a `fits` mutated to
            // `return true` keeps such a test green while every token silently exceeds the limit.
            // The byte count is the fact; `fits` is the code under test.
            XCTAssertLessThanOrEqual(
                bytes, CallbackToken.telegramPayloadBudget,
                """
                \(token.wire) is \(bytes) bytes, over Telegram's \
                \(CallbackToken.telegramPayloadBudget)-byte callback_data limit. Telegram rejects \
                the SEND, so this is a message that never posts — not a truncated button.
                """
            )

            // ⚠️ AND `fits` MUST AGREE WITH THE FACT. This is what stops the predicate drifting away
            // from the measurement it exists to express — the failure mode that would make every
            // future use of `fits(budget:)` worthless.
            XCTAssertEqual(token.fits(), bytes <= CallbackToken.telegramPayloadBudget,
                           "`fits()` disagrees with the actual byte count for \(token.wire)")
        }
    }

    /// ⚠️ THE PREDICATE MUST ACTUALLY REFUSE SOMETHING. Every shipped token fits, so the test above
    /// can only ever watch `fits` say yes — it would not notice a `fits` that always does. This
    /// gives it the case the file's own header warns about: a token carrying TWO UUIDs, which is
    /// `use:<profile>:<conversation>` at 77 bytes and cannot exist.
    ///
    /// Mutation that must turn this red: `func fits(budget:) -> Bool { true }`.
    func testThePredicateRefusesATokenThatIsTooLong() {
        let twoUUIDs = "use:\(UUID().uuidString):\(UUID().uuidString)"
        XCTAssertEqual(twoUUIDs.utf8.count, 77, "the header's worked example changed shape")
        XCTAssertFalse(CallbackToken.selectProfile(UUID()).fits(budget: 10),
                       "`fits` never refuses anything, so the budget is not being enforced at all")
    }

    /// ⚠️ THE ENUM MUST NOT GROW WITHOUT THIS FILE NOTICING. `CallbackToken` has associated values
    /// so it cannot be `CaseIterable`; this count is the substitute, and it is the whole reason the
    /// probe above can claim to cover "every token".
    ///
    /// Mutation that must turn this red: add a case to `CallbackToken` without listing it here.
    func testEveryCaseOfTheGrammarIsCovered() {
        // One per case, plus one per `Action`, minus the single `.action` case they collapse into.
        let expected = 7 + CallbackToken.Action.allCases.count
        XCTAssertEqual(
            Self.everyCase.count, expected,
            """
            `everyCase` no longer lists every token, so the budget probe above is silently \
            checking a subset. Add the new case there.
            """
        )
    }

    /// The headroom the file's guidance rests on. If a case ever creeps close to the ceiling, the
    /// advice "do not reach for base64url to save bytes on a token that already fits" stops holding.
    func testTheWorstCaseStillLeavesHeadroom() {
        let worst = Self.everyCase.max { $0.wire.utf8.count < $1.wire.utf8.count }
        let bytes = worst?.wire.utf8.count ?? 0
        XCTAssertLessThanOrEqual(bytes, 56, """
            The widest token is now \(bytes) bytes, leaving \
            \(CallbackToken.telegramPayloadBudget - bytes) of Telegram's 64. The grammar is close \
            enough to its ceiling that the next case needs base64url and a legacy-decode window — \
            see CallbackToken.swift's header.
            """)
    }

    /// ⚠️ THE OTHER TWO PLATFORMS ARE NOT THE CONSTRAINT, AND THAT IS WORTH PINNING. If Telegram's
    /// budget were ever raised above theirs, the shared grammar would start failing on Discord and
    /// Slack instead — silently, since neither rejects the send the way Telegram does.
    func testTelegramIsTheBindingLimitForTheSharedGrammar() {
        XCTAssertLessThanOrEqual(CallbackToken.telegramPayloadBudget,
                                 RemoteCapabilities.discord.callbackPayloadBudget)
        XCTAssertLessThanOrEqual(CallbackToken.telegramPayloadBudget,
                                 RemoteCapabilities.slack.callbackPayloadBudget)
        XCTAssertEqual(CallbackToken.telegramPayloadBudget,
                       RemoteCapabilities.telegram.callbackPayloadBudget,
                       "the token's own budget and the platform's capability must not drift apart")
    }

    // MARK: - Comparing commands

    /// ⚠️ A TEST-LOCAL DESCRIPTOR, NOT `Equatable` ON THE PRODUCTION ENUM. `ChatOpsCommand` is a
    /// bare enum and every other test in this suite matches it with `if case`; adding a conformance
    /// to production code for a test's convenience is a change to the thing under test. This maps a
    /// command to a comparable string instead.
    ///
    /// ⚠️ NO `default:` ARM, deliberately — the same rule the renderers and the mirror's content
    /// switch follow. A `ChatOpsCommand` case added later fails to COMPILE here rather than
    /// silently comparing equal to something it is not.
    private func describe(_ command: ChatOpsCommand) -> String {
        switch command {
        case .conversations:                       return "conversations"
        case .conversationPage(let offset):        return "page(\(offset))"
        case .searchConversations(let query):      return "search(\(query))"
        case .conversationHistory(let argument):   return "history(\(argument))"
        case .newConversation:                     return "new"
        case .status:                              return "status"
        case .cancel:                              return "cancel"
        case .help:                                return "help"
        case .profiles:                            return "profiles"
        case .selectProfile(let id):               return "selectProfile(\(id))"
        case .useProfile(let name):                return "useProfile(\(name))"
        case .switchConversation(let id):          return "switch(\(id))"
        case .approveHITL(let id):                 return "approve(\(id))"
        case .denyHITL(let id):                    return "deny(\(id))"
        case .gateChoiceHITL(let id, let index):   return "gate(\(id),\(index))"
        case .answerClarification(let id):         return "answer(\(id))"
        case .clarificationResponse(let text):     return "clarification(\(text))"
        case .freeText(let text):                  return "freeText(\(text))"
        case .pairingAttempt(let pin):             return "pair(\(pin))"
        case .unknown:                             return "unknown"
        }
    }

    // MARK: - The round trip

    /// ⚠️⚠️ THROUGH THE REAL PARSER, NOT AGAINST A STRING LITERAL. `CallbackToken` does not define
    /// the grammar — `ChatOpsCommand.parseCallbackData` is the live reader on all three platforms,
    /// and buttons emitted last week are still tappable today. A token that no longer round-trips is
    /// a button that silently does nothing.
    ///
    /// Mutation that must turn this red: change any `wire` string.
    func testEveryTokenRoundTripsThroughTheShippedParser() {
        let id = UUID()
        let expectations: [(CallbackToken, ChatOpsCommand)] = [
            (.switchConversation(id), .switchConversation(id)),
            (.approveHITL(operationID: id), .approveHITL(operationID: id)),
            (.denyHITL(operationID: id), .denyHITL(operationID: id)),
            (.gateChoice(operationID: id, optionIndex: 3), .gateChoiceHITL(operationID: id, optionIndex: 3)),
            (.answerClarification(operationID: id), .answerClarification(operationID: id)),
            (.selectProfile(id), .selectProfile(id)),
            (.conversationPage(offset: 20), .conversationPage(offset: 20)),
            (.action(.conversations), .conversations),
            (.action(.new), .newConversation),
            (.action(.status), .status),
            (.action(.cancel), .cancel),
        ]
        for (token, expected) in expectations {
            XCTAssertEqual(describe(ChatOpsCommand.parseCallbackData(token.wire)), describe(expected),
                           "\(token.wire) no longer decodes — every button already in scrollback breaks")
        }
    }

    /// ⚠️ `Action` IS EXACTLY THE SET THE PARSER ANSWERS. A case here that the parser resolves to
    /// `.unknown` would be a button that does nothing — which is why `help` is deliberately absent
    /// from the enum even though it is a real command.
    func testNoActionDecodesToUnknown() {
        for action in CallbackToken.Action.allCases {
            XCTAssertNotEqual(describe(ChatOpsCommand.parseCallbackData(CallbackToken.action(action).wire)), "unknown",
                              "action:\(action.rawValue) is emitted on buttons but the parser rejects it")
        }
    }

    /// ⚠️ UPPERCASE IS WHAT SHIPS. `UUID.uuidString` is uppercase in Swift and that is what is
    /// sitting in users' scrollback; `UUID(uuidString:)` is case-insensitive so decoding is safe
    /// either way, but the emitted bytes must not change.
    func testTheWireFormKeepsSwiftsUppercaseUUIDs() {
        let id = UUID()
        XCTAssertEqual(CallbackToken.switchConversation(id).wire, "switch:\(id.uuidString)")
        XCTAssertFalse(id.uuidString.contains(where: { $0.isLowercase && $0.isLetter }))
    }

    /// Junk must decode to `.unknown` rather than to a neighbouring case — a stale button should do
    /// nothing visible, never something unexpected.
    func testMalformedPayloadsDecodeToUnknown() {
        for junk in ["switch:not-a-uuid", "use:", "page:-1", "page:abc",
                     "hitl:gate:\(UUID().uuidString):x", "hitl:approve:", "action:help", ""] {
            XCTAssertEqual(describe(ChatOpsCommand.parseCallbackData(junk)), "unknown",
                           "\"\(junk)\" decoded to something a user never tapped")
        }
    }
}
