// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  WorkflowCanvasChromeTests.swift
//  DevgenticTests
//
//  Created by Raj Singh.
//

import XCTest
@testable import devgentic

@MainActor
final class WorkflowCanvasChromeTests: XCTestCase {

    // MARK: - CVV-3 — the port badge is capped, the port label is not

    /// The reserved error port is a ROUTING KEY and must never wear an ellipsis.
    func testTheReservedErrorPortRendersInFull() {
        XCTAssertEqual(
            WorkflowCanvasState.portBadgeText(WorkflowEdge.errorPortLabel),
            WorkflowEdge.errorPortLabel
        )
    }

    func testTheShippedGateDefaultsRenderInFull() {
        for label in ["Approve", "Reject"] {
            XCTAssertEqual(WorkflowCanvasState.portBadgeText(label), label)
        }
    }

    /// ⚠️ The coupling the cap exists to express: EVERY label the Router inspector will accept must
    /// render in full. This assertion fails if anyone later lowers the badge cap below the Router
    /// label cap — which is the drift that would make a legal, validated label look truncated.
    func testEveryLegalRouterLabelRendersInFull() {
        for label in ["a", "Refund", "Escalate1", "ABCDEFGHIJ", "1234567890"] {
            XCTAssertTrue(ConditionNodeConfig.isValidLabel(label),
                          "\(label) must be a legal Router label for this test to mean anything")
            XCTAssertEqual(WorkflowCanvasState.portBadgeText(label), label,
                           "a label the inspector accepts must never be truncated on the canvas")
        }
    }

    /// The boundary: exactly at the cap is untouched; one over is capped.
    ///
    /// ⚠️ The cap's VALUE is named by literal here, not read from the constant. Building the probe
    /// from `portBadgeCharacterCap` makes the test self-referential — it would hold for any cap —
    /// which is the same trap that let a `revealMargin` mutation through earlier in this batch.
    func testTheCapBoundaryIsExact() {
        XCTAssertEqual(WorkflowCanvasState.portBadgeCharacterCap, 10)

        let atCap = "xxxxxxxxxx"                    // exactly 10
        XCTAssertEqual(atCap.count, 10)
        XCTAssertEqual(WorkflowCanvasState.portBadgeText(atCap), atCap)

        let overByOne = atCap + "y"                 // 11
        let rendered = WorkflowCanvasState.portBadgeText(overByOne)
        XCTAssertNotEqual(rendered, overByOne)
        XCTAssertEqual(rendered, "xxxxxxxxx\u{2026}",
                       "9 characters plus the ellipsis — the ellipsis is INSIDE the 10-character "
                       + "budget, not added on top of it, and it goes at the END")
    }

    /// The row's actual residual defect: an uncapped Gate option.
    func testALongGateOptionIsBoundedOnTheCanvas() {
        let option = "Approve and forward to compliance"
        let rendered = WorkflowCanvasState.portBadgeText(option)

        XCTAssertEqual(rendered.count, WorkflowCanvasState.portBadgeCharacterCap)
        XCTAssertTrue(rendered.hasSuffix("\u{2026}"))
    }

    func testAPathologicalLabelIsStillBounded() {
        let rendered = WorkflowCanvasState.portBadgeText(String(repeating: "z", count: 200))
        XCTAssertEqual(rendered.count, WorkflowCanvasState.portBadgeCharacterCap)
    }

    /// A label out of a persisted layout blob need not have come from the TextField. A newline
    /// would make the badge grow DOWN over the ports below, which `.fixedSize()` would honour.
    func testNewlinesAreFlattenedBeforeTheCap() {
        let rendered = WorkflowCanvasState.portBadgeText("Approve\nand continue")

        XCTAssertFalse(rendered.contains("\n"))
        XCTAssertTrue(rendered.hasPrefix("Approve "),
                      "the newline becomes a space rather than being dropped, so words do not fuse")
    }

    func testCarriageReturnsAndTabsAreFlattenedToo() {
        XCTAssertFalse(WorkflowCanvasState.portBadgeText("a\rb").contains("\r"))
        XCTAssertFalse(WorkflowCanvasState.portBadgeText("a\tb").contains("\t"))
    }

    /// Grapheme safety: the cap counts CHARACTERS, so a refactor to unicode scalars or UTF-16 —
    /// which would split a flag emoji or a combining mark — breaks this rather than the rendering.
    func testTheCapCountsCharactersNotScalars() {
        let flags = String(repeating: "🇮🇳", count: 12)
        XCTAssertEqual(WorkflowCanvasState.portBadgeText(flags).count,
                       WorkflowCanvasState.portBadgeCharacterCap)
    }

