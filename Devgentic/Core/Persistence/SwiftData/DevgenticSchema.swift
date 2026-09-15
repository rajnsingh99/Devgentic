// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DevgenticSchema.swift
//  Devgentic
//
//  Created on 04/08/26.
//
//  The single, referenceable definition of the app's SwiftData entity set.
//
//  WHY THIS FILE EXISTS: this list used to be a `Schema([...])` literal inline in
//  `DevgenticApp.swift`'s `private let swiftDataContainer` closure, which meant no test could
//  reference it. A migration test written against a duplicated list would silently drift from
//  production — and drift is precisely the failure this schema needs guarding against
//  (see SWIFTDATA_GAP_REGISTER.md G54, and G1 for why drift is terminal).
//
//  ⚠️ INVARIANT — read before editing:
//  The on-disk store carries a Core Data model hash derived from entity names, property names,
//  property types, optionality, and the transient/read-only flags. Changing ANY of those for an
//  entity below changes the hash and makes every existing store un-openable unless a migration
//  stage covers it. Swift default VALUES are excluded from the hash and are always safe to add.
//  Full safety table: SWIFTDATA_MIGRATION_PLAN.md.
//
//  ⚠️ Moving an @Model type between files or into a namespace does NOT change its entity name
//  (SwiftData uses the bare type name), so this extraction is hash-neutral. Renaming the TYPE
//  would change it.
//

import Foundation
import SwiftData
import SQLite3
import CryptoKit

/// The app's SwiftData entity set and the container configuration built from it.
///
/// Referenced by `DevgenticApp` at launch and by the migration tests, so that both see the
/// same list by construction rather than by convention.
enum DevgenticSchema {

    /// Every `@Model` type registered in the production store.
    ///
    /// Delegates to the CURRENT schema version so there is exactly one list in the codebase.
    /// ⚠️ **THE SINGLE SYMBOL A NEW SCHEMA VERSION REPOINTS.** Everything else here derives from it,
    /// so there is exactly one edit and no way for the entity list and the opened container to
    /// disagree. Do NOT edit `DevgenticSchemaV1` itself — it is a frozen historical record. Full
    /// procedure in `DevgenticSchemaVersions.swift`.
    ///
    /// This indirection is not decoration. `schema` used to name `DevgenticSchemaV1` directly while
    /// the documented V2 procedure said to repoint `models` — and `models` had **zero** production
    /// readers, so following the procedure verbatim would have left the container on V1: the new
    /// entity never registered (a trap on the first fetch), staged migration never engaged, and
    /// `structuralFingerprint` unchanged, so the launch-sweep gate would have reported `.run` on
    /// precisely the launch a schema change happened. Guarded by
    /// `SchemaMigrationTests.testProductionSchemaTracksTheDeclaredCurrentVersion`.
    static var currentVersion: any VersionedSchema.Type { DevgenticSchemaV6.self }

    /// The entity list of the CURRENT schema version.
    ///
    /// ⚠️ Order is not load-bearing for the model hash, but membership is: omitting an entity
    /// is one of the drifts that makes an existing store un-openable.
    ///
    /// RETIRED 2026-08-04: `CodeViewerSessionSD`. Code Viewer tabs are in-memory only
    /// (`ChatHistoryViewModel.tabsByConversation`); the entity, its cascade relationship on
    /// `ConversationSD`, and the launch purge are all gone. Entity deletion is lightweight-safe —
    /// verified against a real store that CONTAINED a linked row, in
    /// `SchemaMigrationTests.testRetiredCodeViewerEntityDropsWithoutLosingConversations`.
    static var models: [any PersistentModel.Type] { currentVersion.models }

    /// The production `Schema` — what `DevgenticApp` actually opens the container with.
    ///
    /// ⚠️ Built from `currentVersion`, NOT from a named version, so it can never fall behind `models`.
    ///
    /// ⚠️ Building it from the VERSIONED schema is hash-neutral versus the previous `Schema(models)`
    /// form: `Schema.init(_ types:version:)` already defaults `version` to `Schema.Version(1, 0, 0)`,
    /// which is exactly what `DevgenticSchemaV1` declares. Core Data's model checksum derives only
    /// from entity/property names, types, optionality and the transient/read-only flags — never from
    /// the version identifier, and never from Swift default values.
    /// `SchemaMigrationTests.testVersionedSchemaIsHashIdenticalToUnversioned` pins this.
    static var schema: Schema { Schema(versionedSchema: currentVersion) }

