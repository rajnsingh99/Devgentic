// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DevgenticSchemaVersions.swift
//  Devgentic
//
//  Created on 04/08/26.
//
//  Versioned schema history and the migration plan.
//
//  WHY THIS EXISTS: the app previously opened its store with a bare `Schema([...])` and no
//  migration plan, so SwiftData had no recorded version to migrate FROM. The first schema change
//  it could not infer would have made the app refuse to launch, with the store left untouched and
//  no in-app recovery. Declaring V1 — while it costs nothing — gives every future change a named
//  source version to stage from.
//
//  ⚠️⚠️ HISTORY WAS RESET ON 2026-09-23, BEFORE ANY BUILD REACHED ANYONE. The development history
//  (V1 → V2 → V3 → V6, with frozen nested copies at every step and two further versions deleted
//  along the way) served only stores on the developer's own machine. It was collapsed into the V1
//  below — today's shape — at the developer's decision, with every existing store deleted. The
//  MACHINERY was kept deliberately: the versioned schema, the plan, the baseline drift test. It is
//  what makes the first post-release change a migration instead of a launch failure, and it cannot
//  be added after the fact.
//
//  ⚠️ STILL PRE-RELEASE, V1 HAS BEEN EDITED IN PLACE ONCE SINCE: 2026-09-24 added the OPTIONAL
//  `ConversationSD.projectPath`. Allowed only because nobody else holds a store; proven safe for
//  the developer's store by `testAllEntitiesFixtureOpensUnderCurrentSchema`, which opens a V1 store
//  written before the field through the production plan. After the first release, a change like
//  this is a V2.
//  A second in-place edit on 2026-09-27 (owner decision): the OPTIONAL
//  `ScheduledTaskModel.runLimitSeconds` (a per-task execution limit, HITL Waiting Contract §5).
//  Proven the same way — the same fixture's scheduled task must open and read it as nil.
//
//  ⚠️ THIS FILE IS A HISTORICAL RECORD FROM THE FIRST RELEASE ON. Each `VersionedSchema` below
//  describes the shape of a schema that was ONCE CURRENT. Once a version has shipped, its `models`
//  list is frozen forever: editing it retroactively rewrites history and breaks migration from
//  stores that carry it. A reset like the one above is possible exactly once — before anyone else
//  holds a store.
//
//  ── Adding a V2 (the whole procedure) ──────────────────────────────────────────────────────
//  1. Leave `DevgenticSchemaV1` EXACTLY as it is.
//  2. Add `enum DevgenticSchemaV2: VersionedSchema` with `versionIdentifier = Version(2, 0, 0)`
//     and the new model list.
//  3. Point `DevgenticSchema.currentVersion` at `DevgenticSchemaV2.self` — ⚠️ THAT ONE SYMBOL, and
//     nothing else. `models` and `schema` both derive from it, so they cannot disagree. (This step
//     used to say "point `DevgenticSchema.models` at `DevgenticSchemaV2.models`", which was a trap:
//     `schema` named V1 directly and `models` had no production readers, so following it verbatim
//     left the container on V1 with the new entity unregistered and the sweep gate unarmed.)
//  4. Append V2 to `DevgenticMigrationPlan.schemas` — ⚠️ ASCENDING ORDER IS LOAD-BEARING. A
//     descending array fails deterministically with `SwiftDataError.backwardMigration`, and Apple
//     documents no such requirement.
//  5. Add the stage: `.lightweight(fromVersion: V1.self, toVersion: V2.self)` if the change is in
//     the safe set (see the table in SWIFTDATA_MIGRATION_PLAN.md), otherwise `.custom(...)`.
//     ⚠️ `willMigrate`/`didMigrate` do NOT run for `.lightweight` stages — verified. Do not attach
//     logic to one and expect it to execute.
//  5b. ⚠️ NEST FROZEN COPIES — learned the hard way on the first real V2 (2026-08-22). The old
//     version's `models` may NOT keep referencing an evolved shared class: both versions then hash
//     identically and EVERY container open crashes with NSInvalidArgumentException "Duplicate
//     version checksums detected". The old version needs its own frozen copies of the changed
//     entity's whole RELATIONSHIP CLOSURE (a shared neighbor pulls the evolved entity back in and
//     collides on the entity name); entities outside the closure stay shared.
//     ⚠️⚠️ CHECK EVERY OLDER VERSION, NOT ONLY THE PREVIOUS ONE — learned again 2026-09-23: a
//     change meant for the newest version also rewrote two older ones that listed the same live
//     class, and every store stamped at them stopped opening. Grep each `models` list for the class.
//     `testV1RendersExactlyTheV1Baseline` already guards V1; give each new version the same test
//     the day it is FROZEN (i.e. when the next one is added), and verify per-entity hash parity
//     against a real pre-change store — descriptor parity has proven sufficient, but the hash is
//     the contract.
//  6. Add a `SchemaBaselineV2` recording the new shape and point the drift test at it. ⚠️ Do NOT
//     edit `SchemaBaselineV1` — it records what V1 shipped, and that file's own header says so.
//     Editing it to make the build green erases the record the drift guard exists to keep.
//  7. Update the assertions that hardcode V1 facts — `testProductionSchemaRegistersExactlyTheExpectedEntities`
//     (entity set + count) and `testSchemaBuiltFromModelsIsStable` (version).
//  8. ⚠️ BEFORE regenerating `devgentic-all-entities-fixture.store`, copy it aside as the
//     previous-version fixture and add a test that it opens under the new plan. Once regenerated
//     it is a CURRENT-shape store and can no longer prove the migration works.
//
//  ⚠️ A RENAME chain must always cite the ORIGINAL SHIPPED name in `@Attribute(originalName:)`,
//  never the previous one. `a→b` then `b→c` needs `originalName: "a"` on `c`, not `"b"`: the
//  migration runs V1→VN directly (see the chain note below), so intermediate names never existed
//  as far as the store is concerned. Apple documents neither the rule nor the failure.
//
//  ⚠️ A chain of all-lightweight stages SKIPS intermediates and attempts a direct V1→VN migration,
//  so an intermediate stage cannot be relied upon to run.
//
//  ⚠️ DEPLOYMENT TARGET IS LOAD-BEARING HERE — do not lower `MACOSX_DEPLOYMENT_TARGET` below 26.1.
//  Apple changed how SwiftData persists COLLECTION attributes between macOS 26.0 and 26.1: they
//  moved from Binary Data to Transformable / `NSSecureUnarchiveFromData`. A store written under
//  26.0 then opened under 26.1+ fails with `NSCocoaErrorDomain 134140` ("missing mapping model")
//  — with no developer change of any kind, so no amount of VersionedSchema discipline prevents it.
//  `PromptModel.tags: [String]?` is this app's only non-relationship collection attribute and is
//  exactly that shape. Raising the floor to 26.1 means no store can ever be written under the old
//  encoding, which closes the exposure at the source. Decided 2026-08-04; the alternative
//  (moving `tags` to a hand-rolled blob) was rejected as more churn for the same outcome.
//  `SchemaBaselineV1` records the current storage marking, so if Apple ever changes it again the
//  drift test fails rather than a user's launch.
//

