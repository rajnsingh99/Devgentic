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
//  no in-app recovery. Declaring V1 now — while it costs nothing — gives every future change a
//  named source version to stage from.
//
//  ⚠️ THIS FILE IS A HISTORICAL RECORD. Each `VersionedSchema` below describes the shape of a
//  schema that was ONCE CURRENT. Once a version has shipped, its `models` list is frozen forever:
//  editing it retroactively rewrites history and breaks migration from stores that carry it.
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
//  6. Add a `SchemaBaselineV2` recording the new shape and point the drift test at it. ⚠️ Do NOT
//     edit `SchemaBaselineV1` — it records what V1 shipped, and that file's own header says so.
//     Editing it to make the build green erases the record the drift guard exists to keep.
//  7. Update the assertions that hardcode V1 facts — `testProductionSchemaRegistersExactlyTheExpectedEntities`
//     (entity set + count) and `testSchemaBuiltFromModelsIsStable` (version) — and confirm the
//     fixture-store test still opens a pre-change store.
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
/// ⚠️ `versionIdentifier` MUST remain `Schema.Version(1, 0, 0)`. That is the value SwiftData
/// already recorded implicitly for every store written by the previous unversioned
/// `Schema([types])` (its `version` parameter defaults to exactly this), which is what makes
/// introducing versioning hash-neutral rather than a migration event. Changing it to 1.0.1 or
/// 2.0.0 would orphan every existing store.
///
/// ⚠️ The model types are referenced at their top level rather than nested inside this enum.
/// Nesting is only required when two versions of the SAME model type must coexist in one build;
/// with a single version it would be pure churn. Entity names are unaffected either way — SwiftData
/// derives them from the bare type name, not the enclosing scope.
enum DevgenticSchemaV1: VersionedSchema {

    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    /// The 12 entities as of 2026-08-04.
    ///
    /// ⚠️ FROZEN once a build ships. `CodeViewerSessionSD` was deliberately retired BEFORE this
    /// version was declared so that V1 would not canonize a tombstone and force the very next
    /// release to be an entity-deletion migration.
    static var models: [any PersistentModel.Type] {
        [
            BackendProfile.self,
            MCPToolItem.self,
            MCPToolDefinitionModel.self,
            PromptModel.self,
            ScheduledTaskModel.self,
            // Chat persistence (migrated from CoreData)
            ConversationSD.self,
            ChatMessageSD.self,
            AttachedTextFileSD.self,
            AttachedImageFileSD.self,
            // Cross-launch download history (Ollama / MLX / Whisper)
            DownloadRecord.self,
            // Workflow persistence (migrated from UserDefaults)
            WorkflowLayoutSD.self,
            WorkflowRunRecordSD.self,
        ]
    }
}

// MARK: - Migration plan

/// The store's migration plan.
///
/// ⚠️ `stages` is EMPTY, and that is correct — not an omission. `MigrationStage` has exactly two
/// cases, `.lightweight(fromVersion:toVersion:)` and `.custom(...)`, and both require a FROM and a
/// TO version. With one declared version there is no stage to express. The planning doc's original
/// instruction to "pass a SchemaMigrationPlan with a single stage" is not expressible; following it
/// literally by inventing a fictitious V2 is what produces `NSCocoaErrorDomain 134504`
/// ("Cannot use staged migration with an unknown model version") on every existing store.
///
/// With `schemas: [V1]` and no stages, SwiftData never engages staged migration, so this behaves
/// identically to `migrationPlan: nil` today. Its value is that the scaffolding — and the frozen
/// V1 record — are in place before the first change that needs them.
enum DevgenticMigrationPlan: SchemaMigrationPlan {

    /// ⚠️ ASCENDING version order is load-bearing. See the V2 procedure in this file's header.
    static var schemas: [any VersionedSchema.Type] {
        [DevgenticSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
