// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RAGRetrievalBudgetTests.swift
//  devgenticTests
//
//  Created on 11/07/26.
//
//  Covers the retrieval injection budget: retrieved parent texts are clamped
//  (8K/parent, 24K total) and — critically — windowed AROUND the matched chunk,
//  not head-clamped. The head-clamp bug made every symbol past a file's first
//  8K chars unanswerable ("does not contain…") even though retrieval found the
//  right document.
//

import XCTest
@testable import devgentic

final class RAGRetrievalBudgetTests: XCTestCase {

    // MARK: - Assembly basics

    func testAssemble_UnderBudget_JoinedUnchanged() {
        let out = RAGRetrievalBudget.assemble([(text: "short one", anchor: nil), (text: "short two", anchor: nil)])
        XCTAssertEqual(out, "short one\n\nshort two")
    }

    func testAssemble_EmptyInput_EmptyOutput() {
        XCTAssertEqual(RAGRetrievalBudget.assemble([]), "")
    }

    func testAssemble_TotalBudget_DropsDocsPastTheCap() {
        // Each doc exactly fills the per-parent budget: 3 fit inside the 24K
        // total, the 4th must be dropped entirely.
        let doc = String(repeating: "b", count: RAGRetrievalBudget.perParent)
        let out = RAGRetrievalBudget.assemble(Array(repeating: (text: doc, anchor: String?.none), count: 4))
        XCTAssertEqual(out.components(separatedBy: "\n\n").count, 3)
    }

    // MARK: - Window placement

    func testWindow_NoAnchor_HeadWindowMarked() {
        let big = String(repeating: "a", count: RAGRetrievalBudget.perParent + 2_000)
        let out = RAGRetrievalBudget.window(for: big, anchor: nil, budget: RAGRetrievalBudget.perParent)
        XCTAssertTrue(out.hasSuffix("… [truncated]"), "truncation must be visible to the model")
        XCTAssertLessThanOrEqual(out.count, RAGRetrievalBudget.perParent + 32)
    }

    func testWindow_CentersOnAnchor_PreservingFileHeader() {
        // Symbol sits ~24K into a 28K file — beyond any head window.
        let filler = String(repeating: "x", count: 24_000)
        let symbolRegion = "private func addAttachedFiles(fileItems: [FileSystemItem]) { attach() }"
        let tail = String(repeating: "y", count: 4_000)
        let text = "[File: ChatInputAreaView.swift]\n" + filler + symbolRegion + tail

        let out = RAGRetrievalBudget.window(for: text, anchor: symbolRegion, budget: RAGRetrievalBudget.perParent)

        XCTAssertTrue(out.contains("addAttachedFiles"), "window must contain the matched region — the head-clamp bug this fixes")
        XCTAssertTrue(out.hasPrefix("[File: ChatInputAreaView.swift]"), "identity line survives head trimming")
        XCTAssertTrue(out.contains("earlier chars omitted"), "trimmed head must be marked")
        XCTAssertLessThanOrEqual(out.count, RAGRetrievalBudget.perParent + 128)
    }

    func testWindow_AnchorNearTail_ReanchorsToTextEnd() {
        let text = String(repeating: "m", count: 20_000) + "END_SYMBOL_marker"
        let out = RAGRetrievalBudget.window(for: text, anchor: "END_SYMBOL_marker", budget: 8_000)
        XCTAssertTrue(out.contains("END_SYMBOL_marker"))
        XCTAssertFalse(out.hasSuffix("… [truncated]"), "window reaches the text end — no tail marker")
        XCTAssertTrue(out.contains("earlier chars omitted"))
    }

    func testWindow_AnchorNotFound_FallsBackToHead() {
        let big = String(repeating: "z", count: 12_000)
        let out = RAGRetrievalBudget.window(for: big, anchor: "not-present-anywhere", budget: 8_000)
        XCTAssertTrue(out.hasPrefix("zzzz"))
        XCTAssertTrue(out.hasSuffix("… [truncated]"))
    }

    func testWindow_SmallTextReturnedWhole() {
        let text = "tiny document"
        XCTAssertEqual(RAGRetrievalBudget.window(for: text, anchor: "document", budget: 8_000), text)
    }

    // MARK: - Context-window scaling

    func testBudgets_CloudWindow_KeepsCeilings() {
        let b = RAGRetrievalBudget.budgets(forContextWindowTokens: 128_000)
        XCTAssertEqual(b.total, RAGRetrievalBudget.total)
        XCTAssertEqual(b.perParent, RAGRetrievalBudget.perParent)
    }

    func testBudgets_LocalWindow_ScalesDown() {
        // 8192-token local model (gemma-class): ≈15% of window at 3 chars/token.
        let b = RAGRetrievalBudget.budgets(forContextWindowTokens: 8_192)
        XCTAssertLessThan(b.total, 5_000, "a local window must not receive the 24K cloud injection")
        XCTAssertGreaterThanOrEqual(b.total, RAGRetrievalBudget.minTotal)
        XCTAssertEqual(b.perParent, b.total / 2)
    }

    func testBudgets_TinyWindow_HitsFloors() {
        let b = RAGRetrievalBudget.budgets(forContextWindowTokens: 2_048)
        XCTAssertEqual(b.total, RAGRetrievalBudget.minTotal)
        XCTAssertEqual(b.perParent, RAGRetrievalBudget.minPerParent)
    }

    func testAssemble_CustomBudgets_BoundOutput() {
        let doc = String(repeating: "q", count: 5_000)
        let out = RAGRetrievalBudget.assemble(
            [(text: doc, anchor: nil), (text: doc, anchor: nil), (text: doc, anchor: nil)],
            perParent: 1_000,
            total: 2_000
        )
        XCTAssertLessThanOrEqual(out.count, 2_200, "scaled budgets must bound the total injection")
        XCTAssertTrue(out.contains("… [truncated]"))
    }

    func testWindow_StripsCodeChunkContextPrefixFromAnchor() {
        // Tree-Sitter chunks carry "[lang Context]:\n" which is NOT in the stored
        // document — the window must strip it or code anchors never match and
        // silently fall back to the head.
        let filler = String(repeating: "w", count: 20_000)
        let symbolRegion = "func addAttachedFiles(fileItems: [String]) { files.append(contentsOf: fileItems) }"
        let text = "[File: AttachmentManager.swift]\n" + filler + symbolRegion

        let anchor = "[swift Context]:\n" + symbolRegion
        let out = RAGRetrievalBudget.window(for: text, anchor: anchor, budget: 8_000)

        XCTAssertTrue(out.contains("addAttachedFiles"), "prefixed code anchor must still center the window on the match")
        XCTAssertTrue(out.contains("earlier chars omitted"))
    }
}