import Foundation
import SwiftData

// MARK: - V1 (current)

/// The first declared schema version — the shape the first shipped build will carry.
///
/// ⚠️ Every model is listed by its LIVE top-level class. That is correct for exactly as long as V1
/// is the only version. The moment a V2 evolves any of these classes, V1 must get frozen nested
/// copies of the changed entity's relationship closure (rule 5b in the header) — otherwise V1
/// silently renders V2's shape, and every store stamped V1 stops opening. That exact failure
/// happened on 2026-09-23, to V2 and V3, and is why the header's rule is marked as learned.
///
/// ⚠️ `versionIdentifier` stays `Schema.Version(1, 0, 0)` — the value `Schema(_:)` defaults to, so
/// the versioned and unversioned forms of this list are hash-identical
/// (`SchemaMigrationTests.testVersionedSchemaIsHashIdenticalToUnversioned`).
enum DevgenticSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// The 15 entities as of 2026-09-23.
    static var models: [any PersistentModel.Type] {
        [
            BackendProfile.self,
            MCPToolItem.self,
            MCPToolDefinitionModel.self,
            PromptModel.self,
            ScheduledTaskModel.self,
            ConversationSD.self,
            ChatMessageSD.self,
            AttachedTextFileSD.self,
            AttachedImageFileSD.self,
            DownloadRecord.self,
            WorkflowLayoutSD.self,
            WorkflowRunRecordSD.self,
            SkillSD.self,
            SkillVersionSD.self,
            SkillFileSD.self,
        ]
    }
}

// MARK: - Migration plan

/// The store's migration plan: ONE version, ZERO stages.
///
/// ⚠️ With zero stages SwiftData does not engage staged migration. A store whose shape differs from
/// V1 is left to Core Data's automatic lightweight inference — it may open (inferred) or fail —
/// rather than being refused as an unknown version. That changes the moment a second version and
/// a stage are added: from then on, a store matching NO declared version fails with
/// `NSCocoaErrorDomain 134504` ("Cannot use staged migration with an unknown model version").
///
/// ⚠️ Versions are only ever ADDED: `MigrationStage` requires a FROM and a TO, so a stage cannot be
/// expressed against a version that does not exist. Inventing a fictitious version to have
/// something to stage from is what produces 134504 on every existing store.
enum DevgenticMigrationPlan: SchemaMigrationPlan {

    /// ⚠️ ASCENDING version order is load-bearing. See the V2 procedure in this file's header.
    static var schemas: [any VersionedSchema.Type] {
        [DevgenticSchemaV1.self]
    }

    /// Empty until V2. ⚠️ `willMigrate`/`didMigrate` do NOT run for `.lightweight` stages — see the
    /// header before attaching logic to one.
    static var stages: [MigrationStage] {
        []
    }
}