    func testBadgeTextIsIdempotent() {
        for label in ["", "error", "Approve", String(repeating: "q", count: 40)] {
            let once = WorkflowCanvasState.portBadgeText(label)
            XCTAssertEqual(WorkflowCanvasState.portBadgeText(once), once, "label \(label)")
        }
    }

    /// ⚠️ The badge is COSMETIC. Capping at the source would be a silent port rename, and
    /// `WorkflowEdge.sourcePortLabel` is matched by exact string — so the port list a node exposes
    /// must stay the raw, uncapped text.
    func testCappingTheBadgeDoesNotCapTheRoutingPortItself() {
        let long = "Approve and forward to compliance"
        let node = WorkflowNode(
            kind: .gate(GateNodeConfig(prompt: "p", options: [long, "Reject"], timeout: nil)),
            position: .zero,
            displayName: "G"
        )

        let ports = WorkflowCanvasState.outputPortLabels(for: node)

        XCTAssertTrue(ports.contains(long),
                      "the routing key must survive verbatim — only the drawn badge is shortened")
        XCTAssertNotEqual(WorkflowCanvasState.portBadgeText(long), long)
    }

    // MARK: - CVV-9 — the empty placard must not cover the user's notes

    func testThePlacardShowsOnlyOnAGenuinelyEmptyCanvas() {
        XCTAssertTrue(WorkflowCanvasView.showsEmptyPlacard(nodeCount: 0, annotationCount: 0),
                      "a brand-new workflow must still get its invitation")
        XCTAssertFalse(WorkflowCanvasView.showsEmptyPlacard(nodeCount: 0, annotationCount: 1),
                       "annotations are content — this is the filed defect")
        XCTAssertFalse(WorkflowCanvasView.showsEmptyPlacard(nodeCount: 1, annotationCount: 0))
        XCTAssertFalse(WorkflowCanvasView.showsEmptyPlacard(nodeCount: 1, annotationCount: 1))
    }

    /// The annotations-only state is reachable through the ordinary Add Note path, not contrived.
    func testAddingTheFirstStickyNoteWithdrawsThePlacard() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        XCTAssertTrue(WorkflowCanvasView.showsEmptyPlacard(
            nodeCount: s.nodes.count, annotationCount: s.annotations.count))

        s.addStickyNote()

        XCTAssertFalse(WorkflowCanvasView.showsEmptyPlacard(
            nodeCount: s.nodes.count, annotationCount: s.annotations.count))
    }

    /// …and it round-trips, so the placard would have covered the notes on every later open too.
    func testAnAnnotationsOnlyLayoutSurvivesAReload() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        s.addStickyNote()
        let saved = s.currentLayout()

        let reopened = WorkflowCanvasState(profileID: s.profileID)
        reopened.load(from: saved)

        XCTAssertTrue(reopened.nodes.isEmpty)
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertFalse(WorkflowCanvasView.showsEmptyPlacard(
            nodeCount: reopened.nodes.count, annotationCount: reopened.annotations.count))
    }

    /// Why the collision is the DEFAULT rather than an edge case: the first note lands dead centre
    /// in the viewport, which is exactly where the placard — including its button — is drawn.
    ///
    /// ⚠️ The ANSWER IS NAMED, not bounded by a tolerance derived from the note. Asserting the
    /// centre to within half the note's own size gave 90×60pt of slack, which is exactly the error
    /// produced by deleting the centring — placing the note's top-left AT the viewport centre
    /// passed. `nextAvailablePosition` centres its 220×120 probe envelope (not the 180×120 note),
    /// so on a 1000×800 viewport with no pan the origin is (500−110, 400−60).
    func testTheFirstNoteLandsWhereThePlacardIsDrawn() {
        let s = WorkflowCanvasState(profileID: UUID())
        s.load(from: WorkflowLayout(nodes: [], edges: [], annotations: []))
        s.viewportSize = CGSize(width: 1000, height: 800)

        s.addStickyNote()

        XCTAssertEqual(s.annotations[0].position, CGPoint(x: 390, y: 340),
                       "the note must be centred on the viewport, where the placard is drawn")
        XCTAssertEqual(s.visibleCanvasCenter, CGPoint(x: 500, y: 400),
                       "…and that is the viewport centre, stated independently")
    }
}
