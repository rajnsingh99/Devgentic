// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteIntentParityTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class RemoteIntentParityTests: XCTestCase {

    /// `ChatOpsCommand` is not `Equatable`, and making it so would be an unrelated production
    /// change, so parity is compared on a label. Payload-carrying cases include their payload —
    /// a labeller that collapsed `.freeText("a")` and `.freeText("b")` would make this test vacuous.
    private func label(_ command: ChatOpsCommand) -> String {
        switch command {
        case .conversations:                      return "conversations"
        case .newConversation:                    return "newConversation"
        case .status:                             return "status"
        case .cancel:                             return "cancel"
        case .help:                               return "help"
        case .switchConversation(let id):         return "switch(\(id))"
        case .conversationPage(let offset):       return "page(\(offset))"
        case .profiles:                           return "profiles"
        case .selectProfile(let id):              return "selectProfile(\(id))"
        case .useProfile(let name):               return "useProfile(\(name))"
        case .searchConversations(let query):     return "search(\(query))"
        case .conversationHistory(let arg):       return "history(\(arg))"
        case .answerClarification(let id):        return "answer(\(id))"
        case .approveHITL(let id):                return "approve(\(id))"
        case .denyHITL(let id):                   return "deny(\(id))"
        case .gateChoiceHITL(let id, let index):  return "gate(\(id),\(index))"
        case .clarificationResponse(let text):    return "clarification(\(text))"
        case .freeText(let text):                 return "freeText(\(text))"
        case .pairingAttempt(let pin):            return "pairing(\(pin))"
        case .unknown:                            return "unknown"
        }
    }

    // MARK: - Slash-command parity

    /// Every alias of every verb must mean the same thing on all three platforms.
    ///
    /// Mutation that must turn this red: remove an alias from `ChatOpsVerb.aliases`, or give one
    /// entry point its own switch again.
    func testEveryVerbAliasMeansTheSameThingOnAllThreePlatforms() {
        for verb in ChatOpsVerb.allCases {
            for alias in verb.aliases {
                let expected = label(verb.command(argument: ""))

                let telegram = label(ChatOpsCommand.parse(text: "/\(alias)", callbackData: nil))
                let discord = label(ChatOpsCommand.parseDiscord(slashCommandName: alias))
                let slack = label(ChatOpsCommand.parseSlack(slashCommand: "/\(alias)"))

                XCTAssertEqual(telegram, expected, "Telegram disagrees on /\(alias)")
                XCTAssertEqual(discord, expected, "Discord disagrees on \(alias)")
                XCTAssertEqual(slack, expected, "Slack disagrees on /\(alias)")
            }
        }
    }

    /// The text path is shared, so a slash verb typed as a MESSAGE must resolve identically on all
    /// three — including on Discord and Slack, where it arrives as plain text rather than as a
    /// registered command.
    func testASlashVerbTypedAsPlainTextResolvesIdenticallyEverywhere() {
        for verb in ChatOpsVerb.allCases {
            let typed = "/\(verb.canonicalName)"
            let expected = label(verb.command(argument: ""))
            XCTAssertEqual(label(ChatOpsCommand.parse(text: typed, callbackData: nil)), expected)
            XCTAssertEqual(label(ChatOpsCommand.parseDiscord(text: typed)), expected)
            XCTAssertEqual(label(ChatOpsCommand.parseSlack(text: typed)), expected)
        }
    }

    /// Case and surrounding whitespace must not change the meaning on any platform. This is the
    /// divergence the shared table closed: Telegram lowercased, Discord and Slack did not.
    ///
    /// Mutation that must turn this red: drop `.lowercased()` or the trim from
    /// `ChatOpsVerbTable.verb(forSlashCommandName:)`.
    func testSlashCommandsAreCaseInsensitiveAndTrimmedOnEveryPlatform() {
        for raw in ["STATUS", " status ", "Status", "/STATUS", " /Status "] {
            XCTAssertEqual(label(ChatOpsCommand.parseDiscord(slashCommandName: raw)), "status",
                           "Discord rejected \"\(raw)\"")
            XCTAssertEqual(label(ChatOpsCommand.parseSlack(slashCommand: raw)), "status",
                           "Slack rejected \"\(raw)\"")
        }
        for raw in ["/STATUS", " /status ", "/Status"] {
            XCTAssertEqual(label(ChatOpsCommand.parse(text: raw, callbackData: nil)), "status",
                           "Telegram rejected \"\(raw)\"")
        }
    }

    // MARK: - The asymmetry that must NOT be collapsed

    /// ⚠️ A bare verb with no leading slash is a MESSAGE, not a command. If the table ever accepts
    /// it, a user typing "status" or "new" to their agent gets a command instead of an answer.
    ///
    /// Mutation that must turn this red: make `verb(forSlashPrefixedText:)` treat the slash as
    /// optional — the most natural "simplification" of the two entry points into one.
    func testABareVerbWithNoSlashIsAMessageNotACommand() {
        for verb in ChatOpsVerb.allCases {
            let bare = verb.canonicalName
            XCTAssertEqual(label(ChatOpsCommand.parse(text: bare, callbackData: nil)), "freeText(\(bare))",
                           "\"\(bare)\" typed as a message was swallowed as a command")
            XCTAssertNil(ChatOpsVerbTable.verb(forSlashPrefixedText: bare))
        }
    }

    // MARK: - Callback parity

    /// All three entry points hand button payloads to the same `parseCallbackData`, so every token
    /// must resolve identically whether it arrived as Telegram `callback_data`, a Discord
    /// `custom_id` or a Slack `action_id`.
    func testEveryCallbackTokenResolvesIdenticallyOnAllThreePlatforms() {
        let id = UUID()
        let tokens: [CallbackToken] = [
            .switchConversation(id),
            .approveHITL(operationID: id),
            .denyHITL(operationID: id),
            .gateChoice(operationID: id, optionIndex: 2),
        ] + CallbackToken.Action.allCases.map(CallbackToken.action)

        for token in tokens {
            let telegram = label(ChatOpsCommand.parse(text: nil, callbackData: token.wire))
            let discord = label(ChatOpsCommand.parseDiscord(customID: token.wire))
            let slack = label(ChatOpsCommand.parseSlack(actionID: token.wire))

            XCTAssertEqual(telegram, discord, "Telegram and Discord disagree on \(token.wire)")
            XCTAssertEqual(discord, slack, "Discord and Slack disagree on \(token.wire)")
            XCTAssertNotEqual(telegram, "unknown", "\(token.wire) is an inert button on every platform")
        }
    }

    // MARK: - Clarification parity

    /// The clarification fallback is part of the shared text path, so it must behave identically on
    /// all three — which is what makes the C8 fix (deleting the dead Discord and Slack flags) a
    /// change to the BRIDGES only, with no parser work. Slice 4 then narrowed what it swallows.
    func testTheClarificationFallbackBehavesIdenticallyOnAllThreePlatforms() {
        let answer = "the second one"
        XCTAssertEqual(label(ChatOpsCommand.parse(text: answer, callbackData: nil, awaitingClarification: true)),
                       "clarification(\(answer))")
        XCTAssertEqual(label(ChatOpsCommand.parseDiscord(text: answer, awaitingClarification: true)),
                       "clarification(\(answer))")
        XCTAssertEqual(label(ChatOpsCommand.parseSlack(text: answer, awaitingClarification: true)),
                       "clarification(\(answer))")

        // ⚠️ THE DEFECT THIS ONCE PINNED IS NOW CLOSED, AND THE OLD EXPECTATION IS KEPT IN WORDS SO
        // THE CHANGE IS LEGIBLE. It asserted `"clarification(/cancel)"` and carried a note that
        // "while a clarification is pending, `/cancel` is swallowed as the answer on every
        // platform, so a remote user cannot abort a parked run… this pins the current behaviour so
        // that change is visible when it lands." Slice 4 landed it: the verb table is now consulted
        // BEFORE the clarification fallback.
        //
        // Mutation that must turn this red: move the `if awaitingClarification` branch back above
        // the `ChatOpsVerbTable.parse` call in `ChatOpsCommand.parse`.
        for parsed in [
            label(ChatOpsCommand.parse(text: "/cancel", callbackData: nil, awaitingClarification: true)),
            label(ChatOpsCommand.parseDiscord(text: "/cancel", awaitingClarification: true)),
            label(ChatOpsCommand.parseSlack(text: "/cancel", awaitingClarification: true)),
        ] {
            XCTAssertEqual(parsed, "cancel", """
                A parked run must remain cancellable from chat. While the clarification branch ran \
                first, the one command meant to end the wait was consumed as the answer to it — \
                which RESUMED the run instead of stopping it.
                """)
        }

        // ⚠️ `/skip` must still reach the clarification branch. It is not a verb, so the table
        // declines it and it falls through — the reorder must not turn the skip affordance into an
        // unrecognised command.
        XCTAssertEqual(label(ChatOpsCommand.parse(text: "/skip", callbackData: nil, awaitingClarification: true)),
                       "clarification()")

        // ⚠️ And an ANSWER that merely looks like a command still answers. The table matches known
        // verbs only, so a filesystem path is not mistaken for one.
        XCTAssertEqual(label(ChatOpsCommand.parse(text: "/usr/local/bin", callbackData: nil, awaitingClarification: true)),
                       "clarification(/usr/local/bin)")
    }

    // MARK: - The table itself

    /// ⚠️ PINNED AS LITERALS, NOT DERIVED FROM THE TABLE. The parity test above iterates
    /// `verb.aliases`, so DELETING an alias silently reduces its coverage instead of failing it —
    /// a mutation proved exactly that. Only an independent expectation catches a shrinking table,
    /// and `convos` / `stop` / `start` are aliases real users have in their muscle memory.
    ///
    /// Mutation that must turn this red: remove any alias from `ChatOpsVerb.aliases`.
    func testTheAliasSetIsExactlyWhatTheShippedSwitchesAccepted() {
        let expected: [ChatOpsVerb: Set<String>] = [
            .conversations:   ["conversations", "convos"],
            .newConversation: ["new"],
            .status:          ["status"],
            .cancel:          ["cancel", "stop"],
            .help:            ["help", "start"],
            .profiles:        ["profiles"],
            .use:             ["use"],
            // ⚠️ Added with the verb in slice 5. `find` is here because it is what users reach for
            // before `search`, and this literal is the only thing that would notice it vanishing —
            // the parity test above iterates `verb.aliases`, so deleting one shrinks its coverage
            // rather than failing it.
            .search:          ["search", "find"],
            .history:         ["history"],
        ]
        for verb in ChatOpsVerb.allCases {
            XCTAssertEqual(Set(verb.aliases), expected[verb], """
                \(verb)'s aliases changed. These are the strings the three shipped switches \
                accepted; dropping one silently stops answering a command users already type.
                """)
        }
    }

    func testCanonicalNamesAreTheirOwnFirstAlias() {
        for verb in ChatOpsVerb.allCases {
            XCTAssertEqual(verb.aliases.first, verb.canonicalName,
                           "\(verb) registers \(verb.canonicalName) but does not accept it")
        }
    }

    /// Two verbs sharing an alias would make resolution depend on `allCases` ordering.
    func testNoAliasIsClaimedByTwoVerbs() {
        let all = ChatOpsVerb.allCases.flatMap(\.aliases)
        XCTAssertEqual(Set(all).count, all.count, "duplicate alias in the verb table: \(all)")
    }
}
