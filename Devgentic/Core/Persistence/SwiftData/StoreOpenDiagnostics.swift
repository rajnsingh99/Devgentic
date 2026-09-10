// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  StoreOpenDiagnostics.swift
//  Devgentic
//
//  Created on 04/08/26.
//
//  Turns an opaque container-open failure into something a human can act on.
//
//  THE PROBLEM (SWIFTDATA_GAP_REGISTER.md G39/G40, both verified by probe):
//  Every structurally distinct container-open failure — a non-optional attribute with no default,
//  a `.unique` constraint violated by existing rows, a corrupt file, an unwritable path — reaches
//  the app as the SAME value: `SwiftDataError(_error: .loadIssueModelContainer)`, NSError domain
//  `SwiftData.SwiftDataError` code `1`, with **empty `userInfo` and empty `underlyingErrors`**.
//  Pattern-matching `.unknownSchema` / `.modelValidationFailure` / `.backwardMigration`
//  discriminates nothing, because everything matches `.loadIssueModelContainer`.
//
//  Worse: the diagnostic that WOULD identify the cause —
//      {entity=PromptModel, attribute=driftProbe,
//       reason=Validation error missing attribute values on mandatory destination attribute}
//  — is written by Core Data to **stderr**, not to the unified log. Confirmed absent from
//  `log show` under every subsystem. For a Finder-launched `.app` stderr is discarded, so the one
//  piece of information that identifies the bug is unrecoverable after the fact.
//
//  So the user sends "The operation couldn't be completed. (SwiftData.SwiftDataError error 1.)"
//  and nothing else — which violates the standing rule that the app must be field-debuggable from
//  logs alone.
//
//  THE FIX — two complementary side channels, since error introspection cannot work:
//   1. `classify(...)` reads the store's own metadata with Core Data's raw API, which DOES return
//      real errors and real `NSStoreModelVersionHashes`. That yields entity-level diagnosis
//      (which entities were added/removed) plus "is this even a store".
//   2. `captureStandardError(during:)` redirects stderr to a temp FILE across a deliberate second
//      open attempt, recovering the attribute-level reason Core Data only prints there.
//
//  They are complementary: (1) names the entities, (2) names the attribute.
//

import Foundation
import CoreData
import SwiftData

// MARK: - Diagnosis

/// What actually went wrong when the container refused to open.
enum StoreOpenDiagnosis: Equatable {

    /// No file at the store URL. Normal on a genuinely first launch; suspicious otherwise.
    case storeMissing

    /// The containing directory cannot be written, so Core Data cannot create or migrate a store.
    case pathNotWritable(directory: String)

    /// The file exists but Core Data cannot even read its metadata — corrupt, truncated, or not a
    /// store at all. Carries the REAL underlying error, which the SwiftData wrapper discards.
    case unreadableAsStore(domain: String, code: Int, reason: String)

    /// The store is readable and its entity set differs from the current schema.
    case entitySetChanged(addedInCode: [String], missingFromCode: [String])

    /// The store is readable and its entity set matches, so the incompatibility is INSIDE an
    /// entity — an attribute added/renamed/retyped. Only stderr names which one.
    case entityShapeChanged

    /// Metadata read fine and nothing above applies.
    case indeterminate

    /// One-line summary for logs and the alert body.
    var summary: String {
        switch self {
        case .storeMissing:
            return "No store file exists at the expected path."
        case .pathNotWritable(let directory):
            return "The folder holding the database is not writable: \(directory)"
        case .unreadableAsStore(let domain, let code, let reason):
            return "The database file could not be read (\(domain) \(code)): \(reason)"
        case .entitySetChanged(let added, let missing):
            var parts: [String] = []
            if !added.isEmpty { parts.append("added in this build: \(added.joined(separator: ", "))") }
            if !missing.isEmpty { parts.append("present in the database but not in this build: \(missing.joined(separator: ", "))") }
            return "The set of stored types changed — \(parts.joined(separator: "; "))."
        case .entityShapeChanged:
            return "A stored type changed shape (a property was added, renamed or retyped)."
        case .indeterminate:
            return "The database could not be opened and the cause could not be narrowed down."
        }
    }

    /// Short machine-ish tag for log metadata and support triage.
    var tag: String {
        switch self {
        case .storeMissing:        return "store_missing"
        case .pathNotWritable:     return "path_not_writable"
        case .unreadableAsStore:   return "unreadable_as_store"
        case .entitySetChanged:    return "entity_set_changed"
        case .entityShapeChanged:  return "entity_shape_changed"
        case .indeterminate:       return "indeterminate"
        }
    }
}

// MARK: - Diagnostics

enum StoreOpenDiagnostics {

    /// Classifies a failed open WITHOUT touching the store's contents.
    ///
    /// Strictly read-only: it stats the file, checks directory writability, and reads store
    /// metadata. It never opens the store for writing, never migrates, and never deletes — the
    /// launch path's whole promise is that a store it cannot read is left byte-intact.
    ///
    /// - Parameters:
    ///   - storeURL: the store that failed to open.
    ///   - expectedEntityNames: entity names in the CURRENT schema.
    static func classify(
        storeURL: URL,
        expectedEntityNames: Set<String>
    ) -> StoreOpenDiagnosis {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: storeURL.path) else {
            return .storeMissing
        }

        let directory = storeURL.deletingLastPathComponent()
        if !fileManager.isWritableFile(atPath: directory.path) {
            return .pathNotWritable(directory: directory.path)
        }

