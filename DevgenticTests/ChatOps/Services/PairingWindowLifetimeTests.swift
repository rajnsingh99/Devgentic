// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  PairingWindowLifetimeTests.swift
//  devgenticTests
//
//  Who owns a pairing window, and what it is allowed to do when it ends.
//
//  ⚠️⚠️ THE FAILURE THIS PINS. `pollForPairing` is an instance method, so its `Task` retains the
//  service for the full 300-second window — but the service itself was `@State` inside
//  `ChatOpsSettingsView`, which is torn down by clicking Chat or any other settings category. The
//  window therefore outlived its owner: coming back rebuilt a FRESH, idle service while
//  `connectionState` (on the shared config) still said `.awaitingPairing`, so the PIN card rendered
//  with a Cancel button that cancelled a nil task. Starting again ran TWO windows against one bot
//  token, and the user's correct PIN was consumed by whichever poll held the connection — recorded
//  as a FAILED attempt against their own origin by the orphan. At t=300s the orphan then reset the
//  connection state and DELETED the bot token belonging to the newer, successful pairing.
//
//  ⚠️ A SECOND, SEPARATE DEFECT SHARED THE SAME THREE LINES. Discord and Slack evaluated their
//  deadline as the first statement of a `for await` BODY, so it could only run when the stream
//  yielded — and neither stream emits anything periodic. On a quiet channel the window never expired
//  at all, and the first message to arrive after the deadline was consumed by the expiry check and
//  discarded, so a user returning late and typing the correct PIN saw it silently do nothing.
//

import XCTest
import os
@testable import devgentic

@MainActor
final class PairingWindowLifetimeTests: XCTestCase {

    private let config = ChatOpsConfigManager.shared

    /// ⚠️ These tests write the SHARED config's connection state, so each restores it. They never
    /// touch credentials — nothing here should reach the Keychain.
    private var savedTelegram: ChatOpsConnectionState = .disconnected
    private var savedDiscord: ChatOpsConnectionState = .disconnected
    private var savedSlack: ChatOpsConnectionState = .disconnected

    override func setUp() async throws {
        savedTelegram = config.connectionState
        savedDiscord = config.discordConnectionState
        savedSlack = config.slackConnectionState
    }

    override func tearDown() async throws {
        config.connectionState = savedTelegram
        config.discordConnectionState = savedDiscord
        config.slackConnectionState = savedSlack
    }

    // MARK: - Ownership

    /// ⚠️ THE ORPHAN CASE, AND THE WHOLE REASON THE PIN IS COMPARED. `Task.isCancelled` is false for
    /// a window nobody cancelled, so it is no evidence of ownership at all.
    func testAnExpiredWindowThatIsNoLongerLiveChangesNothing() {
        // A newer pairing has already succeeded.
        config.connectionState = .connected(chatID: 4242)

        // The ORPHAN from an earlier window reaches its deadline.
        PairingWindowExpiry.expire(pin: "111111", platform: "Telegram", timeout: 300,
                                   state: \.connectionState, config: config, logger: Self.logger)

        XCTAssertEqual(config.connectionState, .connected(chatID: 4242), """
            An orphaned window overwrote the state of a newer, successful pairing. This is the defect \
            that also deleted the newer pairing's bot token from the Keychain.
            """)
    }

    /// A superseded window — the user restarted pairing and got a new PIN — must not disturb the
    /// window that replaced it.
    func testASupersededWindowDoesNotExpireItsSuccessor() {
        config.connectionState = .awaitingPairing(pin: "222222")

        PairingWindowExpiry.expire(pin: "111111", platform: "Telegram", timeout: 300,
                                   state: \.connectionState, config: config, logger: Self.logger)

        XCTAssertEqual(config.connectionState, .awaitingPairing(pin: "222222"),
                       "the live window's PIN was cleared by its predecessor's deadline")
    }

    func testTheLiveWindowDoesExpire() {
        config.connectionState = .awaitingPairing(pin: "333333")

        PairingWindowExpiry.expire(pin: "333333", platform: "Telegram", timeout: 300,
                                   state: \.connectionState, config: config, logger: Self.logger)

        guard case .error(let message) = config.connectionState else {
            return XCTFail("the live window did not expire; state is \(config.connectionState)")
        }
        XCTAssertTrue(message.lowercased().contains("timed out"), """
            Expiry must say what happened. A bare `.disconnected` — what this used to write — is \
            indistinguishable from never having started pairing at all.
            """)
    }

    /// Each platform's expiry must land on its OWN connection state. A copy-paste of the keypath is
    /// exactly the kind of drift a shared helper invites.
    func testExpiryIsScopedToOnePlatform() {
        config.connectionState = .awaitingPairing(pin: "444444")
        config.discordConnectionState = .awaitingPairing(pin: "444444")
        config.slackConnectionState = .awaitingPairing(pin: "444444")

        PairingWindowExpiry.expire(pin: "444444", platform: "Discord", timeout: 300,
                                   state: \.discordConnectionState, config: config, logger: Self.logger)

        XCTAssertEqual(config.connectionState, .awaitingPairing(pin: "444444"),
                       "expiring Discord disturbed Telegram")
        XCTAssertEqual(config.slackConnectionState, .awaitingPairing(pin: "444444"),
                       "expiring Discord disturbed Slack")
        if case .awaitingPairing = config.discordConnectionState {
            XCTFail("Discord did not expire")
        }
    }

    // MARK: - Wiring

