// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  StoreRecovery.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Results

/// Outcome of moving a store's complete artifact set aside.
struct QuarantineResult: Equatable {
    /// Where the old store now lives.
    let quarantinedStoreURL: URL
    /// Every artifact that was moved, in the order it moved.
    let movedArtifacts: [URL]
}

/// Companion stores that a SwiftData reset does not touch (vector index, media cache, diagnostics database), named so
/// the confirmation dialog can warn they will reference conversations that are gone.
struct CompanionStore: Equatable {
    let label: String
    let url: URL
}

enum StoreRecoveryError: LocalizedError {
    case nothingToMove(storeURL: URL)
    case destinationUnavailable(reason: String)
    case moveFailed(artifact: String, underlying: String, rolledBack: Bool)

    var errorDescription: String? {
        switch self {
        case .nothingToMove(let storeURL):
            return "There is no database file at \(storeURL.path) to move."
        case .destinationUnavailable(let reason):
            return "A destination could not be prepared: \(reason)"
        case .moveFailed(let artifact, let underlying, let rolledBack):
            let state = rolledBack
                ? "Everything was put back where it was."
                : "⚠️ The database may now be split between two locations."
            return "Could not move \(artifact): \(underlying). \(state)"
        }
    }
}

// MARK: - Recovery operations

enum StoreRecovery {

    private static let logger = DGLogger(category: "StoreRecovery")

    // MARK: Artifact discovery

