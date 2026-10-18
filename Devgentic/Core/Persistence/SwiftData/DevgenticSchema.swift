// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DevgenticSchema.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import SQLite3
import CryptoKit

/// The app's SwiftData entity set and the container configuration built from it.
/// Shared by `DevgenticApp` at launch and the migration tests so both see the same list.
enum DevgenticSchema {

    // Why: everything else derives from it, so the entity list and the opened container cannot disagree
    /// Every `@Model` type registered in the production store, taken from the current schema version.
    /// Repoint this single symbol for a new schema version; a shipped version's `models` is a frozen record.
    static var currentVersion: any VersionedSchema.Type { DevgenticSchemaV1.self }

    /// The entity list of the current schema version.
    /// Order does not affect the model hash, but membership does: omitting an entity makes an existing store un-openable.
    static var models: [any PersistentModel.Type] { currentVersion.models }

    // Why: the versioned form is hash-neutral: Core Data's checksum ignores the version identifier and Swift defaults
    /// The production `Schema` that `DevgenticApp` opens the container with.
    /// Built from `currentVersion`, not a named version, so it cannot fall behind `models`.
    static var schema: Schema { Schema(versionedSchema: currentVersion) }

    /// The migration plan passed to the container.
    /// One version and no stages, so staged migration is not engaged until a second version is added.
    static var migrationPlan: any SchemaMigrationPlan.Type { DevgenticMigrationPlan.self }

    /// Filename of the on-disk store, in Application Support.
    /// The store is four artifacts: this file, `-wal`, `-shm` and a `.DevgenticSD_SUPPORT/` directory;
    /// see `storeArtifactURLs(for:)`.
    static let storeFilename = "DevgenticSD.store"

    /// Name passed to `ModelConfiguration`. Distinct from the filename by history; kept as-is
    /// because it participates in the configuration identity.
    static let configurationName = "DevgenticSD"

    // Why: tests launch the real app host, which would otherwise open and sweep the developer's real store
    /// Environment variable that redirects the store away from Application Support. Debug builds only.
    static let storeURLOverrideEnvKey = "DEVGENTIC_STORE_URL"

    /// Environment variable that suppresses the mutating launch sweep. Debug builds only.
    /// Set with `DEVGENTIC_STORE_URL` by test runs so the app host does not prune or flip a store under test.
    static let skipLaunchSweepEnvKey = "DEVGENTIC_SKIP_LAUNCH_SWEEP"

    /// Whether the DEBUG-only environment override is suppressing the launch sweep.
    static var isLaunchSweepSuppressedByEnvironment: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment[skipLaunchSweepEnvKey] != nil
        #else
        return false
        #endif
    }

    // Why: `NSAlert.runModal()` blocks forever with nobody to click it, hanging every test run
    /// Environment variable that suppresses the modal alert on a fatal container-open failure. Debug builds only.
    /// The failure is still diagnosed and logged and the process still exits non-zero; only the modal is skipped.
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
    /// The app is not sandboxed, so this is the real `~/Library/Application Support/`.
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

    // Why: the `_SUPPORT` directory is named from the base name, so renaming the store file does not carry it along
    /// Every on-disk artifact of the store at `storeURL`, whether or not it exists, in the order a move should apply them.
    /// The main store file comes last so an interrupted move never leaves a store without its WAL.
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

    /// Renders the hash-relevant shape of a schema as a canonical, diffable string, sorted for stable output.
    /// Covers entities, properties, options, relationships, constraints and indices.
    static func structuralDescriptor(for schema: Schema) -> String {
        schema.entities
            .sorted { $0.name < $1.name }
            .map { entity in
                var lines = ["ENTITY \(entity.name)"]

                lines += entity.properties
                    .map { property in
                        // Why: that protocol witness reports false for relationships reached through `entity.properties`
                        // Classifies by concrete type, not `property.isRelationship`.
                        let relationship = property as? Schema.Relationship
                        let kind = relationship == nil ? "ATTR" : "REL "
                        let flags = [
                            property.isOptional ? "optional" : "required",
                            property.isTransient ? "transient" : nil,
                            property.isUnique ? "unique" : nil,
                        ].compactMap { $0 }.joined(separator: ",")
                        // `originalName` is rendered only when set and different; it is the supported rename path and hash-relevant.
                        let original = property.originalName.isEmpty || property.originalName == property.name
                            ? ""
                            : " originalName=\(property.originalName)"
                        // Attribute options are surfaced because `.externalStorage` moves the payload to the sidecar,
                        // and the OS-chosen transformable marking on collections has changed between releases.
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

    // Why: `Schema.hashValue` is seeded per process, so it would differ every launch and fire the gate every time
    /// A stable, persistable fingerprint of the current schema's shape: the SHA-256 of the descriptor.
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

    // Why: adding `.unique` over duplicate rows fails the migration and leaves the container unopenable
    /// Scans a store for duplicate values on columns you are about to constrain with `@Attribute(.unique)`.
    /// Raw SQL, so the store is inspected under the schema that wrote it. columns: Core Data table/column name pairs.
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

    // Why: `immutable=1` is WAL-blind and misses committed rows still in the `-wal`, falsely reporting clean
    /// Count of values appearing more than once in `column`, or nil if the query could not run.
    /// Opens read-only: first a plain connection that sees WAL rows, then `immutable=1` as a fallback.
    private static func sqliteDuplicateCount(storeURL: URL, table: String, column: String) -> Int? {
        // Identifiers cannot be bound as parameters, so they are validated against a strict pattern and fail loudly.
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

    // Why: a lightweight migration can succeed structurally while degrading data, which the sweep would make authoritative
    /// Decides whether the destructive launch sweep may run; it is deferred after any schema change or a nil fingerprint.
    /// suppressedByEnvironment is injectable so the gate's own tests exercise the fingerprint logic.
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
    /// Called after a successful open regardless of the decision, so a deferral lasts exactly one launch.
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
