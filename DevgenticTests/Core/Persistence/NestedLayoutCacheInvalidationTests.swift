// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  NestedLayoutCacheInvalidationTests.swift
//  DevgenticTests
//
//  Created on 29/08/26.
//
//  ⚠️ A canvas caches the layouts of the workflows its sub-workflow nodes point at, because
//  `revalidate()` runs on every node drag and inspector keystroke and resolving them walks the whole
//  nesting tree with a fetch per workflow. The cache was keyed on the SET of child ids alone — which
//  does not change when a child's CONTENT does — so editing a child left every parent validating
//  against a stale copy for the rest of its session. The nesting cycle and depth rules are `.error`
//  severity, so it failed both ways: a graph that had become cyclic still read "Workflow Ready", and
//  one whose cycle had been removed kept a blocking error nothing could clear.
//
//  `WorkflowLayoutStore.writeGeneration` is the invalidation signal. These tests pin it.
//

import XCTest
import SwiftData
@testable import devgentic

final class NestedLayoutCacheInvalidationTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([WorkflowLayoutSD.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func layout(nodeCount: Int) -> WorkflowLayout {
        WorkflowLayout(
            nodes: (0..<nodeCount).map {
                WorkflowNode(kind: .code(CodeNodeConfig()),
                             position: CGPoint(x: Double($0), y: 0),
                             displayName: "N\($0)")
            },
            edges: []
        )
    }

    /// THE SIGNAL. A child's CONTENT changing must move the generation — that is the whole fix,
    /// since the set of child ids is unchanged by such an edit.
    @MainActor
    func testSavingALayoutMovesTheWriteGeneration() throws {
        WorkflowLayoutStore.shared.configureContainer(try makeContainer())
        let child = UUID()

        let before = WorkflowLayoutStore.shared.writeGeneration
        XCTAssertEqual(WorkflowLayoutStore.shared.save(layout(nodeCount: 1), for: child), .saved)
        let afterFirst = WorkflowLayoutStore.shared.writeGeneration
        XCTAssertGreaterThan(afterFirst, before, "the first save of a workflow must move the generation")

        // The SAME workflow, more nodes inside it — the exact edit the old cache key could not see.
        XCTAssertEqual(WorkflowLayoutStore.shared.save(layout(nodeCount: 4), for: child), .saved)
        XCTAssertGreaterThan(WorkflowLayoutStore.shared.writeGeneration, afterFirst,
                             "editing a child's CONTENT must move the generation — its id set did not change")
    }

    /// Deleting a child is a change to what a parent's nesting validation sees, so it counts too.
    @MainActor
    func testDeletingALayoutMovesTheWriteGeneration() throws {
        WorkflowLayoutStore.shared.configureContainer(try makeContainer())
        let child = UUID()
        XCTAssertEqual(WorkflowLayoutStore.shared.save(layout(nodeCount: 1), for: child), .saved)

        let before = WorkflowLayoutStore.shared.writeGeneration
        WorkflowLayoutStore.shared.delete(for: child)
        XCTAssertGreaterThan(WorkflowLayoutStore.shared.writeGeneration, before)
    }

    /// ⚠️ The control that keeps the signal meaningful: a READ must not move it. If reads bumped the
    /// generation, the cache would miss on every validation and the fetch-per-keystroke cost the
    /// cache exists to avoid would come straight back.
    @MainActor
    func testReadingALayoutDoesNotMoveTheWriteGeneration() throws {
        WorkflowLayoutStore.shared.configureContainer(try makeContainer())
        let child = UUID()
        XCTAssertEqual(WorkflowLayoutStore.shared.save(layout(nodeCount: 2), for: child), .saved)

        let before = WorkflowLayoutStore.shared.writeGeneration
        _ = WorkflowLayoutStore.shared.load(for: child)
        _ = WorkflowLayoutStore.shared.storedCounts(for: child)
        _ = WorkflowLayoutStore.shared.isLayoutUnreadable(for: child)
        XCTAssertEqual(WorkflowLayoutStore.shared.writeGeneration, before,
                       "reads must not invalidate the cache")
    }

    /// A REFUSED write changed nothing on disk, so it must not invalidate anyone's cache either.
    @MainActor
    func testARefusedWriteDoesNotMoveTheWriteGeneration() throws {
        let container = try makeContainer()
        // Seed a row whose blob cannot be decoded — the store refuses to overwrite it.
        let context = ModelContext(container)
        let child = UUID()
        let row = WorkflowLayoutSD(workflowProfileID: child, layout: layout(nodeCount: 1))
        row.layoutData = Data(#"{"payloadFromTheFuture":true}"#.utf8)
        context.insert(row)
        try context.save()
        WorkflowLayoutStore.shared.configureContainer(container)

        let before = WorkflowLayoutStore.shared.writeGeneration
        let outcome = WorkflowLayoutStore.shared.save(layout(nodeCount: 3), for: child)
        guard case .saved = outcome else {
            XCTAssertEqual(WorkflowLayoutStore.shared.writeGeneration, before,
                           "a write that did not reach disk must not move the generation — got \(outcome)")
            return
        }
        XCTFail("precondition: the seeded blob should have been unreadable, so the save should be refused")
    }
}
