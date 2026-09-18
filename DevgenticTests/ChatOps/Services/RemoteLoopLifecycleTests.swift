// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteLoopLifecycleTests.swift
//  devgenticTests
//
//  B2 — SL-7, CONC-5, DC-6, DC-7 and the wiring half of TG-6. Six register rows that all rewrite the
//  same three lines of catch-arm code in the same two files; landed separately, the last writer wins
//  and the others' tests pass vacuously over a predicate that no longer exists.
//
//  ⚠️ These are structural assertions because the subjects are actors that open real sockets — there
//  is no way to exercise a connect loop in a unit test without one. The BEHAVIOURAL half lives in
//  `RemoteLoopCancellationTests`, which tests the pure classifier these arms now call.
//

import XCTest
@testable import devgentic

final class RemoteLoopLifecycleTests: XCTestCase {

    /// The body of `connectAndListen`, which is the only scope in which "the catch arm's order" means
    /// anything.
    private static func connectLoopBody(of source: String) throws -> String {
        guard let start = source.range(of: "func connectAndListen(") else {
            XCTFail("connectAndListen has been renamed — the ordering tests are blind")
            return ""
        }
        guard let open = source[start.upperBound...].firstIndex(of: "{") else { return "" }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" { depth -= 1; if depth == 0 { return String(source[open...i]) } }
            i = source.index(after: i)
        }
        return String(source[open...])
    }

    private func code(_ name: String) throws -> String {
        try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/ChatOps/Services/\(name).swift")
    }

    // MARK: - TG-6: the dead arm is gone everywhere

    /// ⚠️⚠️ `catch is CancellationError` NEVER MATCHED A CANCELLED NETWORK CALL, and all four ChatOps
    /// loops were written as if it did — so every deliberate stop logged a failure and a retry that
    /// never happened, at a level the exported diagnostic bundle keeps.
    func testNoLoopStillCatchesTheWrongCancellationType() throws {
        for file in ["TelegramListener", "SlackSocketClient", "DiscordGatewayClient", "ChatOpsPairingService"] {
            XCTAssertFalse(try code(file).contains("catch is CancellationError"),
                           "\(file) still catches CancellationError, which a cancelled URLSession call never throws")
            XCTAssertTrue(try code(file).contains("RemoteLoopCancellation.isCancellation"),
                          "\(file) must classify the ERROR — `Task.isCancelled` is false for an orphan")
        }
    }

    // MARK: - SL-7 / DC-7: stop() actually stops

    /// ⚠️ Both clients' `stop()` tore down the socket and left the loop running, so the in-flight
    /// `receive()` threw, the catch arm called it a network fault and RECONNECTED. Correctness
    /// depended on the consumer abandoning its iterator — which every caller happens to do and none
    /// is required to.
    func testBothSocketClientsOwnTheirConnectLoop() throws {
        for file in ["SlackSocketClient", "DiscordGatewayClient"] {
            let source = try code(file)
            XCTAssertTrue(source.contains("connectTask"), "\(file) has no handle on its own loop")
            XCTAssertTrue(source.contains("connectTask?.cancel()"), "\(file).stop() must end the loop")
            XCTAssertTrue(source.contains("isStopping"),
                          "\(file) cannot tell a teardown it asked for from one that happened to it")
        }
    }

    /// ⚠️ THE ORDER IS THE CONTRACT. `isStopping` must be consulted BEFORE the terminal/close-code
    /// classifier: a stop has no failure to classify. Reversing them reports a fabricated terminal
    /// failure on every ordinary shutdown.
    func testADeliberateStopIsCheckedBeforeAnythingIsClassified() throws {
        for (file, classifier) in [("SlackSocketClient", "terminalReason"),
                                   ("DiscordGatewayClient", "DiscordGatewayClosePolicy.disposition")] {
            // ⚠️ SCOPED TO THE LOOP BODY. A whole-file search matched `terminalReason`'s DECLARATION
            //   near the top of the file rather than its use in the catch arm, and reported a
            //   correctly-ordered arm as mis-ordered. An ordering assertion is only meaningful inside
            //   the one scope where the order exists.
            let source = try Self.connectLoopBody(of: try code(file))
            guard let stopIndex = source.range(of: "if isStopping"),
                  let classifyIndex = source.range(of: classifier) else {
                return XCTFail("\(file): could not locate both the stop check and the classifier in connectAndListen")
            }
            XCTAssertLessThan(stopIndex.lowerBound, classifyIndex.lowerBound,
                              "\(file) classifies the failure before noticing it was asked to stop")
        }
    }

    /// ⚠️ Discord was the ONE platform with no `terminalFailure`, so a permanently-closed Gateway left
    /// the Settings pane showing a green dot. Telegram and Slack both gained one with their classifiers.
    func testDiscordCanReportATerminalFailureLikeItsSiblings() throws {
        let source = try code("DiscordGatewayClient")
        XCTAssertTrue(source.contains("private(set) var terminalFailure"),
                      "Discord cannot report why it died, so its bridge cannot turn it into a red state")
        XCTAssertTrue(source.contains("terminalFailure ="),
                      "the property exists but nothing ever sets it")
    }

    // MARK: - DC-6: one teardown, and never from the catch arm

    /// ⚠️⚠️ THE PROHIBITION IS LOAD-BEARING. The catch arm classifies by reading
    /// `webSocket?.closeCode`, and a nil socket reads as close code 0 — which the policy maps to
    /// `.reconnect`. Tearing down before classifying would turn every 4004/4014 into an infinite
    /// reconnect, silently undoing the fatal-close work.
    func testDiscordNeverTearsDownBeforeItHasClassifiedTheClose() throws {
        let source = try code("DiscordGatewayClient")
        guard let arm = source.range(of: "isConnected = false"),
              let policy = source.range(of: "DiscordGatewayClosePolicy.disposition") else {
            return XCTFail("could not locate the catch arm")
        }
        let between = String(source[arm.upperBound..<policy.lowerBound])
        XCTAssertFalse(between.contains("teardownConnection()"),
                       "the catch arm tears the socket down before reading its close code, so every "
                       + "permanent close reads as code 0 and reconnects forever")
    }

    /// The reconnect path must release the previous connection, or its heartbeat task survives and
    /// writes to whatever socket the actor holds next.
    func testDiscordReleasesThePreviousConnectionBeforeInstallingANewOne() throws {
        let source = try code("DiscordGatewayClient")
        guard let teardown = source.range(of: "teardownConnection()\n\n        let ws = session.webSocketTask"),
              teardown.isEmpty == false else {
            // Tolerate whitespace differences; fall back to an ordering check.
            guard let t = source.range(of: "teardownConnection()"),
                  let install = source.range(of: "self.webSocket = ws") else {
                return XCTFail("could not locate connect()'s teardown or its socket install")
            }
            XCTAssertLessThan(t.lowerBound, install.lowerBound,
                              "connect() installs the new socket before releasing the old connection, "
                              + "so the previous heartbeat task survives and writes to the new socket")
            return
        }
    }

    // MARK: - CONC-5: the socket is threaded, not re-read

    /// ⚠️ Slack's `connect()` assigned `self.webSocket` AFTER an await, resurrecting a socket a
    /// concurrent `stop()` had already torn down — and nothing was left holding a reference that
    /// could cancel it. Returning the socket makes the resurrection unrepresentable.
    func testSlackThreadsItsSocketRatherThanRepublishingIt() throws {
        let source = try code("SlackSocketClient")
        XCTAssertTrue(source.contains("func connect() async throws -> URLSessionWebSocketTask"),
                      "connect() must hand back the socket it made, not publish it and hope")
        XCTAssertTrue(source.contains("try Task.checkCancellation()"),
                      "a socket that must not exist should never be constructed")
        XCTAssertTrue(source.contains("receiveLoop(on:"),
                      "the receive loop must read the socket it was given")
    }

    /// ⚠️ SCOPED TO SLACK DELIBERATELY. Discord's catch arm MUST read `self.webSocket` after an await
    /// — that is how it gets the close code — so a blanket ban would delete the load-bearing read
    /// that `testDiscordNeverTearsDownBeforeItHasClassifiedTheClose` protects.
    func testSlackDoesNotRepublishItsSocketAfterAnAwait() throws {
        let source = try code("SlackSocketClient")
        let assignments = source.components(separatedBy: "self.webSocket = ").count - 1
        XCTAssertEqual(assignments, 1,
                       "exactly one assignment, inside connect(); a second means the socket is being "
                       + "republished somewhere a stop() can race")
    }

    // MARK: - SL-4: the ack cannot evaporate

    /// ⚠️ `try await webSocket?.send(...)` meant a nil socket made the ack vanish with no send, no
    /// throw and no log — on the path the file's own header calls critical. Slack then redelivers the
    /// envelope up to three times and finally marks the app unhealthy.
    func testTheSlackAckCannotSilentlyNoOp() throws {
        let source = try code("SlackSocketClient")
        XCTAssertTrue(source.contains("acknowledge(envelopeID: String, on ws: URLSessionWebSocketTask)"),
                      "the ack must take a non-optional socket, so the silent version is unwritable")
        XCTAssertFalse(source.contains("try await webSocket?.send"),
                       "the ack still goes through an optional chain that can evaporate")
    }
}

