// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SlackEventAdmissionTests.swift
//  devgenticTests
//
//  One Slack message must start exactly one agent run.
//
//  ⚠️⚠️ THE FAILURE THIS PINS (SL-3). Slack delivers a separate Socket Mode envelope per matching
//  event subscription. The standard bot recipe subscribes to BOTH `app_mention` and
//  `message.channels`, so `@Devgentic refactor the parser` arrived twice — neither copy carrying a
//  `bot_id` or `subtype`, both carrying the same `channel` and `text` — and `handleMessage` submitted
//  the same prompt twice. Two runs, double token spend, double tool execution. `SlackEvent.type` was
//  decoded and read by nothing in the whole tree.
//

import XCTest
@testable import devgentic

final class SlackEventAdmissionTests: XCTestCase {

    /// ⚠️ THE EXACT SCENARIO: one message, two subscriptions, two envelopes, same `ts`.
    func testTheSameMessageDeliveredTwiceRunsOnce() {
        var admission = SlackEventAdmission()

        let first = admission.admit(type: "app_mention", channel: "C1", ts: "1710000000.000100")
        let second = admission.admit(type: "message", channel: "C1", ts: "1710000000.000100")

        guard case .admit = first else { return XCTFail("the first delivery must run: \(first)") }
        guard case .duplicate(_, let type) = second else {
            return XCTFail("""
                The second delivery of the SAME message was admitted, so one prompt starts two agent \
                runs — double token spend and double tool execution. Got: \(second)
                """)
        }
        XCTAssertEqual(type, "message", "the log must name which delivery repeated")
    }

    /// ⚠️ ORDER MUST NOT MATTER. Slack does not promise which subscription's envelope arrives first.
    func testDeduplicationIsIndependentOfWhichEnvelopeArrivesFirst() {
        var admission = SlackEventAdmission()
        _ = admission.admit(type: "message", channel: "C1", ts: "1.1")
        let second = admission.admit(type: "app_mention", channel: "C1", ts: "1.1")
        guard case .duplicate = second else { return XCTFail("got \(second)") }
    }

    /// ⚠️⚠️ THE REASON THIS DEDUPLICATES INSTEAD OF FILTERING ON `type`. A `guard type == "message"`
    /// closes the double-run and silently breaks every workspace subscribed to `app_mention` ALONE —
    /// the bot simply stops answering. Each subscription on its own must still work.
    func testEitherSubscriptionAloneStillRuns() {
        for type in ["app_mention", "message"] {
            var admission = SlackEventAdmission()
            let decision = admission.admit(type: type, channel: "C1", ts: "1.1")
            guard case .admit = decision else {
                return XCTFail("""
                    A workspace subscribed only to `\(type)` gets no run at all. Type-filtering would \
                    do this; deduplicating must not.
                    """)
            }
        }
    }

    /// Distinct messages must both run — the dedup key is the message, not the channel.
    func testDifferentMessagesInOneChannelBothRun() {
        var admission = SlackEventAdmission()
        guard case .admit = admission.admit(type: "message", channel: "C1", ts: "1.1"),
              case .admit = admission.admit(type: "message", channel: "C1", ts: "2.2") else {
            return XCTFail("two different messages must both run")
        }
    }

    /// ⚠️ Slack's `ts` is unique within a CHANNEL, not across a workspace, so the key is scoped.
    func testTheSameTimestampInAnotherChannelIsNotADuplicate() {
        var admission = SlackEventAdmission()
        _ = admission.admit(type: "message", channel: "C1", ts: "1.1")
        let other = admission.admit(type: "message", channel: "C2", ts: "1.1")
        guard case .admit = other else {
            return XCTFail("a coincident `ts` in a different channel was treated as a duplicate: \(other)")
        }
    }

    /// ⚠️ REDELIVERY. An envelope not acked within three seconds is re-sent with the same `ts`, so a
    /// slow turn used to run twice. Same key, same fix.
    func testARedeliveredEnvelopeDoesNotRunAgain() {
        var admission = SlackEventAdmission()
        _ = admission.admit(type: "message", channel: "C1", ts: "1.1")
        guard case .duplicate = admission.admit(type: "message", channel: "C1", ts: "1.1") else {
            return XCTFail("a redelivery ran a second time")
        }
    }

    /// ⚠️ A NIL `ts` IS ADMITTED, NOT REFUSED — refusing makes the bot deaf for an event shape this
    /// build does not model, which is worse than risking a duplicate. The caller logs it.
    func testAnEventWithNoTimestampIsStillHandled() {
        var admission = SlackEventAdmission()
        guard case .admitUnidentified(let type) = admission.admit(type: "odd", channel: "C1", ts: nil) else {
            return XCTFail("an unidentifiable event must still be handled")
        }
        XCTAssertEqual(type, "odd")
        guard case .admitUnidentified = admission.admit(type: "odd", channel: "C1", ts: "") else {
            return XCTFail("an empty `ts` is as unidentifiable as a nil one")
        }
    }

    /// ⚠️ BOUNDED, because the bridge outlives the conversation and an unbounded set is a leak.
    /// The oldest identity is evicted; the newest — the one a duplicate would match — is kept.
    func testTheMemoryIsBoundedAndEvictsOldestFirst() {
        var admission = SlackEventAdmission()
        let oldest = "0.0"
        _ = admission.admit(type: "message", channel: "C1", ts: oldest)
        for i in 1...SlackEventAdmission.memory {
            _ = admission.admit(type: "message", channel: "C1", ts: "\(i).0")
        }

        guard case .admit = admission.admit(type: "message", channel: "C1", ts: oldest) else {
            return XCTFail("the oldest identity was not evicted — the set grows without bound")
        }
        guard case .duplicate = admission.admit(type: "message", channel: "C1",
                                                ts: "\(SlackEventAdmission.memory).0") else {
            return XCTFail("a recent identity was evicted; a real duplicate would now run twice")
        }
    }

    // MARK: - Wiring

    /// ⚠️ The policy is worth nothing if the bridge does not consult it. A decode-only test on
    /// `SlackEvent` cannot fail here, which is why the audit's own note asked for this.
    func testTheSlackBridgeConsultsAdmissionBeforeRouting() throws {
        let source = try ChatOpsSecurityTierMatrixTests.readSource("Devgentic/ChatOps/Services/SlackChatOpsBridge.swift")
        guard let admit = source.range(of: "guard admitOnce(event, channelID: channelID) else { return }"),
              let route = source.range(of: "await routeCommand(command, channelID: channelID)") else {
            return XCTFail("could not find both the admission check and the routing call in handleMessage")
        }
        XCTAssertTrue(admit.lowerBound < route.lowerBound,
                      "the duplicate check must run BEFORE the message is routed")
        XCTAssertTrue(source.contains("admission.admit(type:"),
                      "`admitOnce` no longer consults the admission record.")
        XCTAssertTrue(source.contains("private var admission = SlackEventAdmission()"), """
            The bridge no longer holds an admission record, so nothing remembers what has already run \
            and every duplicate delivery starts another agent run.
            """)
    }
}
