// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ZipArchiveStaging.swift
//  Devgentic
//
//  Expanding an OOXML container (.docx / .pptx / .xlsx) without letting its FILENAME
//  choose which archive gets opened.
//

import Foundation
import os

private let logger = DGLogger(category: "ZipArchiveStaging")

/// A temporary tree holding one expanded archive.
struct StagedArchive {
    /// Remove this in a `defer` — it contains both the staging link and the expanded content.
    let workDirectory: URL
    /// Where the archive's entries were written.
    let contentRoot: URL
}

enum ZipArchiveStaging {

    /// Expands the zip at `url` into a fresh private directory.
    ///
    /// ## Why the archive is not passed to `unzip` by its real path
    ///
    /// `DOCXExtractor` and `PPTXExtractor` both ran `/usr/bin/unzip -o <path> -d <temp>` through
    /// `Process`, with **no shell anywhere** — and that was not enough, because `unzip` performs
    /// its OWN wildcard matching on the archive name. Reproduced 2026-08-01: with `aX.docx`,
    /// `aY.docx` and a file literally named `a*.docx` in one folder, asking for `a*.docx` made
    /// unzip process all three in turn, each overwriting `word/document.xml` in the output
    /// directory — so `read_file` returned **a different document's text** under the requested
    /// path, exit code 0, reported as a success. Nothing in the result hinted the content was not
    /// the file that was asked for.
    ///
    /// This is the fourth time in this codebase that argv has been mistaken for a complete
    /// defence (see §3.5 — `git_tool`, `grep`, `rg`). The rule it keeps teaching: **argv closes
    /// the SHELL, not the invoked program's own parser.** `unzip` has no `--` separator to end
    /// option and pattern processing, so there is nothing to add to the argument list.
    ///
    /// Refusing paths containing `*?[]` was rejected as the fix: brackets are ordinary in real
    /// document names (`Report [final].docx`), so that trades a wrong answer for a broken one.
    /// Instead the archive is reached through a symlink whose name this code chooses, inside a
    /// directory this code named — so the string `unzip` parses contains no metacharacters at all
    /// and cannot match anything else, whatever the user's file is called.
    ///
    /// `stdin` is closed for the same family of reason as the `S_IFREG` guard in `read_file`: an
    /// encrypted archive makes `unzip` PROMPT for a password, and a prompt on an inherited stdin
    /// waits forever. Reading EOF turns that into a prompt failure, which is a wrong answer this
    /// function can report rather than a hang no timeout can clear.
    ///
    /// - Note: bounds on how much may be written to disk are NOT applied here; `maxSize` caps the
    ///   extracted TEXT, not the archive. That gap is recorded in §6.
    static func expandZip(at url: URL, format: String) throws -> StagedArchive {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let contentRoot = workDirectory.appendingPathComponent("content")

        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': could not create a staging directory (\(error.localizedDescription)). Extraction abandoned.")
            throw DocumentExtractionError.extractionFailed(format, underlying: error)
        }

        // The one name `unzip` is allowed to see. Fixed, and inside a directory named by UUID.
        let stagedArchive = workDirectory.appendingPathComponent("archive.zip")
        do {
            try FileManager.default.createSymbolicLink(at: stagedArchive, withDestinationURL: url)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': could not stage the archive (\(error.localizedDescription)). Extraction abandoned rather than passing the real path to unzip.")
            throw DocumentExtractionError.extractionFailed(format, underlying: error)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", stagedArchive.path, "-d", contentRoot.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': unzip could not be launched (\(error.localizedDescription)). Extraction abandoned.")
            throw DocumentExtractionError.extractionFailed(format, underlying: error)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': unzip exited \(process.terminationStatus); treating the archive as corrupt. No content extracted.")
            throw DocumentExtractionError.corruptedFile(url.path)
        }

        logger.debug("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': expanded into a private staging directory")
        return StagedArchive(workDirectory: workDirectory, contentRoot: contentRoot)
    }
}
