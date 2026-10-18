// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsSilentDropTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
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
        // ⚠️ Added when the sweep went tree-wide (OBS-3). Each is a `try?` that ASKS a question
        //    rather than dropping something; a nil answer is the answer, not a lost payload.
        "AnyCodableValue": "a type-probe decode: `try?` is asking WHICH json type this is, and nil is a valid answer",
        "?? false": "a defaulted read — the fallback IS the decision, and it is written at the call site",
        "?? true": "same as `?? false`",
        "retry_after": "a missing pacing hint means no hint, not a dropped message",
        "decodeNil": "a type probe, as with AnyCodableValue",
    ]

    /// Files exempt from the tree-wide `try?` sweep, each with the reason.
    ///
    /// ⚠️ BY FILE AND BY REASON, never by count. `ChatOpsCommandService`'s own doc comment already
    /// states its exemption and that it wants `throws` in a commit of its own; recording that here
    /// keeps the sweep honest instead of silently tolerant.
    private static let exemptFiles: [String: String] = [
        "DiscordModels.swift": "AnyCodableValue's type probes — `try?` asks which JSON type a value is",
        "SlackModels.swift": "same type-probe shape as DiscordModels",
        "ChatOpsCommandService.swift": "documented at its own :114-118 — the store reads want `throws`, in a commit of their own",
    ]

    /// ⚠️ Both local readers were deleted in favour of `ChatOpsSourceScan`. The one here stripped
    /// WHOLE comment lines only, so a trailing `// …` after code was still scanned — while two sibling
    /// test files stripped to end-of-line. Three readers that disagree is three different answers to
    /// "is this line code".
    private static func source(_ relativePath: String) throws -> String {
        try ChatOpsSecurityTierMatrixTests.readSourceStrippingComments(relativePath)
    }

    private static func codeLines(_ source: String) -> [(number: Int, text: String)] {
        ChatOpsSourceScan.lines(source)
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
        // ⚠️ ANCHORED ON THE PROPERTY, NOT ON A CALL COUNT. This used to require exactly four literal
        // `await self.editResolvedPrompt(` sites; routing all four observers through ONE applier
        // (which is also where a resolution arriving mid-post is parked) holds the invariant
        // strictly better. What must stay true: every observer that computes a resolved status
        // HANDS IT OVER — one that computes a verdict and drops it is one prompt kind whose buttons
        // stay live on a decided prompt.
        let verdicts = source.components(separatedBy: "let statusText").count - 1
        let handoffs = source.components(separatedBy: "await self.applyResolution(").count - 1
        XCTAssertGreaterThanOrEqual(verdicts, 4, """
            expected the tool-approval, clarification, plan-review and gate observers to each \
            compute a resolved status; found \(verdicts)
            """)
        XCTAssertEqual(handoffs, verdicts, """
            \(verdicts) resolution observers compute a status but only \(handoffs) hand it to the \
            shared applier — the odd one out rewrites the prompt on its own or drops the resolution.
            """)
    }

    // MARK: - Terminal arms

    /// ⚠️⚠️ A BARE `break` CANNOT NAME A CONSEQUENCE — and this test used to be unable to find one.
    /// Its predicate was `line == "            break"`: full-line equality against exactly twelve
    /// spaces, four lines below its own comment warning that "a guard that only recognises the shape
    /// it was written against is worth very little". A `break` at 16 or 20 spaces (any nested switch),
    /// one with a trailing space, and every one-line `default: break` all passed it.
    ///
    /// ⚠️ NOW TREE-WIDE, which only became possible with a real discriminator: bare `break` is also
    /// how you leave a loop or a `catch`, and ChatOps contains 14 of those that are perfectly correct.
    /// `ChatOpsSourceScan.isSwitchArmBreak` keys on the previous code line ending in `:`, which
    /// separates a switch arm from a loop exit cleanly.
    func testNoSwitchArmInChatOpsDropsItsInputOnABareBreak() throws {
        let files = try ChatOpsSourceScan.chatOpsFiles()
        XCTAssertGreaterThan(files.count, 30, "the sweep found almost nothing — it is not reading the tree")

        var offenders: [String] = []
        for file in files {
            guard !Self.exemptSwitchArms.keys.contains(file.name) else { continue }
            let lines = ChatOpsSourceScan.lines(file.code)
            for (index, line) in lines.enumerated() {
                if ChatOpsSourceScan.isSwitchArmBreak(lines, at: index)
                    || ChatOpsSourceScan.isInlineSwitchArmBreak(line.text) {
                    offenders.append("\(file.name):\(line.number)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These switch arms drop their input on a bare `break`, which cannot name a consequence: \
            \(offenders). Log it with [CHATOPS/SILENT], or add a NAMED exemption to `exemptSwitchArms` \
            saying why the drop is a non-event.
            """)
    }

    /// Switch arms that may stay bare, each with the reason.
    ///
    /// ⚠️⚠️ THESE ARE NON-EVENTS, AND LOGGING THEM WOULD BE THE WORSE BUG. `PairingAttemptPolicy`'s
    /// header is the precedent: a line per message buries the one event that matters. Discord's opcode
    /// and dispatch-name switches see HEARTBEAT_ACK, GUILD_CREATE and PRESENCE_UPDATE continuously, and
    /// the pairing services see ordinary traffic for the whole five-minute window.
    private static let exemptSwitchArms: [String: String] = [
        "DiscordGatewayClient.swift": "op 11 HEARTBEAT_ACK and the dispatch-name default arrive continuously — a line per event is the burial PairingAttemptPolicy refuses",
        "DiscordPairingService.swift": "`.resumed` / `.interactionCreate` during a pairing window are ordinary traffic, not dropped commands",
        "SlackPairingService.swift": "`.interaction` / `.slashCommand` during a pairing window are ordinary traffic",
    ]

    // MARK: - The tree-wide swallow sweep

    /// ⚠️⚠️ THE SCAN USED TO NAME SIX FILES, AND THE TWO WORST SWALLOWS WERE IN A SEVENTH. Three
    /// hardcoded lists covered the bridges, two socket clients and the mirror — while
    /// `DiscordPairingService` and `SlackPairingService` each dropped the disconnect farewell on a
    /// `_ = try? await …`, the last message a user gets before their credentials are wiped. A list is
    /// a promise about what exists; a tree sweep is a fact about it.
    func testNoFileInChatOpsSwallowsAFailureWithABareTry() throws {
        let files = try ChatOpsSourceScan.chatOpsFiles()

        // ⚠️ NON-VACUITY, without which a moved directory reads as "clean".
        XCTAssertGreaterThan(files.count, 30, "the sweep is not reading the ChatOps tree")
        XCTAssertGreaterThan(files.filter { $0.code.contains("DGLogger(category:") }.count, 20,
                             "the sweep is reading the wrong tree")

        var offenders: [String] = []
        for file in files {
            guard Self.exemptFiles[file.name] == nil else { continue }
            let lines = ChatOpsSourceScan.lines(file.code)
            for (index, line) in lines.enumerated() where line.text.contains("try?") {
                let named = Self.deliberateSilence.keys.contains { line.text.contains($0) }
                if named || Self.failureIsObservable(lines, at: index) { continue }
                offenders.append("\(file.name):\(line.number) \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            These swallow a failure with no log: \(offenders.joined(separator: " | ")). \
            Use do/catch and name the CONSEQUENCE, or add a named entry to `deliberateSilence`.
            """)
    }

    // MARK: - Inbound filters must fail OPEN

    /// ⚠️⚠️ [BR-6] AN INBOUND FILTER THAT MATCHES "ANYTHING UNEXPECTED" EATS REAL COMMANDS. Slack's
    /// bridge guarded `event.subtype == nil`, which drops `file_share` — what Slack stamps on a
    /// message the operator typed WITH a file attached — before it can reach the routing switch, with
    /// no log and no reply. Telegram and Discord have no such pre-filter at all: an input they cannot
    /// route reaches `.unknown` and is logged with its consequence, which is why Slack alone could
    /// swallow a genuine command in silence.
    ///
    /// ⚠️ THE INVARIANT IS THE DIRECTION OF THE TEST, NOT THE LIST'S CONTENTS. An ignore-list means an
    /// unmodelled subtype is ROUTED and at worst logged; "not nil" meant it was eaten. Asserting the
    /// membership of `housekeepingSubtypes` would be asserting the implementation — a drift test in
    /// this subsystem was already found defending a defect that way.
    func testSlackDoesNotDropAMessageMerelyForHavingASubtype() throws {
        let source = try Self.source("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift")
        XCTAssertFalse(source.contains("event.subtype == nil"),
                       "the Slack bridge filters on \"has any subtype\", which fails CLOSED: a message "
                       + "carrying a file attachment is a real command and is eaten before routing")
        XCTAssertTrue(source.contains("housekeepingSubtypes"),
                      "the filter must name what it IGNORES, so an unmodelled subtype is routed rather than dropped")
        XCTAssertFalse(source.contains("\"file_share\""),
                       "file_share is a message the operator typed — it must never be in the ignore-list")
    }

    /// Whether this `try?`'s failure is visible to a reader of the logs.
    ///
    /// ⚠️⚠️ THE FIRST VERSION OF THIS SWEEP FLAGGED TWO SITES THAT WERE ALREADY CORRECT, and that is
    /// worth recording rather than quietly fixing: `RemoteConversationOriginStore.save` is
    /// `guard let data = try? … else { logger.error("…CONSEQUENCE: …") }`, and `TelegramAPIClient`'s
    /// 429 arm logs `retry_after=absent` on the very next line and throws regardless. Both are
    /// `try?` used as a DEFAULTED READ whose fallback is stated immediately. The offence is not the
    /// keyword — it is a failure nobody can see, so that is what the predicate must express.
    ///
    /// ⚠️ A four-line lookahead, not a parse. Deliberately crude and deliberately paired with the
    /// named allow-list: the cost of a false NEGATIVE here is one unlogged drop, while the cost of a
    /// false positive is pressure to "fix" correct code or to exempt a whole file — which is how an
    /// allow-list rots into a list of everything.
    private static func failureIsObservable(_ lines: [(number: Int, text: String)], at index: Int) -> Bool {
        for offset in 0...4 where index + offset < lines.count {
            if lines[index + offset].text.contains("logger.") { return true }
        }
        return false
    }

    /// ⚠️ The farewell is the one notice a user gets that the disconnect was deliberate. All three
    /// platforms must go through the shared seam — two of them swallowed it, which is this
    /// subsystem's signature one-fixed-two-unfixed shape.
    func testAllThreePlatformsSendTheirFarewellThroughTheSharedSeam() throws {
        for service in ["ChatOpsPairingService", "DiscordPairingService", "SlackPairingService"] {
            let source = try Self.source("Devgentic/ChatOps/Services/\(service).swift")
            XCTAssertTrue(source.contains("ChatOpsFarewell.send"),
                          "\(service) does not send its farewell through the shared seam, so its failure "
                          + "can be swallowed independently of the other two")
        }
    }
}