    /// The migration plan passed to the container.
    ///
    /// ⚠️ THREE versions and TWO lightweight stages (V1 → V2 → V3) — staged migration is engaged.
    /// This said "one version and ZERO stages" until 2026-08-29, pointing readers at a comment that
    /// repeated the same stale claim.
    static var migrationPlan: any SchemaMigrationPlan.Type { DevgenticMigrationPlan.self }

    /// Filename of the on-disk store, in Application Support.
    ///
    /// ⚠️ The store is FOUR artifacts on disk, not one file: this name, plus `-wal`, `-shm`, and a
    /// hidden `.DevgenticSD_SUPPORT/` sibling holding `@Attribute(.externalStorage)` payloads
    /// (larger than the store itself). Any copy/move/export must handle all four — see
    /// `storeArtifactURLs(for:)`.
    static let storeFilename = "DevgenticSD.store"

    /// Name passed to `ModelConfiguration`. Distinct from the filename by history; kept as-is
    /// because it participates in the configuration identity.
    static let configurationName = "DevgenticSD"

    /// Environment variable that redirects the store away from Application Support.
    ///
    /// ⚠️ DEBUG BUILDS ONLY — deliberately compiled out of release so a shipped app can never be
    /// pointed at a different store by its environment.
    ///
    /// WHY: `TEST_HOST` for `devgenticTests` is `devgentic.app`, so running ANY test launches the
    /// real app, which opens the developer's real store and then runs the destructive launch sweep
    /// against it (G44/G55). Without this override, a migration test cannot run without first
    /// mutating the very data it is meant to protect.
    static let storeURLOverrideEnvKey = "DEVGENTIC_STORE_URL"

    /// Environment variable that suppresses the mutating/deleting launch sweep.
    ///
    /// ⚠️ DEBUG BUILDS ONLY. Set alongside `DEVGENTIC_STORE_URL` by test runs so the app host does
    /// not prune download history, flip workflow-run statuses, or purge Code Viewer sessions in a
    /// store under test.
    static let skipLaunchSweepEnvKey = "DEVGENTIC_SKIP_LAUNCH_SWEEP"

    /// Whether the DEBUG-only environment override is suppressing the launch sweep.
    static var isLaunchSweepSuppressedByEnvironment: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[skipLaunchSweepEnvKey] != nil
        #else
        return false
        #endif
    }

    /// Environment variable that suppresses the modal alert on a fatal container-open failure.
    ///
    /// ⚠️ DEBUG BUILDS ONLY — a shipped app must always tell the user why it is quitting.
    ///
    /// WHY: `NSAlert.runModal()` blocks forever with nobody to click it. Because `TEST_HOST` is
    /// the real app, a developer whose store cannot open would find EVERY test run hanging on an
    /// invisible modal rather than failing. It also makes the failure path itself testable: the
    /// diagnosis is still computed and logged, the process still exits non-zero, only the modal is
    /// skipped.
    static let suppressFatalAlertEnvKey = "DEVGENTIC_SUPPRESS_FATAL_ALERT"

    /// Whether the fatal-failure alert should be presented. Always `true` in release.
    static var shouldPresentFatalAlert: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[suppressFatalAlertEnvKey] == nil
        #else
        return true
        #endif
    }

    /// The Application Support URL of the production store.
    ///
    /// The app is not sandboxed (entitlements carry only `device.audio-input`), so this resolves
    /// to the real `~/Library/Application Support/`, not a container.
    static func defaultStoreURL() throws -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment[storeURLOverrideEnvKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        #endif
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            // Previously a force-unwrap, which could not be caught by the launch path's own
            // do/catch and would trap instead of reaching the diagnostic alert.
            throw DevgenticSchemaError.applicationSupportUnavailable
        }
        return appSupportURL.appendingPathComponent(storeFilename)
    }

    /// Every on-disk artifact belonging to a store at `storeURL`, whether or not it exists.
    ///
    /// Returned in the order a move should apply them: the support directory and sidecars first,
    /// the main store file last, so an interrupted move never leaves a store file without its WAL.
    ///
    /// ⚠️ The `_SUPPORT` directory is named from the store's BASE name, so it is NOT carried along
    /// by renaming the store file. A rename that ignores it leaves the external blobs owned by
    /// whatever store next takes the original name (G29).
    static func storeArtifactURLs(for storeURL: URL) -> (support: URL, wal: URL, shm: URL, store: URL) {
        let directory = storeURL.deletingLastPathComponent()
        let base = storeURL.deletingPathExtension().lastPathComponent
        return (
            support: directory.appendingPathComponent(".\(base)_SUPPORT", isDirectory: true),
            wal: URL(fileURLWithPath: storeURL.path + "-wal"),
            shm: URL(fileURLWithPath: storeURL.path + "-shm"),
            store: storeURL
        )
    }
}

