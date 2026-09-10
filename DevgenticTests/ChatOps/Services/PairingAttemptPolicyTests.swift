// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PairingAttemptPolicyTests.swift
//  DevgenticTests
//
//  ⚠️ THE VALUE OF THIS CLASSIFIER IS ENTIRELY IN ITS FALSE-POSITIVE RATE. A detector that fires on
//  ordinary conversation is worse than no detector: it buries the one event that matters in exactly
//  the traffic it needs to stand out from, and the three bare `continue`s it replaces were
//  defensible precisely because logging everything would have done that.
//

import XCTest
@testable import devgentic

final class PairingAttemptPolicyTests: XCTestCase {

    private let pin = "482913"

    // MARK: - The three outcomes

    /// Mutation that must turn this red: return `.wrongPIN` for a match.
    func testTheExpectedPINMatches() {
        XCTAssertEqual(PairingAttemptPolicy.classify("PAIR \(pin)", expectedPIN: pin), .matched)
    }

    /// ⚠️ NORMALIZATION MUST MATCH WHAT THE SERVICES ALREADY APPLIED, or this changes who can pair.
    /// All three did `uppercased().trimmingCharacters(in: .whitespaces)` before comparing; a
    /// classifier that normalized differently would either reject a message they accepted or, worse,
    /// call a real failed attempt `.matched` and never report it.
    ///
    /// Mutation that must turn this red: drop `uppercased()` or the trim from `normalize`.
    func testMatchingSurvivesTheSameNormalizationTheServicesUsed() {
        for variant in ["pair \(pin)", "  PAIR \(pin)  ", "Pair \(pin)", "\tPAIR \(pin)\t"] {
            XCTAssertEqual(PairingAttemptPolicy.classify(variant, expectedPIN: pin), .matched,
                           "\"\(variant)\" used to pair and must still pair")
        }
    }

    /// ⚠️⚠️ THE EVENT THE WHOLE CHANGE EXISTS TO SURFACE. Every one of these was a bare `continue`.
    ///
    /// Mutation that must turn this red: return `.unrelated` for a wrong PIN.
    func testAWrongPINIsReportedAsAnAttempt() {
        for attempt in ["PAIR 000000", "PAIR 482914", "pair 123456", "  PAIR 999999"] {
            XCTAssertEqual(PairingAttemptPolicy.classify(attempt, expectedPIN: pin), .wrongPIN,
                           "\"\(attempt)\" is someone trying to pair and must leave a trace")
        }
    }

    /// ⚠️ MALFORMED ATTEMPTS STILL COUNT. Requiring six well-formed digits would miss precisely the
    /// attempts worth seeing — someone fumbling the format is still someone trying to pair.
    func testAMalformedPairCommandIsStillAnAttempt() {
        for attempt in ["PAIR 12345", "PAIR abc123", "PAIR 0", "pair xyz"] {
            XCTAssertEqual(PairingAttemptPolicy.classify(attempt, expectedPIN: pin), .wrongPIN,
                           "a fumbled format is still someone trying to pair")
        }
    }

    /// ⚠️ THE WORD ALONE IS NOT AN ATTEMPT, and the reason is the normalization rather than a
    /// judgement call: "PAIR " trims to "PAIR", which no longer carries the trailing space that
    /// makes the prefix a command. The trim is not negotiable — it is exactly what the three
    /// services already applied before comparing, so changing it would change who can pair.
    ///
    /// ⚠️ PINNED BECAUSE I GOT IT WRONG FIRST. My initial version asserted "PAIR " was `.wrongPIN`
    /// by checking the prefix on the RAW string, while the classifier checks the NORMALIZED one.
    /// The classifier was right: a bare "PAIR" carries no guess, and logging it would add noise for
    /// no signal.
    func testTheWordPairAloneIsNotAnAttempt() {
        for message in ["PAIR", "PAIR ", "  pair  "] {
            XCTAssertEqual(PairingAttemptPolicy.classify(message, expectedPIN: pin), .unrelated,
                           "a bare word normalizes to no command and carries no guess")
        }
    }

