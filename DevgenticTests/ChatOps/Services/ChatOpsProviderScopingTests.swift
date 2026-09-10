// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsProviderScopingTests.swift
//  DevgenticTests
//
//  C6 of the ChatOps remote-interface plan: the Discord swap, and the two properties it turns on.
//
//  Both are structural and can only be checked by reading source. That is stated rather than
//  disguised: `ProviderSessionContext` reaches `ChatOpsConfigManager.shared`, whose cursors forward
//  to `UserDefaults.standard`, so a behavioural test would move the developer's own ChatOps state;
//  and the two Discord dispatch paths are `private` inside a bridge no test may construct (its view
//  model opens real network connections).
//
//  ⚠️ Every scan below regexes over the JOINED body, never line by line — a multi-line chain has
//  already walked past a line-filtered scan in this repo.
//

import XCTest
@testable import devgentic

final class ChatOpsProviderScopingTests: XCTestCase {

    // MARK: - One service per provider, one cursor per provider

    /// ⚠️ THE BUG THIS COMMIT WOULD OTHERWISE HAVE SHIPPED. `ChatOpsConfigManager.activeConversationID`
    /// IS the Telegram cursor — Discord's and Slack's are separate properties. A service reading the
    /// bare property would have moved Discord's conversation by writing Telegram's, and both bridges
    /// would still have "worked" in every existing test.
    ///
    /// Mutation that must turn this red: point two providers at the same property.
    func testEachProviderSessionReadsAndWritesItsOwnCursorProperty() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/ChatOpsCommandService.swift")
        guard let start = source.range(of: "final class ProviderSessionContext") else {
            return XCTFail("ProviderSessionContext is gone — the service is Telegram-only again")
        }
        // ⚠️ Whitespace-normalised. The switch arms are column-aligned in source
        // (`case .discord:  return …`), so an exact-spacing match passes for `.telegram` and fails
        // for the other two — which is precisely how this test first failed.
        let body = Self.collapsingSpaces(String(source[start.upperBound...].prefix(2600)))

        let expected: [(String, String)] = [
            (".telegram", "config.activeConversationID"),
            (".discord", "config.discordActiveConversationID"),
            (".slack", "config.slackActiveConversationID"),
        ]
        for (provider, property) in expected {
            XCTAssertTrue(body.contains("case \(provider): return \(property)"),
                          "\(provider)'s getter no longer reads \(property)")
            XCTAssertTrue(body.contains("case \(provider): \(property) = newValue"),
                          "\(provider)'s setter no longer writes \(property)")
        }