// MARK: - Structural fingerprint

extension DevgenticSchema {

    /// Renders the hash-relevant shape of a schema as a canonical, diffable string.
    ///
    /// Includes exactly what Core Data's model version hash derives from — entity name, and per
    /// property its name, original name, value type, optionality, and the transient/unique flags —
    /// plus attribute options, relationship edges, uniqueness constraints and indices. Sorted
    /// throughout so the output is stable across runs (SwiftData exposes attributes and
    /// relationships as unordered `Set`s).
    ///
    /// Lives in production rather than in the tests because BOTH the drift test and the launch-sweep
    /// gate key off it, and two copies would drift from each other — the same failure that put the
    /// entity list here in the first place.
    static func structuralDescriptor(for schema: Schema) -> String {
        schema.entities
            .sorted { $0.name < $1.name }
            .map { entity in
                var lines = ["ENTITY \(entity.name)"]

                lines += entity.properties
                    .map { property in
                        // ⚠️ Classify by concrete type, NOT by `property.isRelationship` — that
                        // protocol witness reports false for relationships reached through
                        // `entity.properties`, which silently labelled every relationship "ATTR".
                        let relationship = property as? Schema.Relationship
                        let kind = relationship == nil ? "ATTR" : "REL "
                        let flags = [
                            property.isOptional ? "optional" : "required",
                            property.isTransient ? "transient" : nil,
                            property.isUnique ? "unique" : nil,
                        ].compactMap { $0 }.joined(separator: ",")
                        // originalName is "" unless @Attribute(originalName:) was used. Render it
                        // only when actually set AND different — it is the supported rename path
                        // and therefore hash-relevant.
                        let original = property.originalName.isEmpty || property.originalName == property.name
                            ? ""
                            : " originalName=\(property.originalName)"
                        // Attribute options are not on the SchemaProperty protocol, but
                        // `.externalStorage` moves the payload out of the store into the _SUPPORT
                        // sidecar, and the transformable marking on a collection attribute is chosen
                        // by the OS and has changed between releases — both worth surfacing.
                        let options = (property as? Schema.Attribute)
                            .map { $0.options.map(String.init(describing:)).sorted() } ?? []
                        let renderedOptions = options.isEmpty ? "" : " options=\(options.joined(separator: ","))"
                        // Delete rule and inverse are behavioural, not hash-relevant, but a silently
                        // changed cascade deletes user rows and a missing inverse is a known wart.
                        let edge = relationship.map {
                            " -> \($0.destination) delete=\($0.deleteRule) inverse=\($0.inverseName ?? "none")"
                        } ?? ""
                        return "  \(kind) \(property.name): \(property.valueType) [\(flags)]\(original)\(renderedOptions)\(edge)"
                    }
                    .sorted()

                // Column ORDER within a constraint or index is significant (a compound index on
                // (a, b) is not the index on (b, a)), so only the outer list is sorted.
                for constraint in entity.uniquenessConstraints.map({ $0.joined(separator: "+") }).sorted() {
                    lines.append("  UNIQUE (\(constraint))")
                }
                for index in entity.indices.map({ $0.joined(separator: "+") }).sorted() {
                    lines.append("  INDEX (\(index))")
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
    }

    /// A stable, persistable fingerprint of the current schema's shape.
    ///
    /// ⚠️ SHA-256 of the descriptor, NOT `Schema.hashValue`. Swift seeds `Hashable` per process, so
    /// `hashValue` differs on every launch and would make the gate below fire every single time —
    /// permanently disabling retention while looking like it worked.
    static var structuralFingerprint: String {
        let digest = SHA256.hash(data: Data(structuralDescriptor(for: schema).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Uniqueness pre-flight

extension DevgenticSchema {

    /// Duplicate values found on a column, keyed by `entity.attribute`.
    struct DuplicateReport {
        /// `["PromptModel.title": 3]` — the column and how many values appear more than once.
        let offendingColumns: [String: Int]
        var isClean: Bool { offendingColumns.isEmpty }

        var summary: String {
            isClean
            ? "No duplicates on any candidate column."
            : offendingColumns
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value) duplicated value(s)" }
                .joined(separator: "; ")
        }
    }

    /// Scans a store for duplicate values on columns you are ABOUT to constrain with
    /// `@Attribute(.unique)`.
    ///
    /// ⚠️ WHY THIS EXISTS (G9). Adding `.unique` to an existing column is not a lightweight-safe
    /// change: if any two rows already share a value the migration fails on the constraint violation
    /// and the container will not open — for a user whose data was fine a moment earlier, with the
    /// opaque `SwiftDataError` code 1 that `StoreOpenDiagnostics` exists to decode. The app has 12
    /// `.unique` constraints and had NO way to answer "would adding a 13th brick anyone?" before
    /// shipping it.
    ///
    /// Deliberately raw SQL rather than SwiftData: the whole point is to inspect a store as it is
    /// TODAY, under the schema that wrote it, without opening it under a schema that already
    /// declares the constraint you are testing for.
    ///
    /// - Parameter columns: `("ZPROMPTMODEL", "ZTITLE")` pairs — Core Data's mangled table/column
    ///   names, which is what a `.store` actually contains.
    static func duplicateReport(
        storeURL: URL,
        columns: [(table: String, column: String)]
    ) -> DuplicateReport {
        var offending: [String: Int] = [:]
        for (table, column) in columns {
            guard let count = sqliteDuplicateCount(storeURL: storeURL, table: table, column: column),
                  count > 0 else { continue }
            offending["\(table).\(column)"] = count
        }
        return DuplicateReport(offendingColumns: offending)
    }

    private static let preflightLogger = DGLogger(category: "DevgenticSchema")

    /// Count of values appearing more than once in `column`, or nil if the query could not run.
    ///
    /// Opens the store READ-ONLY so a pre-flight can never modify the thing it is inspecting.
    /// Two connection modes, in order:
    ///
    /// 1. A plain read-only connection. This attaches to the store's WAL, so rows that are
    ///    committed but not yet checkpointed into the main file ARE counted — the state of any
    ///    store that is currently open elsewhere (the running app, a live `ModelContainer`) or
    ///    was copied with a hot `-wal`. SQLite builds a private in-memory WAL index when it
    ///    cannot write the `-shm`, so this works without write access to the sidecars.
    /// 2. `immutable=1`, only if the plain connection could not produce an answer (read-only
    ///    media, missing sidecar permissions). ⚠️ This mode is WAL-BLIND: it reads the main file
    ///    only, so committed rows still sitting in the `-wal` are invisible to it. It used to be
    ///    the ONLY mode, which made the pre-flight report a just-written store as duplicate-free
    ///    whenever the writing connection had not yet closed and checkpointed — a false "clean"
    ///    from the one tool whose job is to say "this constraint would brick user data"
    ///    (caught by `testDuplicateReportSeesRowsWhileTheWritingContainerIsStillOpen`).
    private static func sqliteDuplicateCount(storeURL: URL, table: String, column: String) -> Int? {
        // Identifiers cannot be bound as parameters, so they are validated instead — these come from
        // developer-supplied schema names, but a typo that happened to contain SQL should fail
        // loudly here rather than execute.
        let identifier = /^[A-Za-z_][A-Za-z0-9_]*$/
        guard table.wholeMatch(of: identifier) != nil,
              column.wholeMatch(of: identifier) != nil else {
            preflightLogger.error(
                "[PREFLIGHT] Duplicate scan REFUSED non-identifier name \(table).\(column) — "
                + "identifiers are interpolated into SQL and anything else must not execute. "
                + "CONSEQUENCE: the column is absent from the report; fix the name, or the "
                + "pre-flight has not vouched for it."
            )
            return nil
        }

        let sql = """
            SELECT COUNT(*) FROM (
              SELECT \(column) FROM \(table)
              WHERE \(column) IS NOT NULL
              GROUP BY \(column) HAVING COUNT(*) > 1
            )
            """

        for uri in ["file:\(storeURL.path)", "file:\(storeURL.path)?immutable=1"] {
            if let count = sqliteScalar(uri: uri, sql: sql) { return count }
        }
        preflightLogger.error(
            "[PREFLIGHT] Duplicate scan could not evaluate \(table).\(column) at \(storeURL.path) — "
            + "the store could not be opened read-only, or the query failed, on both connection "
            + "modes (plain and immutable=1). A missing store or a table this schema never wrote "
            + "also lands here. CONSEQUENCE: the column is treated as duplicate-free in the "
            + "report; a .unique constraint on it could still brick existing stores."
        )
        return nil
    }

    /// Runs a single-scalar read-only query against `uri`, or nil if it could not run there.
    private static func sqliteScalar(uri: String, sql: String) -> Int? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }
}

// MARK: - Launch-sweep gate

/// Whether the destructive launch-time sweep may run.
enum LaunchSweepDecision: Equatable {
    /// The schema is unchanged since the last successful open.
    case run
    /// The schema changed (or has never been recorded). Reads only this launch.
    case deferSchemaChanged(previous: String?, current: String)
    /// DEBUG-only environment override.
    case skippedByEnvironment
}

extension DevgenticSchema {

    /// UserDefaults key holding the fingerprint of the schema that last opened the store cleanly.
    static let lastOpenedFingerprintKey = "devgentic.persistence.lastOpenedSchemaFingerprint"

    /// Decides whether the destructive launch sweep may run this launch.
    ///
    /// ⚠️ WHY THIS GATE EXISTS: the sweep prunes download history, flips workflow-run statuses and
    /// previously deleted a whole entity's rows — all unconditionally, the instant the container
    /// opened. A lightweight migration can succeed STRUCTURALLY while defaulting a new non-optional
    /// or dropping a renamed column's data, so on the first launch after a schema change those
    /// sweeps would write a degraded store back as authoritative before the user could look at it.
    ///
    /// On the first launch after any schema change the sweep is deferred to the NEXT launch. The
    /// cost is one launch of skipped retention; the benefit is that a bad migration is observable
    /// and recoverable rather than compounded.
    ///
    /// A nil stored fingerprint also defers. It means either a brand-new install (where the store is
    /// empty and the sweep is a no-op anyway) or the first launch of the build that introduced this
    /// gate (which may well be a migration) — and the two cannot be told apart, so take the safe one.
    /// - Parameter suppressedByEnvironment: injectable so the gate's own tests can exercise the
    ///   fingerprint logic. The test host runs with `DEVGENTIC_SKIP_LAUNCH_SWEEP` set (it must —
    ///   `TEST_HOST` is the real app), which would otherwise short-circuit every one of them to
    ///   `.skippedByEnvironment` and make them assert nothing.
    static func evaluateLaunchSweep(
        defaults: UserDefaults = .standard,
        suppressedByEnvironment: Bool = isLaunchSweepSuppressedByEnvironment
    ) -> LaunchSweepDecision {
        if suppressedByEnvironment { return .skippedByEnvironment }

        let current = structuralFingerprint
        let previous = defaults.string(forKey: lastOpenedFingerprintKey)
        guard previous == current else {
            return .deferSchemaChanged(previous: previous, current: current)
        }
        return .run
    }

    /// Records the current schema as the last one that opened the store cleanly.
    ///
    /// Called after a successful open regardless of the decision, so a deferral lasts exactly one
    /// launch instead of becoming permanent.
    static func recordSuccessfulOpen(defaults: UserDefaults = .standard) {
        defaults.set(structuralFingerprint, forKey: lastOpenedFingerprintKey)
    }
}

/// Failures raised while resolving the store location, before SwiftData is involved.
enum DevgenticSchemaError: LocalizedError {
    case applicationSupportUnavailable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The Application Support directory could not be located."
        }
    }
}
