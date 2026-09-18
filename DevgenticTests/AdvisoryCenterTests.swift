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

    /// The estimate DROPS an oversized file rather than clamping it, because
    /// `readFileContentOrThrow` THROWS `.tooLarge` past the per-file budget instead of
    /// truncating — `assembleTextFileContent` records the failure and moves on, so the model
    /// never sees one character of it. The old clamp charged the full 50,000 regardless, and
    /// that phantom cost posted an overflow advisory the user could only clear by detaching a
    /// file that was costing nothing.
    ///
    /// The mechanics of the rule are `AttachmentSizingTests`' job. What is pinned here is the
    /// arithmetic the ADVISORY is computed from, including the case that suite does not cover:
    /// a batch of individually-oversized files, where the old clamp did not merely over-charge
    /// but saturated the total budget.
    func testEstimatedAttachmentChars_DoesNotBillFilesTheReaderRefuses() {
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [5_000_000], wrapperCharsPerFile: 0), 0,
            "a 5 MB file is refused whole — charging it the budget over-warns by 50K phantom chars"
        )
        // Files under the budget still pass through at size; the advisory must keep firing on
        // the attachments that genuinely do reach the prompt.
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(forFileSizes: [18_379, 32_549], wrapperCharsPerFile: 0),
            18_379 + 32_549
        )
        // Ten 60K files are ten separate refusals, not a filled 200K budget. Under the clamp
        // this read as the entire total budget — the worst version of the defect, since not
        // one of those files contributes anything to the request.
        XCTAssertEqual(
            PromptFitCheck.attachmentInjectionChars(
                forFileSizes: Array(repeating: 60_000, count: 10), wrapperCharsPerFile: 0),
            0
        )
        XCTAssertEqual(PromptFitCheck.attachmentInjectionChars(forFileSizes: [], wrapperCharsPerFile: 0), 0)
    }

    /// The consequence one layer up, which is this file's actual subject: an attachment set
    /// that ships nothing must not trip the banner. Under the clamp the same 600 KB priced at
    /// the full 200K budget — ~67K tokens against an 8K window — and fired an advisory whose
    /// stated cause did not exist.
    func testRefusedAttachmentsDoNotTripTheOverflowAdvisory() {
        let chars = PromptFitCheck.attachmentInjectionChars(
            forFileSizes: Array(repeating: 60_000, count: 10), wrapperCharsPerFile: 0)
        let tokens = PromptFitCheck.estimatedTokens(
            attachmentChars: chars, knowledgeChars: 0, retrievalChars: 0,
            queryChars: 7, historyChars: 0
        )
        XCTAssertFalse(PromptFitCheck.exceeds(estimatedTokens: tokens, windowTokens: 8_192),
                       "every one of these files is refused by the reader — the prompt is a bare query")
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
