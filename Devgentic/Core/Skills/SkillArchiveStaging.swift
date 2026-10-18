// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillArchiveStaging.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillArchiveStaging")

/// Errors raised while safely expanding a skill archive into a caller-owned staging directory, offline, before its
/// contents are ingested.
enum SkillArchiveError: LocalizedError, Equatable {
    case archiveUnreadable(String)
    case tooLarge(bytes: Int, limit: Int)
    case tooManyEntries(count: Int, limit: Int)
    case containsSymlink(String)
    case escapesDestination(String)

    var errorDescription: String? {
        switch self {
        case .archiveUnreadable(let reason):
            return "The archive could not be read: \(reason)"
        case .tooLarge(let bytes, let limit):
            return "This package expands to \(bytes / 1024 / 1024) MB; the limit is \(limit / 1024 / 1024) MB."
        case .tooManyEntries(let count, let limit):
            return "This package contains \(count) files; the limit is \(limit)."
        case .containsSymlink(let path):
            return "This package contains a symbolic link (\(path)), which is not allowed."
        case .escapesDestination(let path):
            return "This package contains an entry that would be written outside its folder (\(path))."
        }
    }
}

enum SkillArchiveStaging {

    /// Uncompressed-size ceiling for one skill package.
    static let maxUncompressedBytes = 100 * 1024 * 1024
    /// Entry-count ceiling. A zip bomb is as easily many tiny files as one huge one.
    static let maxEntries = 5_000

    /// Expands an archive into a caller-owned staging directory and applies every safety check; nothing is promoted or
    /// retained. The caller owns `staging` and must delete it. This is the single validation sequence (preflight, expand,
    /// measure, refuse symlinks).
    static func stageValidated(zipAt url: URL, into staging: URL) throws -> URL {
        try preflight(url)

        let staged: StagedArchive
        do {
            staged = try ZipArchiveStaging.expand(at: url, into: staging, label: "skill")
        } catch let error as ZipStagingError {
            switch error {
            case .corrupt: throw SkillArchiveError.archiveUnreadable("the archive is corrupt or encrypted")
            case .staging(let e), .launch(let e): throw SkillArchiveError.archiveUnreadable(e.localizedDescription)
            }
        }

        // Enforces the budget on what actually landed: the pre-flight reads sizes the archive itself declares, which an
        // attacker controls. The pre-flight stays to refuse honest oversize archives early.
        try enforceExtractedSizeBudget(under: staged.contentRoot)

        try refuseSymlinksAndEscapes(under: staged.contentRoot)

        return staged.contentRoot
    }

    // MARK: - Pre-flight

    /// Reads the archive's table of contents and refuses it before a byte is written. Goes through the same symlink
    /// staging as extraction, since `unzip -l` does the same wildcard matching on the archive name.
    private static func preflight(_ url: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staged = work.appendingPathComponent("archive.zip")
            try fm.createSymbolicLink(at: staged, withDestinationURL: url)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-l", staged.path]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()   // read before wait
            process.waitUntilExit()

            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                throw SkillArchiveError.archiveUnreadable("unzip could not list the archive")
            }

            // unzip -l's trailer: "  <total bytes>  <n> files"
            guard let totals = parseListingTotals(text) else {
                throw SkillArchiveError.archiveUnreadable("unzip's listing could not be parsed")
            }
            let bytes = totals.bytes
            let entries = totals.entries

            guard bytes <= maxUncompressedBytes else {
                logger.error("[SKILL_ARCHIVE] REFUSED '\(url.lastPathComponent)': expands to \(bytes) bytes, over the \(maxUncompressedBytes) limit. CONSEQUENCE: nothing was written to disk — a compressed archive can expand to many times the user's free space.")
                throw SkillArchiveError.tooLarge(bytes: bytes, limit: maxUncompressedBytes)
            }
            guard entries <= maxEntries else {
                logger.error("[SKILL_ARCHIVE] REFUSED '\(url.lastPathComponent)': \(entries) entries, over the \(maxEntries) limit. CONSEQUENCE: nothing was written to disk.")
                throw SkillArchiveError.tooManyEntries(count: entries, limit: maxEntries)
            }
        } catch let error as SkillArchiveError {
            throw error
        } catch {
            throw SkillArchiveError.archiveUnreadable(error.localizedDescription)
        }
    }

    /// Reads the totals line from an `unzip -l` listing (`<bytes> <n> files`), anchored on the last matching line since
    /// entry names can contain digits and "file". Returns nil when the shape is unrecognised, so an unreadable listing is
    /// an explicit failure. A cheap pre-filter over declared numbers, not a defence.
    static func parseListingTotals(_ listing: String) -> (bytes: Int, entries: Int)? {
        let trailer = listing
            .components(separatedBy: "\n")
            .reversed()
            .first { $0.contains("file") && $0.rangeOfCharacter(from: .decimalDigits) != nil } ?? ""
        let numbers = trailer.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        return (bytes: numbers[0], entries: numbers[1])
    }

    // MARK: - Post-extraction validation

    /// Measures the extracted tree and refuses it if it exceeds the budget. Runs before the symlink walk so a bomb is
    /// caught early; the caller's `defer` removes the staging directory either way.
    static func enforceExtractedSizeBudget(under root: URL) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return }

        var total = 0
        var count = 0
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            count += 1
            total += values.fileSize ?? 0

            // Bail on the FIRST breach rather than walking a million-file tree to report a number.
            if total > maxUncompressedBytes {
                logger.error("[SKILL_ARCHIVE] REFUSED: the extracted package exceeds \(maxUncompressedBytes) bytes (the archive's own listing under-reported it). CONSEQUENCE: the staging directory is discarded and the archive is refused and nothing is read.")
                throw SkillArchiveError.tooLarge(bytes: total, limit: maxUncompressedBytes)
            }
            if count > maxEntries {
                logger.error("[SKILL_ARCHIVE] REFUSED: the extracted package holds more than \(maxEntries) files (the archive's own listing under-reported it). CONSEQUENCE: the staging directory is discarded and the archive is refused and nothing is read.")
                throw SkillArchiveError.tooManyEntries(count: count, limit: maxEntries)
            }
        }
    }

    /// Refuses the whole package if any symlink exists or any entry resolved outside the root. Walked with
    /// `skipsHiddenFiles: false`, since a hidden symlink such as `.config -> ~/.ssh` is still a symlink.
    private static func refuseSymlinksAndEscapes(under root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }

        for case let item as URL in walker {
            if let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                logger.error("[SKILL_ARCHIVE] REFUSED: archive contains a symbolic link at '\(item.lastPathComponent)'. CONSEQUENCE: the whole package is rejected and the archive is refused and nothing is read — a link is how an extracted archive reaches files outside its own folder.")
                throw SkillArchiveError.containsSymlink(item.lastPathComponent)
            }
            // Trailing-separator prefix check: `/a/skills` must not claim `/a/skills_backup`.
            let resolved = item.standardizedFileURL.path
            guard resolved == rootPath || resolved.hasPrefix(prefix) else {
                logger.error("[SKILL_ARCHIVE] REFUSED: entry resolved to '\(resolved)', outside the staging root. CONSEQUENCE: the archive is refused and nothing is read.")
                throw SkillArchiveError.escapesDestination(item.lastPathComponent)
            }
        }
    }
}
