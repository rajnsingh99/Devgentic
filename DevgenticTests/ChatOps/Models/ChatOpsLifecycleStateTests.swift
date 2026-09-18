// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsLifecycleStateTests.swift
//  devgenticTests
//
//  "Paired" and "switched on" are different questions.
//
//  ⚠️⚠️ LIFE-4: THE OFF SWITCH WAS A ONE-WAY DOOR. `ChatOpsConfigManager.init` restored
//  `connectionState` only when `isEnabled` was ALSO true, so a user who turned ChatOps off — which
//  the toggle's own description invites — and then quit came back to `.disconnected`, a Pairing card
//  offering "Start Pairing", and an Enable toggle greyed out by
//  `.disabled(!config.connectionState.isConnected)`. Nothing in the app could turn it back on: the
//  only other writer of `isEnabled = true` is a pairing service. Their credentials and chat id were
//  intact the whole time; the only way back was re-doing a pairing they never undid.
//
//  ⚠️⚠️ LIFE-5: ONE TIER, THREE TABS. The same `securityCard` was embedded in each platform's stack
//  with no qualifier, reading and writing ONE global value — so Full Access granted for a private
//  Telegram DM was already showing on the Discord tab, and setting Discord to Read Only silently
//  dropped the phone to Read Only too.
//

import XCTest
@testable import devgentic

@MainActor
final class ChatOpsLifecycleStateTests: XCTestCase {

    // MARK: - LIFE-4: the restore condition

    /// ⚠️ The regression, as a property of the state vocabulary rather than of the singleton (which
    /// reads the developer's own real defaults and must not be mutated by a test).
    func testConnectedStateDescribesAPairingNotARunningListener() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        guard let start = source.range(of: "private init() {"),
              // ⚠️ ANCHORED ON THE ASSIGNMENT, NOT ON ITS VALUE. This read
              //   `"slackConnectionState = .connected"` and broke the moment the restore started
              //   routing through `ChatOpsPairingRestore.state` (NEW-1) — the invariant below was
              //   untouched, but the test could no longer FIND the block and failed as "could not
              //   locate", which reads like a missing feature rather than a moved anchor.
              let end = source.range(of: "slackConnectionState =", range: start.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the launch restore block")
        }
        // ⚠️ COMMENTS STRIPPED BEFORE SCANNING. The restore block carries a comment EXPLAINING that
        //   it used to consult `isEnabled`, and a raw substring scan matches that prose — so this
        //   test failed against the very fix it exists to pin. A structural test that reads comments
        //   is testing the documentation, not the code.
        let restore = String(source[start.upperBound..<end.upperBound])
            .split(separator: "\n")
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")