    // MARK: - False positives, which are the whole risk

    /// ⚠️⚠️ THE TEST THAT PROTECTS THE SIGNAL. A pairing window is five minutes of a live chat and
    /// most of what arrives is conversation. If any of these produced a line, the log would fill
    /// with noise during exactly the window an operator needs to read it.
    ///
    /// Mutation that must turn this red: drop the trailing space from `commandPrefix`, which makes
    /// "PAIRING SCHEDULED FOR FRIDAY" a failed attempt.
    func testOrdinaryConversationIsNotReportedAsAnAttempt() {
        let chatter = [
            "lunch at 1?",
            "Pairing scheduled for Friday",
            "PAIRING SCHEDULED FOR FRIDAY",
            "can you repair the build",
            "REPAIR 482913",
            "what's the pin",
            "",
            "   ",
        ]
        for message in chatter {
            XCTAssertEqual(PairingAttemptPolicy.classify(message, expectedPIN: pin), .unrelated,
                           "\"\(message)\" is ordinary chatter and must not be logged as an attempt")
        }
    }

    /// ⚠️ `REPAIR <pin>` IS THE SHARP CASE — it contains the exact command and PIN as a substring.
    /// A `contains` check instead of `hasPrefix` would both log it as an attempt AND, if the match
    /// used `contains` too, let it PAIR. Pinned separately because it is the one that would slip
    /// through a reviewer.
    func testASubstringMatchNeitherPairsNorReportsAnAttempt() {
        XCTAssertEqual(PairingAttemptPolicy.classify("REPAIR \(pin)", expectedPIN: pin), .unrelated)
        XCTAssertEqual(PairingAttemptPolicy.classify("please PAIR \(pin) now", expectedPIN: pin), .unrelated)
    }

    /// ⚠️ THE CLASSIFIER ANSWERS FOR THE WINDOW IT IS GIVEN. Three services run three separate
    /// pairing windows; a PIN from one must not match another's.
    func testAPINFromADifferentWindowDoesNotMatch() {
        XCTAssertEqual(PairingAttemptPolicy.classify("PAIR \(pin)", expectedPIN: "111111"), .wrongPIN)
    }

    // MARK: - The lockout

    private func spend(_ ledger: inout PairingAttemptLedger, _ origin: String, _ times: Int) {
        for _ in 0..<times { _ = ledger.recordFailure(from: origin) }
    }

    /// ⚠️ THE CAP ITSELF. One origin gets `attemptsPerOrigin` guesses and then nothing.
    ///
    /// Mutation that must turn this red: `>` instead of `>=` in `isBlocked`.
    func testAnOriginIsBlockedOnceItSpendsItsAttempts() {
        var ledger = PairingAttemptLedger()
        XCTAssertFalse(ledger.isBlocked("alice"))
        spend(&ledger, "alice", PairingAttemptLedger.attemptsPerOrigin - 1)
        XCTAssertFalse(ledger.isBlocked("alice"), "the last attempt must still be allowed")
        _ = ledger.recordFailure(from: "alice")
        XCTAssertTrue(ledger.isBlocked("alice"))
    }

    /// ⚠️⚠️ THE PROPERTY THE WHOLE DESIGN EXISTS FOR, AND THE REASON THE OBVIOUS LOCKOUT IS WORSE
    /// THAN NONE. "Abort the window after N failures" would let a stranger end the user's pairing
    /// with ten messages — turning an attack that needs ~9,000 guesses in 300 seconds into one that
    /// needs ten. Telegram bots are discoverable by username, so that is not a theoretical stranger.
    ///
    /// One origin burning its attempts must leave every other origin untouched.
    ///
    /// Mutation that must turn this red: key the ledger on anything shared — a constant, the
    /// channel, the window — instead of the sender.
    func testOneOriginBurningItsAttemptsCannotLockOutAnother() {
        var ledger = PairingAttemptLedger()
        spend(&ledger, "attacker", PairingAttemptLedger.attemptsPerOrigin * 3)

        XCTAssertTrue(ledger.isBlocked("attacker"))
        XCTAssertFalse(ledger.isBlocked("the-actual-user"),
                       "a stranger's guesses must not stop the user pairing — that trade is backwards")
        XCTAssertEqual(ledger.recordFailure(from: "the-actual-user"),
                       .listening(remaining: PairingAttemptLedger.attemptsPerOrigin - 1))
    }

