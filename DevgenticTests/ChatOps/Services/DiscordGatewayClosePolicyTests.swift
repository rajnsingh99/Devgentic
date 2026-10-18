// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordGatewayClosePolicyTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

final class DiscordGatewayClosePolicyTests: XCTestCase {

    private typealias Policy = DiscordGatewayClosePolicy

    // MARK: - Fatal

    /// ⚠️ THE BUG THIS EXISTS FOR. `connectAndListen` caught every error and reconnected with
    /// backoff, forever — so a wrong or revoked bot token produced an infinite loop of identical
    /// failures, and the user was told nothing. Discord says exactly what is wrong in the close
    /// code; nothing read it.
    ///
    /// Mutation that must turn this red: return `.reconnect` for 4004.
    func testARejectedBotTokenIsFatalRatherThanRetriedForever() {
        guard case .fatal(let reason) = Policy.disposition(forCloseCode: 4004) else {
            return XCTFail("4004 is Discord rejecting the token — retrying cannot make it right")
        }
        XCTAssertTrue(reason.lowercased().contains("token"), """
            The reason is the only thing the user ever sees about this. It must name the token: \
            \(reason)
            """)
    }

    /// The most common real-world Discord setup failure: the bot exists, the token is fine, and
    /// Message Content Intent was never switched on in the Developer Portal.
    ///
    /// Mutation that must turn this red: return `.reconnect` for 4014.
    func testADisallowedPrivilegedIntentIsFatalAndNamesTheFix() {
        guard case .fatal(let reason) = Policy.disposition(forCloseCode: 4014) else {
            return XCTFail("4014 means a privileged intent is disabled — reconnecting never enables it")
        }
        XCTAssertTrue(reason.contains("Developer Portal"), "the user must be told where to go: \(reason)")
        XCTAssertTrue(reason.contains("Message Content"), "and which switch to flip: \(reason)")
    }

    /// Mutation that must turn this red: move any of these into the retryable default.
    func testEveryUnfixableCloseCodeStopsTheClient() {
        for code in [4004, 4010, 4011, 4012, 4013, 4014] {
            guard case .fatal(let reason) = Policy.disposition(forCloseCode: code) else {
                return XCTFail("close code \(code) cannot be fixed by reconnecting, so it must be fatal")
            }
            XCTAssertFalse(reason.isEmpty, "close code \(code) must explain itself")
        }
    }

    // MARK: - Retryable

    /// ⚠️ THE OVER-CORRECTION THIS FORBIDS. Treating every close as fatal would turn a dropped
    /// Wi-Fi connection into a permanently dead Discord bridge. Code 0 is the no-close-frame case —
    /// exactly what a network drop looks like — and it must stay retryable.
    ///
    /// Mutation that must turn this red: make the default arm `.fatal`.
    func testTransientAndUnknownClosesStillReconnect() {
        for code in [0, 1000, 1001, 1006, 1011, 4000, 4001, 4002, 4003, 4005, 4008, 4999] {
            XCTAssertEqual(Policy.disposition(forCloseCode: code), .reconnect,
                           "close code \(code) is retryable and must not kill the bridge")
        }
    }

    /// ⚠️ These reconnect, but resuming would be closed again immediately: the session id and
    /// sequence Discord just rejected are exactly what a RESUME replays. Without clearing them the
    /// "retry" is a tight loop that looks like a flaky network.
    ///
    /// Mutation that must turn this red: fold 4007/4009 into the plain `.reconnect` default.
    func testAnInvalidatedSessionReconnectsWithoutTryingToResumeIt() {
        XCTAssertEqual(Policy.disposition(forCloseCode: 4007), .reconnectWithNewSession,
                       "4007 is an invalid sequence — resuming replays it")
        XCTAssertEqual(Policy.disposition(forCloseCode: 4009), .reconnectWithNewSession,
                       "4009 is a timed-out session — resuming it cannot succeed")
    }

    // MARK: - Wiring

    /// ⚠️ THE TEST THAT MATTERS. Everything above passes with the policy sitting unused.
    ///
    /// Mutations that must turn this red: delete the `closeCode` read; stop calling the policy;
    /// remove `break connectLoop` from the fatal arm (the loop then classifies correctly and
    /// retries anyway); or drop the session reset from the `.reconnectWithNewSession` arm.
    func testTheClientActsOnThePolicyRatherThanRetryingEverything() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/DiscordGatewayClient.swift")

        XCTAssertTrue(source.contains("webSocket?.closeCode.rawValue"), """
            The client must read the close code off the TASK. The thrown error is a generic \
            NSPOSIXErrorDomain 57 for every server-side close and cannot distinguish a rejected \
            token from a dropped network.
            """)
        XCTAssertTrue(source.contains("DiscordGatewayClosePolicy.disposition(forCloseCode:"),
                      "the client must consult the policy rather than retrying everything")

        // Slice the fatal arm specifically: a `break` anywhere in the method is not evidence that
        // the FATAL case is the one that stops.
        guard let fatalStart = source.range(of: "case .fatal(let explanation):"),
              let nextCase = source.range(of: "case .reconnectWithNewSession:",
                                          range: fatalStart.upperBound..<source.endIndex) else {
            return XCTFail("the fatal arm is gone from connectAndListen")
        }
        let fatalArm = String(source[fatalStart.upperBound..<nextCase.lowerBound])
        XCTAssertTrue(fatalArm.contains("break connectLoop"), """
            The fatal arm classifies the close correctly and then reconnects anyway. Classifying \
            without stopping is the original bug with extra steps. Arm:\n\(fatalArm)
            """)

        guard let freshStart = source.range(of: "case .reconnectWithNewSession:"),
              let reconnectCase = source.range(of: "case .reconnect:",
                                               range: freshStart.upperBound..<source.endIndex) else {
            return XCTFail("the new-session arm is gone")
        }
        let freshArm = String(source[freshStart.upperBound..<reconnectCase.lowerBound])
        for cleared in ["sessionID = nil", "lastSequence = nil", "resumeGatewayURL = nil"] {
            XCTAssertTrue(freshArm.contains(cleared), """
                \(cleared) is missing, so the next connection sends a RESUME carrying the state \
                Discord just rejected and is closed again at once.
                """)
        }
        XCTAssertFalse(freshArm.contains("break connectLoop"),
                       "an invalidated session is recoverable — it must not stop the bridge")
    }

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Services
            .deletingLastPathComponent()   // ChatOps
            .deletingLastPathComponent()   // DevgenticTests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
