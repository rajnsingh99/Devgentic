// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillArchiveStaging.swift
//  Devgentic
//
//  Expanding a skill archive into a caller-owned staging directory, safely, offline.
//
//  ## What this used to be
//
//  `SkillPackageInstaller`: it unpacked a .zip and PROMOTED it into
//  `~/Library/Application Support/Devgentic/Skills/<name>`, because a skill's bytes lived on disk
//  and the app needed a stable folder to point at. Under the V6 library the bytes live in the store,
//  so there is nothing to promote — `SkillIngest` reads the staged tree into memory and deletes it.
//  The promote half, its Application Support root, and the directory-locating step that renamed a
//  contents-only archive are all gone with it.
//
//  ⚠️ That deletion also removed the arbitrary-recursive-delete fix, and it is worth being precise
//  about why that is safe rather than alarming. The defect was: `locateSkillRoot` derived a
//  directory name from an untrusted archive's frontmatter and handed it to `removeItem`, so
//  `name: ../../../../victim` deleted `/victim`. Nothing here builds a path from archive content any
//  more — the name becomes a database field. The one place a stored name still becomes a path is
//  `SkillMaterializer` on export, which validates it for exactly this reason.
//
//  ## The hardening, and what each part actually stops
//
//  `ZipArchiveStaging` contributes exactly one defence — reaching the archive through a symlink it
//  names itself, so `unzip`'s OWN wildcard matching cannot select a different file. That is real and
//  hard-won (an `a*.docx` in the same folder made unzip process three archives in turn), and it is
//  kept. It contributes nothing else: its own doc comment records that no size bound is applied.
//
//  Everything below is this file's job, done AFTER extraction against the real tree rather than by
//  parsing entry names, because the thing that matters is where bytes actually landed:
//
//    - **Budget**, in TWO places and the second is the load-bearing one. The pre-flight `unzip -l`
//      reads sizes the archive DECLARES — a field an attacker controls, so it refuses the honest
//      majority cheaply and stops nothing else. `enforceExtractedSizeBudget` then measures what
//      actually landed on disk, which is the only number the archive cannot lie about.
//    - **Symlink refusal**: any symlink anywhere in the tree refuses the whole package. Not
//      filtered — refused. A legitimate skill has no reason to ship one, and a symlink is how an
//      archive reaches outside itself after extraction.
//    - **Confinement**: every entry must resolve under the staging root, with a trailing separator,
//      so `/skills` cannot claim `/skills_backup`.
//
//  ⚠️ The caller owns the staging directory and MUST delete it. Nothing here is retained, and that
//  is the whole contract: this type expands and refuses, and has no opinion about what happens next.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillArchiveStaging")

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

    /// Expands an archive into a caller-owned staging directory and applies EVERY safety check,
    /// stopping before anything is promoted anywhere.
    ///
    /// ⚠️ ONE validation sequence, and it must stay one. Two copies of "preflight, expand, measure
    /// what landed, refuse symlinks" is how a check gets fixed in one place and left broken in the
    /// other — the header records the declared-size trap that only the second half catches.
    ///
    /// The caller owns `staging` and MUST delete it. Nothing here is promoted, copied, or retained.
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

        // ⚠️ ENFORCE ON WHAT ACTUALLY LANDED. The pre-flight above reads `unzip -l`, which reports
        // the sizes the archive's own central directory DECLARES — a field an attacker controls. A
        // one-line patch makes a 500 MB bomb list as 20 bytes and sail through the budget. Measuring
        // the extracted tree is the only check the archive cannot lie to; the pre-flight stays
        // because it refuses the honest majority before anything is written.
        try enforceExtractedSizeBudget(under: staged.contentRoot)

        try refuseSymlinksAndEscapes(under: staged.contentRoot)

        return staged.contentRoot
    }

    // MARK: - Pre-flight

    /// Reads the archive's table of contents and refuses it before a single byte is written.
    ///
    /// Goes through the SAME symlink staging as extraction — `unzip -l` performs the same wildcard
    /// matching on the archive name that `unzip -o` does, so listing the real path would reintroduce
    /// exactly the hole the staging trick closes.
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

    /// Reads the totals line from an `unzip -l` listing: `<bytes> <n> files`.
    ///
    /// ⚠️ Deliberately anchored on the LAST line that matches, not the first. A listing's body lines
    /// are file entries, and a filename can contain digits and the word "file" (`report-file-2.txt`),
    /// so a forward scan can lock onto an entry and read its size as the archive total. Scanning
    /// from the end finds the trailer, which is the only line that summarises.
    ///
    /// Returns nil rather than guessing when the shape is unrecognised — a localized `unzip`, or a
    /// future format change, must be an explicit "could not read this archive" rather than a
    /// silently wrong budget that lets an oversized package through.
    ///
    /// ⚠️ This is a CHEAP pre-filter over numbers the ARCHIVE DECLARES. The real bound is
    /// `enforceExtractedSizeBudget`, which measures what landed. Do not treat this as a defence.
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

    /// Measures the extracted tree and refuses it if it exceeds the budget.
    ///
    /// Runs BEFORE the symlink walk so a bomb is caught as early as possible, and before anything is
    /// promoted — the staging directory is removed by the caller's `defer` either way, so a refusal
    /// here leaves nothing behind.
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

    /// Refuses the whole package if any symlink exists, or if any entry resolved outside the root.
    ///
    /// ⚠️ Walked with `skipsHiddenFiles: false`. A hidden symlink is still a symlink, and an
    /// enumerator that skips dotfiles would walk straight past `.config -> ~/.ssh`.
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