        for flag in ["isEnabled", "isDiscordEnabled", "isSlackEnabled"] {
            XCTAssertFalse(restore.contains(flag), """
                The launch restore consults `\(flag)` again. `connectionState` describes whether a \
                PAIRING EXISTS; whether the listener is running is a separate question that \
                `ChatOpsCoordinator.bootstrap()` already asks. Conflating them greys out the only \
                control that can switch ChatOps back on, and the user must re-pair to recover.
                """)
        }
    }

    /// ⚠️ THE HONESTY HALF. Once `.connected` means "paired", a provider whose listener is off would
    /// read "Connected" — a smaller lie than the lock-out, but still a lie: nothing is arriving.
    func testAPairedProviderWithItsListenerOffDoesNotClaimToBeConnected() {
        let connected = ChatOpsConnectionState.connected(chatID: 42)

        XCTAssertEqual(connected.statusText(listenerEnabled: true), "Connected")
        XCTAssertEqual(connected.statusText(listenerEnabled: false), "Paired — listener off", """
            A paired provider with its listener switched off reports itself as Connected. Nothing is \
            being received, so the status has to say so.
            """)
    }

    /// Every other state reads the same whether the listener is on or off — only `.connected` is
    /// ambiguous, so only `.connected` is qualified.
    func testOtherStatesAreUnaffectedByTheListenerFlag() {
        for state: ChatOpsConnectionState in [.disconnected, .validating,
                                              .awaitingPairing(pin: "123456"), .error("nope")] {
            XCTAssertEqual(state.statusText(listenerEnabled: true), state.statusText,
                           "\(state) should not vary with the listener flag")
            XCTAssertEqual(state.statusText(listenerEnabled: false), state.statusText)
        }
    }

    /// The Settings pane must actually pass the flag, or the honest status never renders.
    func testTheSettingsPaneAsksForTheListenerAwareStatus() throws {
        let view = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Settings/ChatOpsSettingsView.swift")
        for call in ["config.connectionState.statusText(listenerEnabled: config.isEnabled)",
                     "config.discordConnectionState.statusText(listenerEnabled: config.isDiscordEnabled)",
                     "config.slackConnectionState.statusText(listenerEnabled: config.isSlackEnabled)"] {
            XCTAssertTrue(view.contains(call), "a status row still renders the unqualified text: \(call)")
        }
    }

    // MARK: - LIFE-5: one tier per provider

    /// ⚠️ An absent key must mean the LEAST privilege, never "inherit whatever another platform got".
    func testAProviderWithNoStoredTierDefaultsToReadOnly() {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: ChatOpsConfigManager.discordSecurityTierKey),
                     defaults.string(forKey: ChatOpsConfigManager.slackSecurityTierKey))
        defer {
            defaults.set(saved.0, forKey: ChatOpsConfigManager.discordSecurityTierKey)
            defaults.set(saved.1, forKey: ChatOpsConfigManager.slackSecurityTierKey)
        }

        defaults.removeObject(forKey: ChatOpsConfigManager.discordSecurityTierKey)
        defaults.removeObject(forKey: ChatOpsConfigManager.slackSecurityTierKey)

        XCTAssertEqual(ChatOpsConfigManager.shared.securityTier(for: .discord), .readOnly)
        XCTAssertEqual(ChatOpsConfigManager.shared.securityTier(for: .slack), .readOnly)
    }

    /// ⚠️ THE REGRESSION. Writing one platform's tier must not move another's.
    func testSettingOnePlatformsTierLeavesTheOthersAlone() {
        let config = ChatOpsConfigManager.shared
        let saved = (config.securityTier, config.discordSecurityTier, config.slackSecurityTier)
        defer {
            config.securityTier = saved.0
            config.discordSecurityTier = saved.1
            config.slackSecurityTier = saved.2
        }

        config.setSecurityTier(.full, for: .telegram)
        config.setSecurityTier(.readOnly, for: .discord)
        config.setSecurityTier(.standard, for: .slack)

        XCTAssertEqual(config.securityTier(for: .telegram), .full, """
            Setting Discord to Read Only dropped Telegram too. That is the exact failure: the user's \
            phone approvals begin returning "Tool approval requires Full Access" with nothing \
            indicating the Discord tab caused it.
            """)
        XCTAssertEqual(config.securityTier(for: .discord), .readOnly)
        XCTAssertEqual(config.securityTier(for: .slack), .standard)
    }

    /// Each bridge must read ITS OWN provider's tier, or the split changes nothing at the gate.
    func testEachBridgeReadsItsOwnProvidersTier() throws {
        for (path, expected, forbidden) in [
            ("Devgentic/ChatOps/Services/ChatOpsBridge.swift", "config.securityTier(for: .telegram)", "config.securityTier(for: .discord)"),
            ("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift", "config.securityTier(for: .discord)", "config.securityTier(for: .telegram)"),
            ("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift", "config.securityTier(for: .slack)", "config.securityTier(for: .telegram)")
        ] {
            let source = try ChatOpsSecurityTierMatrixTests.readSource(path)
            XCTAssertTrue(source.contains(expected), "\(path) does not read its own tier")
            XCTAssertFalse(source.contains(forbidden), "\(path) reads another platform's tier")
        }
    }

    /// The Settings card is rendered in all three tabs, so it must be told which one it is in.
    func testTheSecurityCardIsBoundToItsTab() throws {
        let view = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Settings/ChatOpsSettingsView.swift")
        for call in ["securityCard(for: .telegram)", "securityCard(for: .discord)", "securityCard(for: .slack)"] {
            XCTAssertTrue(view.contains(call), "missing \(call) — a tab still renders the shared card")
        }
    }

    /// ⚠️ THE MIGRATION IS WHAT STOPS THE SPLIT BEING A SILENT DOWNGRADE. Discord and Slack start
    /// reading keys that do not exist yet, so an install running at Full Access would drop to Read
    /// Only on upgrade and its approvals would begin failing with no stated cause.
    func testAnAlreadyPairedProviderInheritsTheTierItWasRunningUnder() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        // ⚠️ THE CALL, INSIDE `init`, NOT JUST THE NAME. Asserting `source.contains("seedPerProviderTiers()")`
        //   passes while the call is commented out, because the FUNCTION DEFINITION still carries the
        //   name — confirmed by mutation, which sailed through. Scope the search to the initialiser
        //   and strip comments, or the test pins nothing.
        guard let initStart = source.range(of: "private init() {"),
              let initEnd = source.range(of: "\n    }", range: initStart.upperBound..<source.endIndex) else {
            return XCTFail("could not locate `private init()`")
        }
        let initBody = String(source[initStart.upperBound..<initEnd.lowerBound])
            .split(separator: "\n")
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
        XCTAssertTrue(initBody.contains("seedPerProviderTiers()"), """
            `private init()` no longer calls the per-provider tier migration, so every already-paired \
            Discord and Slack silently drops to Read Only on the next launch and its remote approvals \
            begin failing with a message naming no cause.
            """)
        XCTAssertTrue(source.contains("where isPaired && UserDefaults.standard.string(forKey: key) == nil"), """
            The seeding no longer restricts itself to already-PAIRED providers with no stored tier. \
            Seeding an unpaired provider would hand a future pairing an inherited Full Access, which \
            is the hole the split exists to close.
            """)
    }

    /// Disconnecting must drop the tier, so a fresh pairing cannot inherit Full Access.
    func testDisconnectingResetsThatProvidersTier() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Models/ChatOpsConfig.swift")
        for reset in ["securityTier = .readOnly", "discordSecurityTier = .readOnly", "slackSecurityTier = .readOnly"] {
            XCTAssertTrue(source.contains(reset), "disconnect leaves a tier behind: expected `\(reset)`")
        }
    }
}
