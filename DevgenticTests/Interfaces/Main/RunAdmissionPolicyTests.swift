//
//  RunAdmissionPolicyTests.swift
//  DevgenticTests
//
//  Cover for the INTERIM one-root-run-per-conversation rule — repo-root
//  `LLM_Execution_Concurrency_Design.md` §0.5 and the increment-1 follow-up.
//
//  What this protects, in two parts:
//
//  1. ONE ROOT RUN PER CONVERSATION — the product model's invariant. Without it, "the conversation
//     is the thing you stop" is a convention rather than a fact, and Stop is ambiguous.
//
//  2. THE SAME-MESSAGE TASK-HANDLE OVERWRITE. `ActiveStreamManager.activeTasks` is keyed by MESSAGE
//     and is the only cancellable handle for an entire run tree. Redo and Resume stream into a
//     pre-existing message (`updating:`), so two runs on ONE message means the second overwrites
//     the first's handle, and that `Task` cannot be reached by `cancelStream(for:)` from anywhere,
//     ever. Increment 1 removed the stored foreground slot and killed the clear-side clobber, but
//     could not reach this: only refusing the second CLAIM does.
//
//  ⚠️ The trigger is NOT "press Redo while a message streams" — the action row is gated on
//  `!message.isStreaming` (AgentBubbleContentView.swift:134) and the Resume chip likewise (`:98`),
//  so neither control is offered on the message being written to. It is a DOUBLE-PRESS during the
//  async history-resolve hop (MessagingCoordinator `regenerateResponse` / `resumeRun`), when the
//  message has not started streaming yet and the control is still live. That is why both paths
//  enforce this again AFTER the hop, not only at the entry point.
//
//  Constructs nothing — no view model, no ActiveStreamManager, no ChatMessage.
//

import XCTest
@testable import devgentic

final class RunAdmissionPolicyTests: XCTestCase {

    private let convA = UUID()
    private let convB = UUID()
    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private let cap = 5

    private func run(_ conversation: UUID, at offset: TimeInterval = 0, id: UUID = UUID()) -> ForegroundRunResolver.LiveRun {
        ForegroundRunResolver.LiveRun(
            messageID: id, conversationID: conversation,
            startedAt: t0.addingTimeInterval(offset), isParked: false
        )
    }

    // MARK: - Admitted