// MARK: - B3: bridge lifecycle

final class ChatOpsBridgeLifecycleTests: XCTestCase {

    private func code(_ name: String) throws -> String {
        try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments("Devgentic/ChatOps/Services/\(name).swift")
    }

    /// ⚠️ [DC-1/LIFE-2] A second `start()` built a fresh client, listener and transport and overwrote
    /// the stored references, orphaning a live connection nothing could cancel — on Telegram, two
    /// pollers then stole each other's updates at random.
    func testEveryBridgeRefusesASecondStart() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            XCTAssertTrue(try code(bridge).contains("ChatOpsBridgeStart.shouldProceed"),
                          "\(bridge).start() is not idempotent — a second call orphans the first listener")
        }
    }

    /// ⚠️ REFUSE, NOT RESTART. `if isRunning { stop() }` looks equivalent and is not: `stop()` tears
    /// down the mirror session, killing an in-flight tool approval a user has already tapped.
    func testASecondStartIsRefusedRatherThanRestarted() {
        let logger = DGLogger(category: "ChatOpsBridgeLifecycleTests")
        XCTAssertTrue(ChatOpsBridgeStart.shouldProceed(isRunning: false, provider: .telegram, logger: logger))
        XCTAssertFalse(ChatOpsBridgeStart.shouldProceed(isRunning: true, provider: .telegram, logger: logger))
    }

    /// ⚠️ [LIFE-2] `stop()` left every client and transport installed, and — through
    /// `ChatOpsCommandService` — a strong reference to the view model, defeating the `weak var
    /// viewModel` the same file declares.
    func testStopReleasesWhatTheRunOwned() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try code(bridge)
            guard let stop = source.range(of: "func stop() {") else { return XCTFail("\(bridge) has no stop()") }
            let body = String(source[stop.upperBound...].prefix(900))
            XCTAssertTrue(body.contains("commands = nil"),
                          "\(bridge).stop() leaves the command service installed, which holds the host")
            XCTAssertTrue(body.contains("apiClient = nil"),
                          "\(bridge).stop() leaves a live API client behind")
        }
    }

    /// ⚠️⚠️ [LIFE-7] THE CYCLE WAS view model → bridge → command service → view model, and it got
    /// WIDER today: `submitTurn` put this service on the main command path for all three providers.
    func testTheCommandServiceHoldsItsHostWeakly() throws {
        let source = try code("ChatOpsCommandService")
        XCTAssertTrue(source.contains("private weak var runControlRef"),
                      "a strong host reference closes the retain cycle `weak var viewModel` exists to prevent")
        XCTAssertTrue(source.contains("private weak var commandingRef"))
        XCTAssertTrue(source.contains("hostLost("),
                      "a lost host must be ANSWERED, not swallowed — the [NEW-4] rule this file already applies")
    }

    /// A prompt whose host is gone must be refused with its own copy — "reopen the app" is a
    /// different remedy from "try again in a moment".
    func testALostHostRefusalIsDistinctFromTheOtherRefusals() {
        guard case .refused(let host, _) = RemoteTurnAdmission.hostUnavailable,
              case .refused(let mirror, _) = RemoteTurnAdmission.mirrorUnavailable else {
            return XCTFail("both refusals must carry copy")
        }
        XCTAssertNotEqual(host, mirror)
        XCTAssertTrue(host.localizedCaseInsensitiveContains("reopen"))
    }
}
