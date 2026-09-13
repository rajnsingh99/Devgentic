// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsTerminalFailureTests.swift
//  devgenticTests
//
//  Telling "the user asked me to stop" apart from "this will never work again".
//
//  ⚠️⚠️ THE FAILURE THIS PINS. Both listeners ended their stream the same way whether they were
//  stopped deliberately or killed by an error no retry could clear, so `ChatOpsBridge` and
//  `SlackChatOpsBridge` logged one `.info` line and flipped `isRunning` for both. Nothing in the app
//  had EVER written `ChatOpsConnectionState.error`, even though `ChatOpsSettingsView.statusColor`
//  carried a red arm waiting for it. A revoked bot token therefore killed remote control for the
//  life of the process while the Pairing card kept a green dot and the word "Active", and the only
//  recovery was quitting the app. Invariant 26 records the same fix for the Discord Gateway; neither
//  Telegram nor Slack had received it.
//

import XCTest
@testable import devgentic

final class ChatOpsTerminalFailureTests: XCTestCase {

    // MARK: - Telegram classification

    func testTelegramTreatsCredentialAndConflictErrorsAsTerminal() {
        for code in [401, 403, 409] {
            XCTAssertNotNil(
                TelegramListener.terminalReason(code: code, description: "d"),
                "\(code) needs the user to act; retrying it forever burns a request per backoff interval and can never succeed."
            )
        }
    }

    /// ⚠️ 409 IS THE ONE THAT WAS MISSING, and it was the quieter half of the bug. Telegram answers
    /// `getUpdates` with 409 Conflict whenever a webhook is registered on the bot or a second client
    /// is polling it. Neither resolves on its own, but 409 fell through to the generic retry arm, so
    /// the bridge looked alive, burned a request a minute, and delivered nothing at all.
    func testTelegramConflictNamesBothOfItsCauses() throws {
        let reason = try XCTUnwrap(TelegramListener.terminalReason(code: 409, description: "Conflict: terminated by other getUpdates"))
        XCTAssertTrue(reason.lowercased().contains("webhook"),
                      "a user who set a webhook cannot act on a message that does not mention one")
        XCTAssertTrue(reason.contains("Conflict: terminated by other getUpdates"),
                      "Telegram's own description carries which cause it is and must reach the user")
    }

    func testTelegramKeepsRetryableErrorsOnTheBackoff() {
        for code in [429, 500, 502, 503, -1] {
            XCTAssertNil(
                TelegramListener.terminalReason(code: code, description: "d"),
                "\(code) clears on its own; killing the listener for it would turn a blip into an outage."
            )
        }
    }

    // MARK: - Slack classification

    func testSlackTreatsRejectedAppTokensAsTerminal() {
        for code in ["invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive"] {
            XCTAssertNotNil(
                SlackSocketClient.terminalReason(slackErrorCode: code),
                "`\(code)` means this app token will never open a socket again."
            )
        }
    }

    func testSlackTreatsMissingScopeAsTerminal() {
        XCTAssertNotNil(SlackSocketClient.terminalReason(slackErrorCode: "missing_scope"))
        XCTAssertNotNil(SlackSocketClient.terminalReason(slackErrorCode: "no_permission"))
    }

    /// ⚠️ DELIBERATELY NOT A CATCH-ALL ON "ANYTHING AUTH-SHAPED". `ratelimited` and transient server
    /// errors arrive through the same `apiError` case, and treating one of those as terminal takes
    /// down a connection that was going to recover by itself.
    func testSlackKeepsTransientFailuresReconnecting() {
        for code in ["ratelimited", "internal_error", "service_unavailable", "connection_limit_reached", ""] {
            XCTAssertNil(
                SlackSocketClient.terminalReason(slackErrorCode: code),
                "`\(code)` recovers on a reconnect; giving up on it makes a blip permanent."
            )
        }
    }

    // MARK: - Wiring

