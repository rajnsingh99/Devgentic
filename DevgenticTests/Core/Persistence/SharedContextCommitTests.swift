// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SharedContextCommitTests.swift
//  DevgenticTests
//
//  RAG-27 (CR-69) — CHARACTERISATION of SwiftData's behaviour after a FAILED save (macOS 26),
//  proven 2026-10-12. Every store shares `container.mainContext`, and the register's prescribed
//  fix was "roll back on failure". These pin why that cannot work:
//
//    • After a failed save, `rollback()` does NOT remove a failed insert. It stays in the context
//      and fails EVERY later save, while `pendingChangeCount` reads 0 (SwiftData has disowned it;
//      the underlying context has not). Deleting it, rolling back twice, or repairing it after the
//      rollback does not help either.
//    • A changed value is NOT restored by that rollback.
//    • A FRESH `ModelContext` on the same container saves normally while `mainContext` is
//      poisoned — the poison lives in one context, not in the store.
//
//  If a future SDK makes `testRollbackAfterAFailedSaveDoesNotClearThePoison` fail, SwiftData's
//  rollback started working: revisit the recovery design in the register (RAG-27).
//
//  A save is made to fail for real with `PoisonParentSD`, whose relationship demands at least one
//  child: inserted with none, it fails Core Data validation on every save of its context.
//

import XCTest
import SwiftData
@testable import devgentic

@Model final class PoisonChildSD {
    var n: Int
    init(n: Int) { self.n = n }
}

/// Fails validation while it has no children — on every save of the context it was inserted into.
@Model final class PoisonParentSD {
    var name: String
    @Relationship(deleteRule: .cascade, minimumModelCount: 1) var children: [PoisonChildSD] = []
    init(name: String) { self.name = name }
}

@MainActor
final class SharedContextCommitTests: XCTestCase {

    /// Held: a `ModelContext` whose container has been released traps on first use.
    private var container: ModelContainer?

    override func tearDown() async throws { container = nil }

    private func mainContext() throws -> ModelContext {
        let made = try ModelContainer(for: PoisonParentSD.self, PoisonChildSD.self,
                                      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        container = made
        return made.mainContext
    }

    private func pending(_ context: ModelContext) -> Int {
        context.insertedModelsArray.count + context.changedModelsArray.count + context.deletedModelsArray.count
    }

    func testThePoisonFailsEverySave() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.insert(PoisonChildSD(n: 1))
        XCTAssertThrowsError(try context.save(), "an unrelated write must fail with it — that is the poisoning")
    }

    /// ⚠️⚠️ The platform fact the RAG-27 design rests on.
    func testRollbackAfterAFailedSaveDoesNotClearThePoison() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.rollback()
        XCTAssertEqual(pending(context), 0, "SwiftData reports nothing pending after the rollback…")

        context.insert(PoisonChildSD(n: 1))
        XCTAssertThrowsError(try context.save(), "…yet the poison still fails the next save. If this now SUCCEEDS, rollback works on this SDK — revisit RAG-27.")
    }

    func testRollbackAfterAFailedSaveDoesNotRestoreAChangedValue() throws {
        let context = try mainContext()
        let kept = PoisonChildSD(n: 1)
        context.insert(kept)
        try context.save()

        kept.n = 99
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())
        context.rollback()
        XCTAssertEqual(kept.n, 99, "rollback restored the value — SwiftData's rollback works on this SDK; revisit RAG-27")
    }

    /// Recovery exists — in a context the poison never entered.
    func testAFreshContextSavesWhileTheMainContextIsPoisoned() throws {
        let context = try mainContext()
        context.insert(PoisonParentSD(name: "poison"))
        XCTAssertThrowsError(try context.save())

        let fresh = ModelContext(try XCTUnwrap(container))
        fresh.insert(PoisonChildSD(n: 3))
        XCTAssertNoThrow(try fresh.save())
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PoisonChildSD>()), 1, "the main context sees the fresh context's row")
    }
}
