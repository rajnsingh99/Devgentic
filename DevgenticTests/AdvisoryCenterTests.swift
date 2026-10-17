// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AdvisoryCenterTests.swift
//  devgenticTests
//
//  Created on 12/07/26.
//
//  Covers the advisory banner's lifecycle contract: one advisory surfaced per
//  conversation, dedupe-key update-in-place (never stacks), dismissal suppresses
//  the exact situation until its inputs change, and clear() self-heals the
//  banner when the condition resolves. Plus the PromptFitCheck estimate that
//  gates the context-overflow advisory.
//

import XCTest
@testable import devgentic

@MainActor
final class AdvisoryCenterTests: XCTestCase {

    private func makeAdvisory(
        conversation: UUID,
        message: String = "warning",
        key: String
    ) -> Advisory {
        Advisory(
            conversationID: conversation,
            category: .contextOverflow,
            message: message,
            actionLabel: "Open Settings",
            action: .openProfileSettings(profileID: UUID()),
            dedupeKey: key
        )
    }

    func testPost_SurfacesCurrentForConversation() {
        let center = AdvisoryCenter()
        let conv = UUID()
        center.post(makeAdvisory(conversation: conv, key: "k1"))
        XCTAssertEqual(center.current(for: conv)?.dedupeKey, "k1")
        XCTAssertNil(center.current(for: UUID()), "advisories are per-conversation")
    }

    func testPost_SameDedupeKey_UpdatesInPlaceNeverStacks() {
        let center = AdvisoryCenter()
        let conv = UUID()
        center.post(makeAdvisory(conversation: conv, message: "v1", key: "k1"))
        center.post(makeAdvisory(conversation: conv, message: "v2", key: "k1"))
        XCTAssertEqual(center.advisories.count, 1, "same situation must update, not stack")
        XCTAssertEqual(center.current(for: conv)?.message, "v2")
    }

    func testDismiss_SuppressesSameSituation_AllowsChangedSituation() {
        let center = AdvisoryCenter()
        let conv = UUID()
        let advisory = makeAdvisory(conversation: conv, key: "conv|overflow|profileA|4096")
        center.post(advisory)
        center.dismiss(center.current(for: conv)!)
        XCTAssertNil(center.current(for: conv))

        // Reposting the SAME situation stays suppressed…
        center.post(makeAdvisory(conversation: conv, key: "conv|overflow|profileA|4096"))
        XCTAssertNil(center.current(for: conv), "dismissed situation must not re-surface")

        // …but a CHANGED situation (e.g. window raised → new key) shows again.
        center.post(makeAdvisory(conversation: conv, key: "conv|overflow|profileA|16384"))
        XCTAssertNotNil(center.current(for: conv))
    }

    func testClear_SelfHealsWhenConditionResolves() {
        let center = AdvisoryCenter()
        let conv = UUID()
        let otherConv = UUID()
        center.post(makeAdvisory(conversation: conv, key: "k1"))
        center.post(makeAdvisory(conversation: otherConv, key: "k2"))

        center.clear(category: .contextOverflow, conversationID: conv)

        XCTAssertNil(center.current(for: conv), "resolved condition removes the banner")
        XCTAssertNotNil(center.current(for: otherConv), "other conversations unaffected")
    }

    func testClear_DoesNotSuppressFutureOccurrences() {
        let center = AdvisoryCenter()
        let conv = UUID()
        center.post(makeAdvisory(conversation: conv, key: "k1"))
        center.clear(category: .contextOverflow, conversationID: conv)
        // Condition re-occurs later (files attached again) — must show again,
        // unlike an explicit user dismissal.
        center.post(makeAdvisory(conversation: conv, key: "k1"))
        XCTAssertNotNil(center.current(for: conv))
    }
}

final class PromptFitCheckTests: XCTestCase {