    /// ⚠️ A TIMEOUT MUST NOT TOUCH CREDENTIALS. The old arms ran `config.botToken = nil` — a Keychain
    /// DELETE — on a token the user had already pasted and the platform had already validated.
    func testNoPairingServiceClearsCredentialsOnTimeout() throws {
        for path in ["Devgentic/ChatOps/Services/ChatOpsPairingService.swift",
                     "Devgentic/ChatOps/Services/DiscordPairingService.swift",
                     "Devgentic/ChatOps/Services/SlackPairingService.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            guard let expiry = source.range(of: "PairingWindowExpiry.expire") else {
                return XCTFail("\(path) no longer routes its expiry through PairingWindowExpiry.")
            }
            // The 400 characters around the expiry call must not delete a credential.
            let lower = source.index(expiry.lowerBound, offsetBy: -400, limitedBy: source.startIndex) ?? source.startIndex
            let window = source[lower..<expiry.upperBound]
            for credential in ["BotToken = nil", "botToken = nil", "AppToken = nil", "appToken = nil"] {
                XCTAssertFalse(window.contains(credential), """
                    \(path) clears `\(credential)` on the timeout path. That token was VALIDATED; \
                    running out of time to send a PIN says nothing about it, and wiping it silently \
                    resets the pane and makes the user paste it again. Only `disconnect()` clears \
                    credentials.
                    """)
            }
        }
    }

    /// ⚠️ THE DEADLINE MUST BE WALL-CLOCK, NOT TRAFFIC-DRIVEN. Discord and Slack tested it inside a
    /// `for await` body, so a quiet channel meant a window that never closed.
    func testEveryServiceArmsAWallClockWatchdog() throws {
        for path in ["Devgentic/ChatOps/Services/ChatOpsPairingService.swift",
                     "Devgentic/ChatOps/Services/DiscordPairingService.swift",
                     "Devgentic/ChatOps/Services/SlackPairingService.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            XCTAssertTrue(source.contains("armDeadline(pin:"), """
                \(path) no longer arms a wall-clock watchdog. Its window then lasts only as long as \
                the event loop chooses to notice — on a silent channel, forever.
                """)
            XCTAssertTrue(source.contains("deadlineTask?.cancel()"),
                          "\(path) never cancels its watchdog, so Cancel and success both leave it armed.")
            XCTAssertTrue(source.contains("await PairingWindowExpiry.waitOutWindow(timeout)"),
                          "\(path)'s watchdog does not wait on the shared window clock.")
            // D-10: the hand-rolled `UInt64(self?.pairingTimeout ?? 300 * 1_000_000_000)` slept
            // 300 NANOSECONDS (`??` binds looser than `*`). Any nanosecond conversion here is that
            // trap waiting to come back.
            let handConverted = source.components(separatedBy: "\n").filter {
                $0.contains("pairingTimeout") && $0.contains("nanoseconds")
            }
            XCTAssertTrue(handConverted.isEmpty,
                          "\(path) converts its pairing window to nanoseconds by hand again: \(handConverted)")
        }
    }

    /// D-10, behaviourally: the window is SECONDS. The broken conversion returned in 300 ns, so a
    /// wait that comes back well before its timeout is exactly the defect.
    func testTheWindowWaitLastsItsTimeoutInSeconds() async {
        let start = ContinuousClock.now
        await PairingWindowExpiry.waitOutWindow(0.3)
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(290),
            "the pairing window ended after \(elapsed) instead of 0.3 s — every pairing expires at once")
    }

    /// The services must be shared, or Cancel goes back to targeting an instance that never ran.
    func testPairingServicesAreSharedRatherThanOwnedByTheView() throws {
        for (path, cls) in [("Devgentic/ChatOps/Services/ChatOpsPairingService.swift", "ChatOpsPairingService"),
                            ("Devgentic/ChatOps/Services/DiscordPairingService.swift", "DiscordPairingService"),
                            ("Devgentic/ChatOps/Services/SlackPairingService.swift", "SlackPairingService")] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            XCTAssertTrue(source.contains("static let shared = \(cls)()"),
                          "\(cls) is no longer shared; a pairing window can outlive its owner again.")
        }

        let view = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Settings/ChatOpsSettingsView.swift")
        XCTAssertFalse(view.contains("@State private var pairingService"), """
            The settings view owns its pairing service again. Tearing the view down (clicking Chat, or \
            any other settings category) then strands a live window that Cancel can no longer reach.
            """)
        for shared in ["ChatOpsPairingService.shared", "DiscordPairingService.shared", "SlackPairingService.shared"] {
            XCTAssertTrue(view.contains(shared), "the settings view does not use \(shared).")
        }
    }

    /// ⚠️ OBS-2. `PairingAttemptPolicy` refuses to record ATTEMPTED digits because a near-miss is one
    /// character from the real PIN. Logging the REAL one is strictly worse, and these lines reach
    /// exported diagnostic bundles.
    func testTheLivePINIsNeverLogged() throws {
        for path in ["Devgentic/ChatOps/Services/ChatOpsPairingService.swift",
                     "Devgentic/ChatOps/Services/DiscordPairingService.swift",
                     "Devgentic/ChatOps/Services/SlackPairingService.swift"] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            for line in source.split(separator: "\n") where line.contains("logger.") {
                XCTAssertFalse(line.contains("\\(pin)") || line.contains("\\(self.currentPIN"), """
                    \(path) logs the live pairing PIN: \(line.trimmingCharacters(in: .whitespaces)). \
                    That writes a working credential into every exported diagnostic bundle.
                    """)
            }
        }
    }

    private static let logger = DGLogger(category: "PairingWindowLifetimeTests")
}
