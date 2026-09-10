// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsSilentDropTests.swift
//  DevgenticTests
//
//  The standing logging rule, enforced against the ChatOps subsystem.
//
//  ⚠️⚠️ WHY A SOURCE SCAN AND NOT BEHAVIOUR. What is being asserted is the ABSENCE of a silent
//  failure path — that no send, decode or terminal arm can fail without writing a line naming what
//  the user loses. There is no runtime observation of "nothing was logged" that a test can make
//  without a fake for every transport, gateway and API client in the subsystem; and the bridges hold
//  concrete clients with no injection seam. A scan is what can actually be enforced here, and its
//  limit is stated rather than implied: it proves the wiring exists, not that the line is correct.
//
//  ⚠️ THE ORIGINAL COUNT WAS WRONG, AND THAT IS WHY THIS FILE IS BROAD. A single grep for
//  `_ = try? await apiClient?` found 15 sites in three bridges. An exhaustive pass over the whole
//  subsystem found 41 across eleven files — including two classes the grep could not see: inbound
//  DECODE failures (a Discord/Slack payload the app cannot model was dropped with no log, so a
//  schema change makes the bot go deaf in total silence) and the mirror's HITL status EDITS (a
//  failed edit leaves live approve/deny buttons on an already-decided prompt, forever).
//

import XCTest
@testable import devgentic

final class ChatOpsSilentDropTests: XCTestCase {

    /// Sites that are allowed to fail in silence, each with the reason it earns the exemption.
    ///
    /// ⚠️ AN ALLOW-LIST, NOT A THRESHOLD. "Fewer than N silent drops" would let a new one in every
    /// time an old one was fixed. Every exemption is named, so adding one is a visible decision.
    private static let deliberateSilence: [String: String] = [
        "sendTypingAction": "a typing indicator is decoration; it expires on its own and the reply arrives regardless",
        "sendTypingIndicator": "same as sendTypingAction",
        "Task.sleep": "a cancelled sleep is the cancellation working, not a failure",
    ]

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

