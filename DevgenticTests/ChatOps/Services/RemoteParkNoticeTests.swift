// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteParkNoticeTests.swift
//  DevgenticTests
//
//  Timeout inventory D-23 (owner decisions 2026-09-27). Remote and voice questions stay open —
//  HITL is unbounded — but the operator is told:
//  - a work-starting command delivered more than 10 min after it was sent is NOT run;
//  - a refused prompt names what the run is waiting on;
//  - Telegram's own retry_after is honoured;
//  - the Orb's approval window really is 30 s on WhisperKit, and can be re-opened.
//

import XCTest
@testable import devgentic

final class RemoteParkNoticeTests: XCTestCase {

    // MARK: - Stale remote commands

    func testAnOldWorkStartingCommandIsSkippedAndAFreshOneRuns() {
        let now = Date()
        XCTAssertNil(RemoteCommandAge.staleAge(sentAt: now.addingTimeInterval(-60), now: now))
        XCTAssertEqual(RemoteCommandAge.staleAge(sentAt: now.addingTimeInterval(-3 * 3600), now: now), 3 * 3600)
        XCTAssertNil(RemoteCommandAge.staleAge(sentAt: nil, now: now), "an unknown send time is never refused")
    }

    func testOnlyCommandsThatStartOrChangeWorkAreAgeGated() {
        XCTAssertTrue(RemoteCommandAge.isAgeGated(.freeText("deploy it")))
        XCTAssertTrue(RemoteCommandAge.isAgeGated(.cancel))
        XCTAssertTrue(RemoteCommandAge.isAgeGated(.newConversation))
        // Answers to a question that is still open are accepted at any age.
        XCTAssertFalse(RemoteCommandAge.isAgeGated(.approveHITL(operationID: UUID())))
        XCTAssertFalse(RemoteCommandAge.isAgeGated(.denyHITL(operationID: UUID())))
        XCTAssertFalse(RemoteCommandAge.isAgeGated(.clarificationResponse("main")))
        // Read-only commands answer with the current state.
        XCTAssertFalse(RemoteCommandAge.isAgeGated(.status))
    }

    func testEachPlatformsSendTimeIsRead() throws {
        XCTAssertEqual(RemoteCommandAge.telegramSentAt(1_790_000_000), Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(try XCTUnwrap(RemoteCommandAge.discordSentAt("2026-09-27T08:00:00.123000+00:00")).timeIntervalSince1970,
                       1_790_496_000.123, accuracy: 0.01)
        XCTAssertEqual(RemoteCommandAge.slackSentAt("1790000000.000200")?.timeIntervalSince1970 ?? 0,
                       1_790_000_000.0002, accuracy: 0.001)
        XCTAssertNil(RemoteCommandAge.slackSentAt("garbage"))
    }

    func testTheNoticeSaysItWasNotRunAndHowToRunIt() {
        let text = RemoteCommandAge.notice(age: 3 * 3600)
        XCTAssertTrue(text.contains("not run"), text)
        XCTAssertTrue(text.contains("Send it again"), text)
    }

    /// Wiring: each bridge consults the gate with its own platform's send time.
    func testEveryBridgeGatesOnAge() throws {
        for (file, reader) in [("ChatOpsBridge.swift", "telegramSentAt(update.message?.date)"),
                               ("DiscordChatOpsBridge.swift", "discordSentAt(message.timestamp)"),
                               ("SlackChatOpsBridge.swift", "slackSentAt(event.ts)")] {
            let text = try source("Devgentic/ChatOps/Services/\(file)")
            XCTAssertTrue(text.contains("RemoteCommandAge.isAgeGated(command)") && text.contains(reader),
                          "\(file) no longer skips stale commands")
        }
    }

    // MARK: - Refusal names what is pending

    func testARefusalWhileWaitingOnAHumanSaysWhat() {
        guard case .refused(let message, _) = RemoteTurnAdmission.decide(hasActiveRun: true, waitingOn: "your approval") else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(message.contains("your approval"), message)
        XCTAssertTrue(message.contains("/cancel"), message)
        XCTAssertFalse(message.contains("Still working"), "it is not working — it is waiting on the operator")
    }

    // MARK: - Telegram retry_after

    func testTelegramsRetryAfterIsHonouredAndSanitised() {
        XCTAssertEqual(TelegramListener.retryDelay(backoff: 1, error: TelegramAPIError.rateLimited(retryAfter: 30)), 30)
        XCTAssertEqual(TelegramListener.retryDelay(backoff: 60, error: TelegramAPIError.rateLimited(retryAfter: 5)), 60,
                       "never shorter than the backoff")
        XCTAssertEqual(TelegramListener.retryDelay(backoff: 2, error: TelegramAPIError.rateLimited(retryAfter: .infinity)), 2,
                       "a non-finite value falls back to the backoff (D-09)")
        XCTAssertEqual(TelegramListener.retryDelay(backoff: 1, error: TelegramAPIError.rateLimited(retryAfter: 1e9)), 3600)
        XCTAssertEqual(TelegramListener.retryDelay(backoff: 4, error: URLError(.timedOut)), 4)
    }

    // MARK: - Orb (source pins: the recognizers need a microphone)

    func testTheApprovalWindowIsNotCutShortBySilence() throws {
        let orb = try source("Devgentic/Orb/OrbSessionController.swift")
        XCTAssertFalse(orb.contains("no approval answer within"),
                       "silence ends the approval session at 8 s again — the real window on WhisperKit shrinks")
        XCTAssertEqual(orb.components(separatedBy: "Approval session ended with nothing heard").count - 1, 2,
                       "both recognizers must keep listening after a silent session inside the window")
        XCTAssertTrue(orb.contains("reopenVoiceApproval(token, via: \"push-to-talk\")")
                      && orb.contains("reopenVoiceApproval(token, via: \"a click on the orb\")"),
                      "a closed voice window can no longer be re-opened")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else {
            throw XCTSkip("\(path) not reachable — running outside a checkout")
        }
        return text
    }
}