    func testEstimate_SumsPartsPlusOverhead() {
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: 30_000, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 1_000, historyChars: 0
        )
        // (30_000 + 1_000 + 2_000 overhead) / 3
        XCTAssertEqual(tokens, 11_000)
    }

    func testExceeds_RespectsResponseHeadroom() {
        // 75% of an 8192-token window = 6144 usable.
        XCTAssertFalse(PromptFitCheck.exceeds(estimatedTokens: 6_000, windowTokens: 8_192))
        XCTAssertTrue(PromptFitCheck.exceeds(estimatedTokens: 6_500, windowTokens: 8_192))
    }

    func testObservedManualTestCase_TwoFilesOnGemma_Exceeds() {
        // Run-3 turn 1: 18,379 + 32,549 chars of attachments into an 8K window.
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: 18_379 + 32_549, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 7, historyChars: 0
        )
        XCTAssertTrue(PromptFitCheck.exceeds(estimatedTokens: tokens, windowTokens: 8_192),
                      "the observed truncation case must trip the advisory")
    }

    func testSmallPromptOnCloudWindow_Fits() {
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: 50_000, knowledgeChars: 20_000, retrievalChars: 4_000,
            queryChars: 500, historyChars: 30_000
        )
        XCTAssertFalse(PromptFitCheck.exceeds(estimatedTokens: tokens, windowTokens: 200_000))
    }

    func testRoundedK_Formatting() {
        XCTAssertEqual(PromptFitCheck.roundedK(8_192), "8K")
        XCTAssertEqual(PromptFitCheck.roundedK(200_000), "200K")
        XCTAssertEqual(PromptFitCheck.roundedK(900), "900")
    }

    // MARK: - Composer-side attachment estimate (pre-send hint)

    /// The estimate bills what the injection plan SHIPS (user decision 2026-10-04: an
    /// over-budget text file is CUT to the budget, no longer dropped whole):
    ///  • a file past the READ cap is never read, so it costs nothing;
    ///  • a file past the per-file budget costs the slice that ships plus its marker;
    ///  • files within budget pass through at size.
    /// The mechanics are `AttachmentSizingTests`' job; this pins the advisory's inputs.
    func testEstimatedAttachmentChars_BillsWhatThePlanShips() {
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [5_000_000], wrapperCharsPerFile: 0), 0,
            "a 5 MB file is past the read cap — it is never read, so the model gets none of it"
        )
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [18_379, 32_549], wrapperCharsPerFile: 0),
            18_379 + 32_549
        )
        let cut = PromptFitCheck.attachmentInjectionChars(forFileSizes: [120_000], wrapperCharsPerFile: 0)
        XCTAssertEqual(
            cut,
            DirectInjectionBudget.perFile
                + DirectInjectionPlan.truncationMarker(sent: DirectInjectionBudget.perFile, total: 120_000).count,
            "an over-budget file ships its first perFile chars plus the marker"
        )
        XCTAssertEqual(PromptFitCheck.attachmentInjectionChars(forFileSizes: [], wrapperCharsPerFile: 0), 0)
    }

    /// The consequence one layer up: a file the reader never reads must not trip the banner,
    /// while ten 60K files — which now ship ~200K of cut content — must.
    func testAdvisoryTracksWhatActuallyShips() {
        let unread = PromptFitCheck.attachmentInjectionChars(forFileSizes: [5_000_000], wrapperCharsPerFile: 0)
        XCTAssertFalse(PromptFitCheck.exceeds(
            estimatedTokens: PromptFitCheck.estimatedTokens(
                attachmentChars: unread, knowledgeChars: 0, retrievalChars: 0, queryChars: 7, historyChars: 0),
            windowTokens: 8_192))

        let cut = PromptFitCheck.attachmentInjectionChars(
            forFileSizes: Array(repeating: 60_000, count: 10), wrapperCharsPerFile: 0)
        XCTAssertTrue(PromptFitCheck.exceeds(
            estimatedTokens: PromptFitCheck.estimatedTokens(
                attachmentChars: cut, knowledgeChars: 0, retrievalChars: 0, queryChars: 7, historyChars: 0),
            windowTokens: 8_192),
            "cut content reaches the prompt — the old 'refused, costs nothing' premise no longer holds")
    }

    func testPreSendEstimate_ObservedTwoFileCase_TripsAdvisory() {
        // Run-3 turn 1 at ATTACH time: stat'd sizes ≈ char counts for code files.
        let chars = PromptFitCheck.attachmentInjectionChars(forFileSizes: [18_379, 32_549], wrapperCharsPerFile: 0)
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: chars, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 7, historyChars: 0
        )
        XCTAssertTrue(PromptFitCheck.exceeds(estimatedTokens: tokens, windowTokens: 8_192),
                      "the pre-send estimate must flag the same case the send-time check flags")
    }
}

/// Phase 7 run banners: a run's state outranks ambient advice, and cannot be dismissed away.
@MainActor
final class AdvisoryRunBannerTests: XCTestCase {

    private func run(_ conv: UUID, _ category: Advisory.Category, priority: Int) -> Advisory {
        Advisory(conversationID: conv, category: category, message: "\(category)", actionLabel: nil, action: nil,
                 dedupeKey: "\(conv)|\(category)", tone: .info, dismissible: false, priority: priority)
    }

    /// ⚠️ Before phase 7 the latest post won: a fit hint posted while the user typed HID the banner
    /// saying their run was waiting.
    func testAnAmbientHintPostedLaterDoesNotHideARunBanner() {
        let center = AdvisoryCenter()
        let conv = UUID()
        center.post(run(conv, .localModelBusy, priority: Advisory.runStatePriority))
        center.post(Advisory(conversationID: conv, category: .contextOverflow, message: "fit", actionLabel: nil, action: nil, dedupeKey: "fit"))
        XCTAssertEqual(center.current(for: conv)?.category, .localModelBusy)
        center.clear(category: .localModelBusy, conversationID: conv)
        XCTAssertEqual(center.current(for: conv)?.category, .contextOverflow, "the hint shows once the run state is gone")
    }

    func testTheQuestionOutranksTheQueueStatus() {
        let center = AdvisoryCenter()
        let conv = UUID()
        center.post(run(conv, .runNeedsConfirmation, priority: Advisory.runQuestionPriority))
        center.post(run(conv, .localModelBusy, priority: Advisory.runStatePriority))
        XCTAssertEqual(center.current(for: conv)?.category, .runNeedsConfirmation)
    }

    func testARunBannerCannotBeDismissed() {
        let center = AdvisoryCenter()
        let conv = UUID()
        let banner = run(conv, .runNeedsConfirmation, priority: Advisory.runQuestionPriority)
        center.post(banner)
        center.dismiss(banner)
        XCTAssertEqual(center.current(for: conv)?.category, .runNeedsConfirmation)
    }

    func testTheCountdownReadsMinutesAndSecondsAndStopsAtZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(AdvisoryBannerStyle.remaining(until: now.addingTimeInterval(120), now: now), "2:00")
        XCTAssertEqual(AdvisoryBannerStyle.remaining(until: now.addingTimeInterval(61.2), now: now), "1:02")
        XCTAssertEqual(AdvisoryBannerStyle.remaining(until: now.addingTimeInterval(-5), now: now), "0:00")
    }

    func testTheQuestionNamesTheConcernWithoutAdvice() {
        let text = ActiveStreamManager.confirmationNotice([.memory(modelID: "qwen", estimatedBytes: 20 << 30, budgetBytes: 18 << 30)])
        XCTAssertTrue(text.hasPrefix("'qwen' is estimated at ~"), text)
        XCTAssertTrue(text.hasSuffix("It may run very slowly or fail."), text)
    }
}