    func testAdmitsWhenNothingIsLive() {
        XCTAssertNil(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [])
        )
    }

    /// The scope boundary: a run streaming in ANOTHER conversation must not block a Redo here.
    func testAdmitsWhenTheLiveRunIsInAnotherConversation() {
        XCTAssertNil(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [run(convB)]),
            "a run in a different conversation is out of scope and must not block Redo"
        )
    }

    func testAdmitsAtOneBelowTheCap() {
        XCTAssertNil(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: cap - 1, cap: cap, live: [])
        )
    }

    // MARK: - THE GUARD: refuse a second root run in one conversation

    /// The zero-config repro: start a long run, scroll up, press Redo on an older message.
    func testRefusesRedoWhileAnotherRunIsLiveInTheSameConversation() {
        let live = run(convA)
        let refusal = RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [live])
        XCTAssertEqual(refusal, .conversationBusy(existingMessageID: live.messageID))
    }

    /// The blocking run IS the claim's own target message — the `activeTasks` overwrite itself.
    /// Reached by double-pressing Redo during the history-resolve hop: the first press has started
    /// streaming into this message by the time the second reaches `continueRegeneration`.
    func testRefusesRedoOnTheStreamingMessageItself() {
        let target = UUID()
        let live = run(convA, id: target)
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [live]),
            .conversationBusy(existingMessageID: target)
        )
    }

    /// The blocker reported must not depend on iteration order, so the log names the same run on
    /// every press.
    func testReportsTheEarliestStartedBlockerDeterministically() {
        let first = run(convA, at: 0)
        let second = run(convA, at: 10)

        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [first, second]),
            .conversationBusy(existingMessageID: first.messageID)
        )
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: [second, first]),
            .conversationBusy(existingMessageID: first.messageID),
            "input order must not change which blocker is reported"
        )
    }

    /// A run elsewhere must not mask a genuine same-conversation block.
    func testMixedConversationsStillRefusesOnTheLocalRun() {
        let mine = run(convA, at: 5)
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap,
                                                 live: [run(convB, at: 0), mine, run(convB, at: 9)]),
            .conversationBusy(existingMessageID: mine.messageID)
        )
    }

    // MARK: - Attempt cap (folded in so the view and the runtime cannot drift)

    func testRefusesAtTheCap() {
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: cap, cap: cap, live: []),
            .attemptCapReached(attempts: cap, cap: cap)
        )
    }

    /// The permanent reason wins over the transient one — telling the user to wait would be a lie,
    /// because waiting does not make an over-cap message regenerable.
    func testCapIsReportedBeforeBusyWhenBothApply() {
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: cap, cap: cap, live: [run(convA)]),
            .attemptCapReached(attempts: cap, cap: cap)
        )
    }

    func testRefusesWhenThereIsNoResponseToRegenerate() {
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: nil, cap: cap, live: []),
            .noResponseToRegenerate
        )
    }

    /// The default `cap` argument must be the real constant — the drift this folding removed.
    func testDefaultCapMatchesChatMessageConstant() {
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: ChatMessage.maxGenerationAttempts, live: []),
            .attemptCapReached(attempts: ChatMessage.maxGenerationAttempts,
                               cap: ChatMessage.maxGenerationAttempts)
        )
        XCTAssertNil(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: ChatMessage.maxGenerationAttempts - 1, live: [])
        )
    }

    // MARK: - Resume (same rule, NO attempt cap)

    func testAdmitsResumeWhenNothingIsLive() {
        XCTAssertNil(RunAdmissionPolicy.admitResume(in: convA, live: []))
    }

    func testAdmitsResumeWhenTheLiveRunIsInAnotherConversation() {
        XCTAssertNil(RunAdmissionPolicy.admitResume(in: convA, live: [run(convB)]))
    }

    /// The double-press race: chip pressed twice during the async history-resolve hop. The first
    /// press has claimed the stream by the time the second reaches `continueResume`.
    func testRefusesResumeWhileARunIsLiveInTheSameConversation() {
        let live = run(convA)
        XCTAssertEqual(
            RunAdmissionPolicy.admitResume(in: convA, live: [live]),
            .conversationBusy(existingMessageID: live.messageID)
        )
    }

    /// A resume re-enters the original run; it never calls `beginRegenerationVariant` and never
    /// consumes an attempt. Folding the cap in would refuse a legitimate post-crash resume on a
    /// message that had simply been retried five times BEFORE the crash.
    func testResumeIgnoresTheAttemptCap() {
        XCTAssertNil(
            RunAdmissionPolicy.admitResume(in: convA, live: []),
            "resume must not be gated by generation attempts"
        )
        // And the regeneration path on the very same conversation IS capped — proving the two
        // entry points genuinely differ rather than one delegating wholesale to the other.
        XCTAssertEqual(
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: ChatMessage.maxGenerationAttempts, live: []),
            .attemptCapReached(attempts: ChatMessage.maxGenerationAttempts,
                               cap: ChatMessage.maxGenerationAttempts)
        )
    }

    func testResumeReportsTheEarliestStartedBlockerDeterministically() {
        let first = run(convA, at: 0), second = run(convA, at: 10)
        XCTAssertEqual(RunAdmissionPolicy.admitResume(in: convA, live: [first, second]),
                       .conversationBusy(existingMessageID: first.messageID))
        XCTAssertEqual(RunAdmissionPolicy.admitResume(in: convA, live: [second, first]),
                       .conversationBusy(existingMessageID: first.messageID))
    }

    /// Both entry points must agree on the shared rule — that is the point of factoring it.
    func testResumeAndRegenerationAgreeOnTheBusyRule() {
        let live = [run(convA, at: 3), run(convB, at: 1)]
        XCTAssertEqual(
            RunAdmissionPolicy.admitResume(in: convA, live: live),
            RunAdmissionPolicy.admitRegeneration(in: convA, attempts: 1, cap: cap, live: live)
        )
        XCTAssertEqual(
            RunAdmissionPolicy.admitResume(in: convB, live: live),
            RunAdmissionPolicy.admitRegeneration(in: convB, attempts: 1, cap: cap, live: live)
        )
    }

    // MARK: - Messaging

    func testEveryRefusalCarriesUserFacingAndLogText() {
        let all: [RunAdmissionPolicy.Refusal] = [
            .conversationBusy(existingMessageID: UUID()),
            .attemptCapReached(attempts: 5, cap: 5),
            .noResponseToRegenerate
        ]
        for refusal in all {
            XCTAssertFalse(refusal.userFacingReason.isEmpty)
            XCTAssertTrue(refusal.logReason.contains("CONSEQUENCE:"),
                          "every refusal must state its consequence per the logging standard: \(refusal)")
        }
    }

    /// The user-facing string must not leak internal identifiers into a tooltip.
    func testUserFacingReasonDoesNotLeakIdentifiers() {
        let id = UUID()
        let text = RunAdmissionPolicy.Refusal.conversationBusy(existingMessageID: id).userFacingReason
        XCTAssertFalse(text.contains(id.uuidString))
        XCTAssertFalse(text.contains(id.uuidString.prefix(8)))
    }
}