    /// ⚠️ THE HALF THAT MATTERS. A perfect classifier changes nothing if no one asks it, and no one
    /// did for the whole life of both listeners. These read the real sources: delete the state write
    /// and the test goes red.
    /// ⚠️⚠️ REWRITTEN WHEN THE THREE COPIES BECAME ONE SEAM, AND THE OLD SHAPE IS THE LESSON. It
    /// asserted the LITERALS `"connectionState = .error("` and `"slackConnectionState = .error("`, so
    /// extracting `ChatOpsBridgeShutdown.report` — which preserved the behaviour exactly — turned it
    /// red. A drift test written against the implementation line fails on a refactor and passes on a
    /// regression; this subsystem has already had one actively defending a defect.
    ///
    /// ⚠️ IT NOW COVERS ALL THREE. Discord was previously absent from this test because it had no
    /// terminal reporting at all: a permanently-closed Gateway left a green "Active" dot for the life
    /// of the process. That was the gap the test's own name ("BothBridges") quietly recorded.
    func testEveryBridgeTurnsATerminalFailureIntoAVisibleConnectionState() throws {
        for (bridge, transportProperty) in [("ChatOpsBridge", "terminalFailure"),
                                            ("SlackChatOpsBridge", "terminalFailure"),
                                            ("DiscordChatOpsBridge", "terminalFailure")] {
            let source = try ChatOpsSecurityTierMatrixTests
                .readSourceStrippingComments("Devgentic/ChatOps/Services/\(bridge).swift")

            XCTAssertTrue(source.contains(transportProperty),
                          "\(bridge) no longer reads its transport's terminal failure — a dead bridge "
                          + "reports itself as a clean stop again.")
            XCTAssertTrue(source.contains("ChatOpsBridgeShutdown.report"),
                          "\(bridge) must route its shutdown through the shared reporter. Three "
                          + "hand-written copies is how Discord ended up with none at all.")
        }
    }

    /// The seam must actually write the state — the reporter existing proves nothing on its own.
    func testTheSharedReporterWritesAnErrorStateForARealFailure() {
        var written: ChatOpsConnectionState?
        let reported = ChatOpsBridgeShutdown.report(
            terminalFailure: "Telegram rejected the bot token (401).",
            provider: .telegram, isOwner: true,
            logger: DGLogger(category: "ChatOpsTerminalFailureTests")) { written = $0 }

        XCTAssertTrue(reported)
        XCTAssertEqual(written, .error("Telegram rejected the bot token (401)."),
                       "without this the Settings pane keeps a green dot over a bridge that will never poll again")
    }

    /// A clean stop writes nothing — the state must keep describing the pairing, not the run.
    func testACleanStopWritesNoErrorState() {
        var written: ChatOpsConnectionState?
        let reported = ChatOpsBridgeShutdown.report(
            terminalFailure: nil, provider: .slack, isOwner: true,
            logger: DGLogger(category: "ChatOpsTerminalFailureTests")) { written = $0 }
        XCTAssertFalse(reported)
        XCTAssertNil(written)
    }

    /// ⚠️ [LIFE-2] A SUPERSEDED RUN MUST NOT WRITE. Without the ownership check a stale orphan paints
    /// a LIVE bridge red with a dead run's failure — a user-visible lie on the one property every
    /// surface reads, and exactly the class of bug the pairing-window work already fixed once.
    func testASupersededRunNeverWritesTheConnectionState() {
        var written: ChatOpsConnectionState?
        let reported = ChatOpsBridgeShutdown.report(
            terminalFailure: "some dead run's failure",
            provider: .discord, isOwner: false,
            logger: DGLogger(category: "ChatOpsTerminalFailureTests")) { written = $0 }
        XCTAssertFalse(reported)
        XCTAssertNil(written, "a run that is no longer the live one must not touch the connection state")
    }

    /// The Slack loop must actually STOP on a terminal failure rather than reconnecting forever —
    /// the behaviour invariant 26 fixed for Discord and Slack never received.
    func testSlackConnectLoopBreaksOnATerminalFailure() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/SlackSocketClient.swift")
        guard let classify = source.range(of: "Self.terminalReason(slackErrorCode:"),
              let tail = source.range(of: "increaseBackoff()", range: classify.upperBound..<source.endIndex) else {
            return XCTFail("Could not find the terminal-failure arm in SlackSocketClient's catch block.")
        }
        XCTAssertTrue(
            source[classify.upperBound..<tail.lowerBound].contains("break"),
            """
            The terminal arm falls through to the reconnect backoff. A rejected app token is then \
            retried every interval forever while the user is shown a merely-flaky connection.
            """
        )
    }
}
