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

    func testEstimatedAttachmentChars_MirrorsInjectionClamps() {
        // A 5 MB file injects at most 50K chars — the estimate must clamp the
        // same way or it would wildly over-warn.
        XCTAssertEqual(
            PromptFitCheck.estimatedAttachmentChars(forFileSizes: [5_000_000]),
            DirectInjectionBudget.perFile
        )
        // Small files pass through at size.
        XCTAssertEqual(
            PromptFitCheck.estimatedAttachmentChars(forFileSizes: [18_379, 32_549]),
            18_379 + 32_549
        )
        // Many big files clamp at the total budget.
        XCTAssertEqual(
            PromptFitCheck.estimatedAttachmentChars(forFileSizes: Array(repeating: 60_000, count: 10)),
            DirectInjectionBudget.total
        )
        XCTAssertEqual(PromptFitCheck.estimatedAttachmentChars(forFileSizes: []), 0)
    }

    func testPreSendEstimate_ObservedTwoFileCase_TripsAdvisory() {
        // Run-3 turn 1 at ATTACH time: stat'd sizes ≈ char counts for code files.
        let chars = PromptFitCheck.estimatedAttachmentChars(forFileSizes: [18_379, 32_549])
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: chars, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 7, historyChars: 0
        )
        XCTAssertTrue(PromptFitCheck.exceeds(estimatedTokens: tokens, windowTokens: 8_192),
                      "the pre-send estimate must flag the same case the send-time check flags")
    }
}