    /// Every artifact belonging to `storeURL` that exists on disk, ordered store-last so a move applies sidecars first
    /// and never strands a store file without its WAL.
    static func existingArtifacts(for storeURL: URL) -> [URL] {
        let artifacts = DevgenticSchema.storeArtifactURLs(for: storeURL)
        return [artifacts.support, artifacts.wal, artifacts.shm, artifacts.store]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Total size on disk of the complete artifact set, for showing the user what is at stake.
    static func totalSize(for storeURL: URL) -> Int64 {
        existingArtifacts(for: storeURL).reduce(0) { $0 + sizeOfItem(at: $1) }
    }

    private static func sizeOfItem(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }

        guard isDirectory.boolValue else {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// The other persistent stores a SwiftData reset leaves untouched. Returned whether or not they exist, so the caller
    /// can filter and report accurately.
    static func companionStores(bundleIdentifier: String?) -> [CompanionStore] {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return [] }

        var stores: [CompanionStore] = [
            CompanionStore(label: "Diagnostics database",
                           url: appSupport.appendingPathComponent("Devgentic/traces.sqlite")),
            CompanionStore(label: "Media cache",
                           url: appSupport.appendingPathComponent("Devgentic/MediaCache", isDirectory: true)),
        ]
        if let bundleIdentifier {
            stores.append(CompanionStore(
                label: "Vector search index",
                url: appSupport.appendingPathComponent(bundleIdentifier).appendingPathComponent("vector-db", isDirectory: true)
            ))
        }
        return stores.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    // MARK: Export

    /// Copies the complete artifact set into a new folder inside `destinationDirectory`; a folder because the store is
    /// several files. - Returns: the created folder.
    @discardableResult
    static func exportCopy(
        of storeURL: URL,
        into destinationDirectory: URL,
        folderName: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let artifacts = existingArtifacts(for: storeURL)
        guard !artifacts.isEmpty else { throw StoreRecoveryError.nothingToMove(storeURL: storeURL) }

        let folder = uniqueURL(in: destinationDirectory, baseName: folderName, pathExtension: nil)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw StoreRecoveryError.destinationUnavailable(reason: error.localizedDescription)
        }

        for artifact in artifacts {
            do {
                try fileManager.copyItem(at: artifact, to: folder.appendingPathComponent(artifact.lastPathComponent))
            } catch {
                // Leave the partial folder in place but tell the truth about it — deleting it
                // would destroy whatever DID copy, which may be all the user needs.
                logger.error(
                    "[RECOVERY] Export failed while copying \(artifact.lastPathComponent) to \(folder.path): "
                    + "\(error.localizedDescription). CONSEQUENCE: the exported folder is INCOMPLETE and "
                    + "must not be treated as a backup; the original store is untouched."
                )
                throw StoreRecoveryError.moveFailed(
                    artifact: artifact.lastPathComponent,
                    underlying: error.localizedDescription,
                    rolledBack: false
                )
            }
        }

        let bytes = artifacts.reduce(0) { $0 + sizeOfItem(at: $1) }
        logger.info(
            "[RECOVERY] Exported \(artifacts.count) artifact(s) (\(bytes) bytes) to \(folder.path) — "
            + "store, WAL, SHM and external-storage sidecar where present."
        )
        return folder
    }

    // MARK: Quarantine ("start fresh")

    /// Moves the complete artifact set aside so the app can create a new, empty store. All-or-nothing: on a failed move,
    /// everything already moved is put back and the error says whether the rollback succeeded. Never deletes anything.
    /// `suffix` is a caller-supplied uniquifier so the result is deterministic.
    @discardableResult
    static func quarantine(storeURL: URL, suffix: String) throws -> QuarantineResult {
        let fileManager = FileManager.default
        let artifacts = existingArtifacts(for: storeURL)
        guard !artifacts.isEmpty else { throw StoreRecoveryError.nothingToMove(storeURL: storeURL) }

        let directory = storeURL.deletingLastPathComponent()
        let originalBase = storeURL.deletingPathExtension().lastPathComponent
        let pathExtension = storeURL.pathExtension

        // Resolve a base name that collides with nothing — the user may have done this before.
        let quarantinedBase = uniqueBaseName(
            in: directory,
            preferred: "\(originalBase)-quarantined-\(suffix)",
            pathExtension: pathExtension
        )
        let quarantinedStoreURL = directory
            .appendingPathComponent(quarantinedBase)
            .appendingPathExtension(pathExtension)

        var completed: [(from: URL, to: URL)] = []

        for artifact in artifacts {
            // The support directory is `.<base>_SUPPORT`, not `<base>.store<suffix>`, so it needs its own mapping; renaming it
            // in step keeps the quarantined copy self-contained and stops a new store adopting its blobs.
            let destination = destinationURL(
                for: artifact,
                originalBase: originalBase,
                quarantinedBase: quarantinedBase,
                in: directory
            )

            do {
                try fileManager.moveItem(at: artifact, to: destination)
                completed.append((from: artifact, to: destination))
            } catch {
                let rolledBack = rollBack(completed)
                logger.error(
                    "[RECOVERY] Quarantine FAILED moving \(artifact.lastPathComponent): "
                    + "\(error.localizedDescription). Rolled back \(completed.count) earlier move(s): "
                    + "\(rolledBack ? "successfully" : "INCOMPLETELY"). CONSEQUENCE: "
                    + (rolledBack
                       ? "the store is exactly as it was; nothing was lost."
                       : "the store is SPLIT between its original location and the quarantine name — "
                         + "do not create a new store until this is resolved by hand.")
                )
                throw StoreRecoveryError.moveFailed(
                    artifact: artifact.lastPathComponent,
                    underlying: error.localizedDescription,
                    rolledBack: rolledBack
                )
            }
        }

        logger.info(
            "[RECOVERY] Quarantined \(completed.count) artifact(s) to base '\(quarantinedBase)' in "
            + "\(directory.path). CONSEQUENCE: the app will create an EMPTY store on next launch; "
            + "the previous data is intact under the quarantined name and can be restored by "
            + "renaming it back."
        )
        return QuarantineResult(
            quarantinedStoreURL: quarantinedStoreURL,
            movedArtifacts: completed.map(\.to)
        )
    }

    // MARK: - Helpers

    /// Maps one artifact to its quarantined location, preserving the sidecar naming rules.
    private static func destinationURL(
        for artifact: URL,
        originalBase: String,
        quarantinedBase: String,
        in directory: URL
    ) -> URL {
        let name = artifact.lastPathComponent

        // `.DevgenticSD_SUPPORT` -> `.DevgenticSD-quarantined-<suffix>_SUPPORT`
        if name == ".\(originalBase)_SUPPORT" {
            return directory.appendingPathComponent(".\(quarantinedBase)_SUPPORT", isDirectory: true)
        }
        // `DevgenticSD.store`, `DevgenticSD.store-wal`, `DevgenticSD.store-shm` all share the base.
        return directory.appendingPathComponent(name.replacingOccurrences(
            of: originalBase, with: quarantinedBase, options: [.anchored]
        ))
    }

    /// Reverses completed moves, newest first. Returns whether every one was undone.
    private static func rollBack(_ completed: [(from: URL, to: URL)]) -> Bool {
        var fullyRestored = true
        for move in completed.reversed() {
            do {
                try FileManager.default.moveItem(at: move.to, to: move.from)
            } catch {
                fullyRestored = false
                logger.error(
                    "[RECOVERY] Rollback could not restore \(move.to.lastPathComponent) to "
                    + "\(move.from.path): \(error.localizedDescription). CONSEQUENCE: this artifact "
                    + "is stranded under its quarantine name and must be renamed back by hand."
                )
            }
        }
        return fullyRestored
    }

    /// A base name for which no destination artifact exists in `directory`. Checks all four destinations (store, `-wal`,
    /// `-shm`, support directory), since a stray `-wal` from an interrupted quarantine would force a rollback.
    private static func uniqueBaseName(in directory: URL, preferred: String, pathExtension: String) -> String {
        let fileManager = FileManager.default
        func isTaken(_ base: String) -> Bool {
            let store = directory.appendingPathComponent(base).appendingPathExtension(pathExtension)
            let candidates = [
                store,
                URL(fileURLWithPath: store.path + "-wal"),
                URL(fileURLWithPath: store.path + "-shm"),
                directory.appendingPathComponent(".\(base)_SUPPORT"),
            ]
            return candidates.contains { fileManager.fileExists(atPath: $0.path) }
        }

        guard isTaken(preferred) else { return preferred }
        // Bounded: 1000 collisions in one second means something is very wrong, and an unbounded
        // loop on a fatal path is worse than a slightly-uglier name.
        for attempt in 2...1000 where !isTaken("\(preferred)-\(attempt)") {
            return "\(preferred)-\(attempt)"
        }
        return "\(preferred)-\(UUID().uuidString.prefix(8))"
    }

    /// A URL not already taken in `directory`.
    private static func uniqueURL(in directory: URL, baseName: String, pathExtension: String?) -> URL {
        func build(_ name: String) -> URL {
            let base = directory.appendingPathComponent(name)
            return pathExtension.map { base.appendingPathExtension($0) } ?? base
        }
        guard FileManager.default.fileExists(atPath: build(baseName).path) else { return build(baseName) }
        for attempt in 2...1000 where !FileManager.default.fileExists(atPath: build("\(baseName)-\(attempt)").path) {
            return build("\(baseName)-\(attempt)")
        }
        return build("\(baseName)-\(UUID().uuidString.prefix(8))")
    }
}