    /// ⚠️ A BLOCKED ORIGIN MUST NOT PAIR EVEN WITH THE CORRECT PIN. A lockout that still honours a
    /// lucky guess is not a lockout — which is why the services check `isBlocked` BEFORE acting on
    /// the classification rather than after.
    ///
    /// Mutation that must turn this red: move the `isBlocked` check below the `.matched` handling
    /// in any of the three services.
    func testTheBlockedCheckPrecedesThePINComparisonInEveryService() throws {
        // ⚠️ ANCHORED ON THE AUTHORIZATION WRITE, NOT ON A COMMENT. My first version looked for
        // "// PIN matched", which only two of the three files happen to carry — so it failed on
        // Slack for a reason that had nothing to do with the property. A comment can also be
        // deleted without changing behaviour; the line that grants access cannot.
        let services = [
            ("ChatOpsPairingService", "config.authorizedChatID = "),
            ("DiscordPairingService", "config.discordAuthorizedChannelID = "),
            ("SlackPairingService", "config.slackAuthorizedChannelID = "),
        ]
        for (service, authorizes) in services {
            let source = try Self.source("Devgentic/ChatOps/Services/\(service).swift")
            let blocked = try XCTUnwrap(source.range(of: "ledger.isBlocked("),
                                        "\(service) no longer consults the lockout at all")
            let paired = try XCTUnwrap(source.range(of: authorizes),
                                       "\(service) no longer authorizes anything — anchor is stale")
            XCTAssertLessThan(blocked.lowerBound, paired.lowerBound, """
                \(service) acts on a matched PIN before checking whether the origin is blocked, \
                so a spent origin can still pair by guessing correctly.
                """)
        }
    }

    /// The counters that make a burst legible: ten failures from one chat is someone struggling,
    /// ten from ten chats is not.
    func testTheLedgerDistinguishesOneStrugglerFromManyGuessers() {
        var struggler = PairingAttemptLedger()
        spend(&struggler, "alice", 6)
        XCTAssertEqual(struggler.totalFailures, 6)
        XCTAssertEqual(struggler.distinctOrigins, 1)

        var swarm = PairingAttemptLedger()
        for i in 0..<6 { spend(&swarm, "guest-\(i)", 1) }
        XCTAssertEqual(swarm.totalFailures, 6)
        XCTAssertEqual(swarm.distinctOrigins, 6, "the same total from six origins is a different event")
    }

    /// ⚠️ THE REMAINING COUNT IS WHAT THE LOG REPORTS, so it must count down truthfully rather than
    /// being decorative.
    func testTheRemainingCountCountsDown() {
        var ledger = PairingAttemptLedger()
        for spent in 1..<PairingAttemptLedger.attemptsPerOrigin {
            XCTAssertEqual(ledger.recordFailure(from: "bob"),
                           .listening(remaining: PairingAttemptLedger.attemptsPerOrigin - spent))
        }
        XCTAssertEqual(ledger.recordFailure(from: "bob"), .blocked)
    }

    /// ⚠️ NO WINDOW-WIDE CAP, DELIBERATELY — a global backstop reintroduces the denial of service
    /// with a larger number in front of it. A fresh ledger is a fresh window.
    func testANewWindowStartsClean() {
        var first = PairingAttemptLedger()
        spend(&first, "alice", PairingAttemptLedger.attemptsPerOrigin)
        XCTAssertTrue(first.isBlocked("alice"))

        let second = PairingAttemptLedger()
        XCTAssertFalse(second.isBlocked("alice"), "restarting pairing must clear the lockout")
        XCTAssertEqual(second.totalFailures, 0)
    }

    private static func source(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