        // Core Data's raw metadata read returns a REAL NSError with a populated userInfo, unlike
        // the SwiftData wrapper. This is the whole reason for dropping to CoreData here.
        let metadata: [String: Any]
        do {
            metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                type: .sqlite, at: storeURL
            )
        } catch {
            let nsError = error as NSError
            let reason = (nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String)
                ?? nsError.localizedDescription
            return .unreadableAsStore(domain: nsError.domain, code: nsError.code, reason: reason)
        }

        // `NSStoreModelVersionHashes` maps entity name -> version hash for the model that WROTE
        // the store. Comparing its key set against the current schema identifies entity-level
        // drift precisely, which is the most common bricking shape.
        guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Any] else {
            return .indeterminate
        }

        let storedEntityNames = Set(hashes.keys)
        let addedInCode = expectedEntityNames.subtracting(storedEntityNames).sorted()
        let missingFromCode = storedEntityNames.subtracting(expectedEntityNames).sorted()

        if addedInCode.isEmpty && missingFromCode.isEmpty {
            // Same entities, still won't open => the change is inside one of them. The attribute
            // name only exists in Core Data's stderr output; see captureStandardError(during:).
            return .entityShapeChanged
        }
        return .entitySetChanged(addedInCode: addedInCode, missingFromCode: missingFromCode)
    }

    /// Runs `body` with stderr redirected to a temporary FILE, and returns whatever was written.
    ///
    /// ⚠️ A FILE, deliberately — not a pipe. A pipe has a fixed buffer (~64 KB) and blocks its
    /// writer once full, which would deadlock the launch path if Core Data ever became chatty.
    /// Files never block.
    ///
    /// Best-effort by construction: any failure to set up the redirect returns nil and runs `body`
    /// normally, because a diagnostic must never be the reason the app fails differently.
    static func captureStandardError(during body: () -> Void) -> String? {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("devgentic-stderr-\(UUID().uuidString).log")

        guard let redirected = fopen(temporaryURL.path, "w+") else {
            body()
            return nil
        }
        defer {
            fclose(redirected)
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        let redirectedDescriptor = fileno(redirected)
        let savedDescriptor = dup(STDERR_FILENO)
        guard savedDescriptor >= 0, dup2(redirectedDescriptor, STDERR_FILENO) >= 0 else {
            if savedDescriptor >= 0 { close(savedDescriptor) }
            body()
            return nil
        }

        body()

        // Flush before restoring, or the tail of the output lands in the RESTORED stderr.
        fflush(stderr)
        dup2(savedDescriptor, STDERR_FILENO)
        close(savedDescriptor)

        guard let captured = try? String(contentsOf: temporaryURL, encoding: .utf8),
              !captured.isEmpty else { return nil }
        return captured
    }

    /// Extracts the lines of captured stderr that actually identify a migration failure.
    ///
    /// Core Data prints a lot; only the lines naming an entity/attribute/reason or a
    /// `NSCocoaErrorDomain` code are worth putting in front of a user or in a support paste.
    /// Bounded on BOTH axes — `limit` lines, `maxLineLength` characters each — because Core Data's
    /// lines routinely run to several hundred characters (they embed full nested NSError
    /// descriptions with absolute URLs), and an unbounded paste is its own kind of useless.
    static func migrationDetailLines(
        in capturedStandardError: String,
        limit: Int = 6,
        maxLineLength: Int = 320
    ) -> [String] {
        let interesting = ["reason=", "entity=", "attribute=", "NSCocoaErrorDomain", "missing mapping model"]
        var seen = Set<String>()
        var result: [String] = []

        for rawLine in capturedStandardError.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard interesting.contains(where: line.contains) else { continue }
            // Core Data repeats the same diagnostic several times per failure.
            guard seen.insert(line).inserted else { continue }
            result.append(line.count > maxLineLength
                          ? String(line.prefix(maxLineLength)) + "…"
                          : line)
            if result.count == limit { break }
        }
        return result
    }

    /// The single most actionable fragment Core Data prints: which entity, which attribute, why.
    ///
    /// ⚠️ This OUTRANKS `classify(...)` when both are available. Metadata comparison reports
    /// whatever differs, which is not necessarily what BLOCKED the open — a store can legitimately
    /// carry a retired entity (harmless, lightweight migration drops it) while the actual failure
    /// is an attribute inside a completely different entity. Observed exactly that during
    /// verification: the classifier said "CodeViewerSessionSD missing from this build" while the
    /// real blocker was `PromptModel.driftProbe`. Lead with this; use the classification as
    /// supporting context.
    static func primaryFailureReason(in capturedStandardError: String) -> String? {
        // Prefer the fully-qualified form Core Data emits for validation failures.
        for line in capturedStandardError.split(separator: "\n") {
            guard let entityRange = line.range(of: "entity="),
                  line.contains("reason=") else { continue }

            let fragment = line[entityRange.lowerBound...]
            // The fragment sits inside `UserInfo={...}`; stop at the closing brace.
            let trimmed = fragment.prefix { $0 != "}" }
            let cleaned = trimmed.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned }
        }

        // Fall back to a bare `reason=` if no entity was named (e.g. a mapping-model failure).
        for line in capturedStandardError.split(separator: "\n") {
            guard let reasonRange = line.range(of: "reason=") else { continue }
            let cleaned = line[reasonRange.lowerBound...]
                .prefix { $0 != "}" }
                .trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }
}