        // Three distinct properties — two providers sharing one would silently merge their cursors.
        let named = Set(expected.map(\.1))
        XCTAssertEqual(named.count, 3)
    }

    /// The write goes through `ChatOpsConfigManager`, not straight to `RemoteSessionStore`. Both end
    /// in the same UserDefaults key, but going direct skips the `withMutation(keyPath:)` wrapper and
    /// silently drops `@Observable` invalidation — a loss nothing would notice today, which is
    /// exactly why it would go unnoticed.
    func testTheProviderSessionWritesThroughTheConfigManagerNotTheStoreDirectly() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/ChatOpsCommandService.swift")
        guard let start = source.range(of: "final class ProviderSessionContext") else {
            return XCTFail("ProviderSessionContext is gone")
        }
        let body = String(source[start.upperBound...].prefix(2600))
        XCTAssertFalse(body.contains("RemoteSessionStore"),
                       "the provider session bypasses ChatOpsConfigManager, dropping @Observable invalidation")
    }

    // MARK: - Discord's two paths, one decision

    /// ⚠️ THE DIVERGENCE C6 EXISTS TO CLOSE. `/conversations` rendered a button grid when it arrived
    /// as a channel message and a numbered plain-text list when it arrived as a slash command,
    /// because "reply into the interaction" was a second code path that re-derived its own text.
    ///
    /// Mutation that must turn this red: reintroduce a text builder for the interaction path.
    func testTheDiscordBridgeHasNoSeparateTextBuildersLeft() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift")
        for builder in ["conversationListText", "statusText", "helpText"] {
            XCTAssertFalse(source.contains(builder), """
                DiscordChatOpsBridge still has `\(builder)`. A second way to render a verb is how \
                /conversations came to have two different Discord renderings; the interaction path \
                must render the same RemoteView to a different DESTINATION, not re-derive text.
                """)
        }
    }

    /// Both dispatch paths must go through the one routing helper.
    ///
    /// Mutation that must turn this red: give either switch its own arm for a service-owned verb.
    func testBothDiscordDispatchPathsRouteThroughTheSameHelper() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift")

        for path in ["private func routeCommand(", "private func routeInteractionCommand("] {
            guard let start = source.range(of: path) else { return XCTFail("\(path) is gone") }
            // Joined body: the call and its destination span several lines.
            let body = String(source[start.upperBound...].prefix(900))
            XCTAssertTrue(body.contains("routeThroughService("), "\(path) no longer routes through the shared helper")
        }

        // And the destinations differ — that is the whole mechanism.
        XCTAssertTrue(source.contains(".channel(RemoteChannel(provider: .discord"),
                      "the message path lost its channel destination")
        XCTAssertTrue(source.contains(".interactionReply("),
                      "the interaction path lost its interaction destination — a slash command would post a stray channel message and leave Discord's deferred \"thinking…\" hanging")
    }

    /// ⚠️ `switch:` was absent from BOTH Discord interaction switches, so the conversation buttons
    /// were inert: the tap was ACKed with a deferred update and then dropped, with no error anywhere.
    /// Routing through the shared helper reaches the handler, which is a BEHAVIOUR FIX shipping in
    /// this commit rather than a silent bonus.
    func testTheInertDiscordSwitchButtonsAreNowReachable() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift")
        guard let start = source.range(of: "private func routeThroughService(") else {
            return XCTFail("routeThroughService is gone")
        }
        let body = Self.methodBody(of: source, after: start.upperBound)
        XCTAssertTrue(body.contains("case .switchConversation(let uuid):"),
                      "switchConversation is unhandled again — Discord's conversation buttons go inert")
    }

    // MARK: - Slack (C7)

    /// The last bridge. Same property as Discord's: one decision, reached from every inbound path.
    ///
    /// Mutation that must turn this red: give `handleInteraction` its own arm for a service-owned
    /// verb again — which is exactly what it had (`.switchConversation` and `.newConversation` were
    /// duplicated between it and `routeCommand`).
    func testEverySlackInboundPathRoutesThroughTheSameHelper() throws {
        let source = try Self.readSource("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift")

        // ⚠️⚠️ THE WINDOW IS GONE, AND ITS REPLACEMENT IS THE POINT. This was a character count, and
        // it had already been outgrown twice: slice 4.3's view-submission branch pushed the routing
        // call from ~1200 to ~2500 characters into `handleInteraction`, and the channel-allowlist
        // fix pushed it to 4011 — past the 3200 the window had been raised to. Each time the test
        // went RED while the routing it guards was perfectly intact, which is the worst failure a
        // guard can have: it reports a fix as a regression and trains the next reader to raise the
        // number without looking.
        //
        // A count cannot be right, because it is a guess about how long a method will be. Scanning
        // to the next declaration cannot be wrong: the method ends where the method ends.
        for path in ["private func routeCommand(", "private func handleInteraction("] {
            guard let start = source.range(of: path) else { return XCTFail("\(path) is gone") }
            XCTAssertTrue(Self.methodBody(of: source, after: start.upperBound).contains("routeThroughService("),
                          "\(path) no longer routes through the shared helper")
        }

        // `handleSlashCommand` reaches it transitively, via `routeCommand`.
        //
        // ⚠️ THIS ONE WAS LEFT ON A CHARACTER COUNT WHEN THE TWO ABOVE WERE CONVERTED, and it went
        // red the very next time the method grew — a tier-denial log line and a `tell(...)` call
        // pushed `routeCommand(` to 1282 characters in, past the 900 it allowed. Two of
        // three fixed is how a trap survives; the boundary is the declaration here too.
        guard let slash = source.range(of: "private func handleSlashCommand(") else {
            return XCTFail("handleSlashCommand is gone")
        }
        XCTAssertTrue(Self.methodBody(of: source, after: slash.upperBound).contains("routeCommand("),
                      "the slash path no longer reaches the shared routing")
    }

    /// ⚠️ Every bridge must be free of its own copies of the six verbs. This is the drift guard for
    /// the whole refactor: a future contributor adding "just one small handler" back to a bridge is
    /// how three copies appeared in the first place.
    ///
    /// Mutation that must turn this red: reintroduce any per-verb handler in any bridge.
    func testNoBridgeKeepsItsOwnCopyOfAServiceOwnedVerb() throws {
        let bridges = [
            "Devgentic/ChatOps/Services/ChatOpsBridge.swift",
            "Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift",
            "Devgentic/ChatOps/Services/SlackChatOpsBridge.swift",
        ]
        let handlers = [
            "func handleConversations", "func handleNewConversation", "func handleStatus",
            "func handleCancel", "func handleHelp", "func handleSwitchConversation",
            "func fetchRecentConversations", "func findReusableEmptyConversation", "func resolveProfile(",
        ]
        for bridge in bridges {
            let source = try Self.readSource(bridge)
            for handler in handlers {
                XCTAssertFalse(source.contains(handler), """
                    \(bridge) has `\(handler)` again. Every verb is decided once in \
                    ChatOpsCommandService and rendered per platform; a handler in a bridge is a \
                    second copy, and three copies is the defect this whole refactor removed.
                    """)
            }
        }
    }

    /// What each bridge legitimately still owns: the transport-level side effects a `-> RemoteView`
    /// return cannot express. Recorded so the remaining surface is deliberate rather than residual.
    func testTheBridgesStillOwnOnlyTheirTransportLevelConcerns() throws {
        let telegram = try Self.readSource("Devgentic/ChatOps/Services/ChatOpsBridge.swift")
        // Free text starts an agent run and must register a mirror session synchronously first —
        // neither is expressible as a returned view, so it stays in the bridge.
        XCTAssertTrue(telegram.contains("func handleFreeText"))
        XCTAssertTrue(telegram.contains("registerSession"))
        // The HITL arms resolve a parked continuation and post nothing.
        XCTAssertTrue(telegram.contains("handleApproval"))
    }

    // MARK: - Clarification wiring (C8)

    /// ⚠️ THE DRIFT GUARD FOR A BLOCKER THAT SHIPPED FOR MONTHS BEHIND GREEN TESTS. A STORED
    /// `awaitingClarification` on any bridge is the defect itself: nothing ever set the Discord and
    /// Slack ones to true, so `.clarificationResponse` was unreachable on both.
    ///
    /// Mutation that must turn this red: reintroduce `private var awaitingClarification` anywhere.
    func testNoBridgeStoresClarificationStateAnyMore() throws {
        for bridge in Self.bridges {
            let source = try Self.readSource(bridge)
            XCTAssertFalse(source.contains("var awaitingClarification"), """
                \(bridge) stores clarification state again. It must be DERIVED from the \
                InteractionCenter at the moment of the reply — a stored flag is what made the \
                Discord and Slack `.clarificationResponse` arms unreachable, so every answer to a \
                mirrored clarification started a second concurrent run.
                """)
        }
    }

    /// All three read the same derived source and answer through the same helper.
    func testEveryBridgeDerivesClarificationStateFromTheService() throws {
        for bridge in Self.bridges {
            let source = try Self.readSource(bridge)
            XCTAssertTrue(source.contains("commands?.isAwaitingClarification ?? false"),
                          "\(bridge) no longer derives the awaiting-clarification flag from the service")
            XCTAssertTrue(source.contains("commands?.pendingClarificationOperationID()"),
                          "\(bridge) resolves the clarification operation id some other way")
            XCTAssertTrue(source.contains("await resolveClarification(text)"),
                          "\(bridge)'s clarification arm no longer delegates")
        }
    }

    /// The bridges reach the InteractionCenter only through the host seam now — a direct reach is
    /// how three bridges came to hold three copies of the same lookup.
    func testNoBridgeReachesTheInteractionCenterDirectly() throws {
        for bridge in Self.bridges {
            let source = try Self.readSource(bridge)
            XCTAssertFalse(source.contains("interactionCenter"),
                           "\(bridge) reaches the InteractionCenter directly instead of through RemoteRunControlling")
        }
    }

    // MARK: - Helpers

    /// Collapses runs of spaces so a column-aligned switch matches a single-spaced expectation.
    private static func collapsingSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    private static let bridges = [
        "Devgentic/ChatOps/Services/ChatOpsBridge.swift",
        "Devgentic/ChatOps/Services/DiscordChatOpsBridge.swift",
        "Devgentic/ChatOps/Services/SlackChatOpsBridge.swift",
    ]

    private static func readSource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(relativePath) not reachable from \(repoRoot.path) — running outside a checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Everything from `index` to the start of the next declaration, with comment lines removed.
    ///
    /// ⚠️ COMMENTS ARE STRIPPED, AND THAT IS NOT TIDINESS. This file's comments name the very
    /// symbols it asserts on — "Routing through the shared helper reaches the handler" sits three
    /// lines above a `routeThroughService(` assertion — so a scan that kept them would pass on a
    /// method whose BODY had lost the call entirely, proving only that someone had written about it.
    ///
    /// ⚠️ THE BOUNDARY IS THE NEXT DECLARATION, NOT A CHARACTER COUNT. A count is a guess about how
    /// long a method will be, and this file has watched that guess fail twice — see the call sites.
    private static func methodBody(of source: String, after index: String.Index) -> String {
        let rest = source[index...]
        var end = rest.endIndex
        for marker in ["\n    private func ", "\n    func ", "\n    private static func ", "\n}"] {
            if let found = rest.range(of: marker)?.lowerBound, found < end { end = found }
        }
        return rest[..<end]
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
