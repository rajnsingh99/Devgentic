// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  PairingPrefixParsingTests.swift
//  devgenticTests
//
//  A sentence that starts with the word "pair" is a prompt, not a pairing attempt.
//
//  ⚠️⚠️ THE FAILURE THIS PINS (BR-5). `ChatOpsCommand.parse` accepted `PAIR ` followed by ANYTHING
//  non-empty, case-insensitively. So "Pair these two CSVs on the id column and write the result to
//  out.csv" parsed as `.pairingAttempt("THESE TWO CSVS ON…")`, cleared the tier gate (pairing is
//  allowed at every tier), and was then discarded by all three bridges without a reply: no answer,
//  no error, not even a typing indicator. `parseSlack` and `parseDiscord` both delegate here for
//  plain text, so this was every platform, not just Telegram.
//
//  ⚠️ THIS IS NOT `PairingAttemptPolicy`, WHICH IS DELIBERATELY LOOSER. That classifier runs only
//  inside an open pairing window and treats `PAIR <anything>` as a failed attempt on purpose —
//  someone fumbling the format is still someone trying to pair, and the lockout needs to see them.
//  Tightening it would be a bug; tightening the always-on command parser is the fix.
//

import XCTest
@testable import devgentic

final class PairingPrefixParsingTests: XCTestCase {

    private func parse(_ text: String) -> ChatOpsCommand {
        ChatOpsCommand.parse(text: text, callbackData: nil)
    }

    // MARK: - Prompts must reach the agent

    /// ⚠️ THE REGRESSION, verbatim from the audit.
    func testASentenceBeginningWithPairReachesTheAgent() {
        let prompt = "Pair these two CSVs on the id column and write the result to out.csv"
        guard case .freeText(let text) = parse(prompt) else {
            return XCTFail("""
                "\(prompt)" was parsed as something other than free text, so it never reaches the \
                agent — and every bridge drops it without a reply. Got: \(parse(prompt))
                """)
        }
        XCTAssertEqual(text, prompt, "the prompt must reach the agent unaltered")
    }

    func testOtherPairPhrasingsAlsoReachTheAgent() {
        for prompt in ["pair the sockets with their handlers",
                       "PAIR PROGRAMMING notes for tomorrow",
                       "Pair 12345 is not a real pin",          // five digits
                       "pair 1234567 with the other id",        // seven digits
                       "Pair abc123 with the fixture",
                       "pair 123456 and then summarise it"] {   // six digits, but not the whole remainder
            guard case .freeText = parse(prompt) else {
                return XCTFail("\"\(prompt)\" did not reach the agent: \(parse(prompt))")
            }
        }
    }

    // MARK: - A real PIN must still pair

    /// ⚠️ `generatePIN()` mints `Int.random(in: 100_000...999_999)`, so a genuine attempt is always
    /// exactly six ASCII digits and nothing else.
    func testARealPINIsStillRecognised() {
        for text in ["PAIR 123456", "pair 654321", "  Pair 100000  "] {
            guard case .pairingAttempt(let pin) = parse(text) else {
                return XCTFail("\"\(text)\" is a real pairing attempt and was not recognised: \(parse(text))")
            }
            XCTAssertEqual(pin.count, 6)
            XCTAssertTrue(pin.allSatisfy(\.isNumber))
        }
    }

    /// ⚠️ `Character.isNumber` is true for Arabic-Indic and other non-ASCII numerals, which a PIN
    /// never contains — so the digits must be ASCII or a lookalike would be accepted as a PIN.
    func testNonASCIINumeralsAreNotAPIN() {
        guard case .freeText = parse("PAIR ١٢٣٤٥٦") else {
            return XCTFail("non-ASCII numerals were accepted as a pairing PIN")
        }
    }

    /// A bare "PAIR" with nothing after it is not a pairing attempt either.
    func testABarePairWordIsJustText() {
        guard case .freeText = parse("pair") else {
            return XCTFail("a lone \"pair\" should reach the agent")
        }
    }

    // MARK: - The looser classifier is untouched

    /// ⚠️ `PairingAttemptPolicy` must stay loose: inside a pairing window, a fumbled format is still
    /// an attempt, and the per-origin lockout depends on seeing it. Tightening both would blind it.
    func testTheLockoutClassifierStillSeesAFumbledAttempt() {
        XCTAssertEqual(PairingAttemptPolicy.classify("PAIR 12345", expectedPIN: "123456"), .wrongPIN,
                       "a five-digit attempt must still be counted by the lockout")
        XCTAssertEqual(PairingAttemptPolicy.classify("PAIR abc123", expectedPIN: "123456"), .wrongPIN)
        XCTAssertEqual(PairingAttemptPolicy.classify("lunch at 1?", expectedPIN: "123456"), .unrelated)
        XCTAssertEqual(PairingAttemptPolicy.classify("PAIR 123456", expectedPIN: "123456"), .matched)
    }

    // MARK: - Wiring

    /// All three platforms share this parser for plain text, so the fix must cover all three.
    func testSlackAndDiscordDelegatePlainTextToThisParser() {
        let prompt = "Pair these two CSVs on the id column"
        guard case .freeText = ChatOpsCommand.parseSlack(text: prompt) else {
            return XCTFail("Slack still swallows the prompt")
        }
        guard case .freeText = ChatOpsCommand.parseDiscord(text: prompt) else {
            return XCTFail("Discord still swallows the prompt")
        }
    }

    /// ⚠️ A PIN reaching `routeCommand` means no pairing window is open. Both bridges must name that
    /// case rather than reporting it through the `[CHATOPS/SILENT]` unknown-command arm, which told
    /// the user the bot might be dead.
    func testBothBridgesNameThePairingAttemptCaseExplicitly() throws {
        for path in ["Devgentic/ChatOps/Services/SlackChatOpsBridge.swift",
                     "Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            XCTAssertTrue(source.contains("case .pairingAttempt:"), """
                \(path) has no explicit `.pairingAttempt` arm, so a PIN sent outside a pairing window \
                falls into the silent-drop default and is reported as an unknown command.
                """)
        }
    }
}