    /// Lines of real code, with comments and doc comments removed.
    ///
    /// ⚠️ COMMENTS MUST GO BEFORE ANY ASSERTION RUNS. These files document the very patterns being
    /// searched for — several comments quote `_ = try? await apiClient?.sendMessage(...)` verbatim
    /// while explaining why it was replaced. A scan that kept them would fail on the explanation of
    /// the fix, which is the most confusing possible red.
    private static func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { return nil }
            return (index + 1, line)
        }
    }

    // MARK: - The user-facing send paths

    /// ⚠️⚠️ THE ORIGINAL FINDING. Every one of these sends is a "here is why nothing happened"
    /// message — a tier denial, an unbound conversation, a missing profile. They were all
    /// `_ = try? await apiClient?.send…`, so the one message whose whole job is to explain a failure
    /// was itself dropped in silence, and no line was written anywhere. A tier-blocked command and a
    /// crashed bridge were indistinguishable from both sides.
    ///
    /// Mutation that must turn this red: restore any `_ = try? await apiClient?.sendMessage(...)`.
    func testNoBridgeExplainsAFailureThroughASwallowedSend() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try Self.source("Devgentic/ChatOps/Services/\(bridge).swift")
            for (number, line) in Self.codeLines(source) where line.contains("try? await apiClient?") {
                let exempt = Self.deliberateSilence.keys.contains { line.contains($0) }
                XCTAssertTrue(exempt, """
                    \(bridge).swift:\(number) reaches the user through a swallowed send:
                    \(line.trimmingCharacters(in: .whitespaces))
                    Route it through `tell(_:_:whenLost:)` or `respond(to:type:data:whenLost:)`, \
                    which require the consequence to be stated.
                    """)
            }
        }
    }

    /// ⚠️ THE HELPER'S CONSEQUENCE PARAMETER MUST STAY REQUIRED. A default would be one generic
    /// sentence silently inherited by every future call site, which is how the three bridges drifted
    /// apart in the first place — the same anti-drift rule as `resolvedBy:` and `offset:`.
    ///
    /// Mutation that must turn this red: give `whenLost` a default value.
    func testTheConsequenceCannotBeOmittedByANewCallSite() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try Self.source("Devgentic/ChatOps/Services/\(bridge).swift")
            XCTAssertTrue(source.contains("whenLost consequence: String"),
                          "\(bridge) no longer has the tell(_:_:whenLost:) helper")
            XCTAssertFalse(source.contains("whenLost consequence: String ="),
                           "\(bridge) gave `whenLost` a default — every new call site now inherits one generic sentence")
        }
    }

    // MARK: - The inbound decode paths

    /// ⚠️⚠️ THE CLASS A GREP FOR SENDS CANNOT SEE, AND THE WORST ONE. `guard let x = try? decode(...)
    /// else { return }` dropped an inbound payload this build cannot model with NO log at all — so a
    /// Discord or Slack schema change turns every typed command into "the bot ignored me", silently,
    /// on both sides. For an interaction it is worse still: nothing acks it, so the user gets
    /// Discord's red "This interaction failed" with nothing anywhere explaining why.
    ///
    /// Mutation that must turn this red: restore any `try? data.decode` / `try? rawPayload.decode`.
    func testNoInboundPayloadIsDroppedWithoutALog() throws {
        for client in ["DiscordGatewayClient", "SlackSocketClient"] {
            let source = try Self.source("Devgentic/ChatOps/Services/\(client).swift")
            for (number, line) in Self.codeLines(source) where line.contains("try?") {
                let exempt = Self.deliberateSilence.keys.contains { line.contains($0) }
                    // A decode with an explicit fallback value is a defaulted read, not a drop.
                    || line.contains("?? false") || line.contains("?? true")
                XCTAssertTrue(exempt, """
                    \(client).swift:\(number) drops an inbound payload with no log:
                    \(line.trimmingCharacters(in: .whitespaces))
                    A payload this build cannot model must say so — otherwise a schema change makes \
                    the bot go deaf in total silence.
                    """)
            }
        }
    }

    // MARK: - The mirror's HITL status edits

    /// ⚠️⚠️ A FAILED EDIT LEAVES LIVE BUTTONS ON A DECIDED PROMPT. Every transport clears the
    /// approve/deny/gate controls only via a SUCCESSFUL edit, and all four observers wrote
    /// `try? await session.transport.editMessage(...)` and then deleted `hitlMessageIDs[operationID]`
    /// on the very next line — discarding the id needed to repair the message in the same breath.
    /// The second tap then goes nowhere silently, forever.
    ///
    /// Mutation that must turn this red: restore any `try? await session.transport.editMessage`.
    func testResolvedPromptsReportAFailedRewrite() throws {
        let source = try Self.source("Devgentic/ChatOps/Services/RemoteMirrorService.swift")
        for (number, line) in Self.codeLines(source) where line.contains("try? await session.transport") {
            XCTFail("""
                RemoteMirrorService.swift:\(number) rewrites a resolved HITL prompt with a swallowed edit:
                \(line.trimmingCharacters(in: .whitespaces))
                Route it through `editResolvedPrompt(_:messageID:to:operationID:kind:)`.
                """)
        }
        // All four observers must go through the helper — one missed observer is one prompt kind
        // whose buttons stay live.
        let uses = source.components(separatedBy: "await self.editResolvedPrompt(").count - 1
        XCTAssertEqual(uses, 4, "expected the tool-approval, clarification, plan-review and gate observers to all rewrite through the helper")
    }

    // MARK: - Terminal arms

    /// ⚠️ A BARE `break` CANNOT NAME A CONSEQUENCE. These arms are reached by input that parsed to
    /// `.unknown` — including a button whose callback token no longer decodes, which chat scrollback
    /// keeps forever. The user taps, nothing changes, and nothing recorded that taps are arriving
    /// and dying, so a grammar change that orphans old buttons is invisible in the field.
    ///
    /// Mutation that must turn this red: replace any of those log lines with `break`.
    func testEveryRoutingSwitchEndsWithALogRatherThanABareBreak() throws {
        for bridge in ["ChatOpsBridge", "DiscordChatOpsBridge", "SlackChatOpsBridge"] {
            let source = try Self.source("Devgentic/ChatOps/Services/\(bridge).swift")

            // ⚠️⚠️ ANY BARE-BREAK ARM, NOT JUST `default:`. This test first checked only for the
            // literal "default:\n break" — and a mutation that turned the `.unknown` arm's log back
            // into a bare `break` sailed straight past it, because that arm is `case .unknown:`, not
            // `default:`. A guard that only recognises the shape it was written against is worth
            // very little; a drop is a drop whichever keyword introduces it.
            //
            // The three bridges currently contain ZERO of these, so the bar is absolute rather than
            // a count — a count would let a new one in each time an old one was fixed.
            for (number, line) in Self.codeLines(source) where line == "            break" {
                XCTFail("""
                    \(bridge).swift:\(number) ends a switch arm with a bare `break`. A `break` \
                    cannot name a consequence: if this arm drops a command, log it with \
                    [CHATOPS/SILENT]; if it is a filter that falls through to more routing, make \
                    that explicit by returning a value the way `routeHITL` does.
                    """)
            }

            XCTAssertTrue(source.contains("[CHATOPS/SILENT]"),
                          "\(bridge) no longer logs its dropped commands with the silent-drop tag")
        }
    }
}
