// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

/// Typed failures from the generalised expansion, so callers that are not extracting a document
/// can report something truthful. `expandZip` maps these back to `DocumentExtractionError`.
enum ZipStagingError: Error {
    case staging(Error)
    case launch(Error)
    case corrupt
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
    /// Document-extraction entry point. Unchanged behaviour: a private temp staging directory and
    /// `DocumentExtractionError` on failure.
    static func expandZip(at url: URL, format: String) throws -> StagedArchive {
        do {
            return try expand(at: url, into: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString), label: format)
        } catch let error as ZipStagingError {
            switch error {
            case .corrupt:
                throw DocumentExtractionError.corruptedFile(url.path)
            case .staging(let underlying), .launch(let underlying):
                throw DocumentExtractionError.extractionFailed(format, underlying: underlying)
            }
        }
    }

    /// Generalised expansion: caller chooses the destination and gets a typed error.
    ///
    /// ⚠️ `workDirectory` is the CALLER'S to remove. `expandZip` documents a `defer`-delete because
    /// a document extraction is transient; an INSTALL keeps what it extracted, so this variant makes
    /// no such promise. Deleting it here would delete the thing being installed.
    ///
    /// ⚠️ This function performs NO content validation. It does not bound the extracted size, does
    /// not refuse symlinks, and does not confine entry paths. Those are the installer's job, done
    /// after extraction against the real tree — see `SkillPackageInstaller`. Anything that expands
    /// an archive from an untrusted source and skips that step has a hole.
    static func expand(at url: URL, into workDirectory: URL, label: String) throws -> StagedArchive {
        let format = label
        let contentRoot = workDirectory.appendingPathComponent("content")

        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': could not create a staging directory (\(error.localizedDescription)). Extraction abandoned.")
            throw ZipStagingError.staging(error)
        }

        // The one name `unzip` is allowed to see. Fixed, and inside a directory named by UUID.
        let stagedArchive = workDirectory.appendingPathComponent("archive.zip")
        do {
            try FileManager.default.createSymbolicLink(at: stagedArchive, withDestinationURL: url)
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': could not stage the archive (\(error.localizedDescription)). Extraction abandoned rather than passing the real path to unzip.")
            throw ZipStagingError.staging(error)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", stagedArchive.path, "-d", contentRoot.path]
        process.standardOutput = FileHandle.nullDevice
        // ⚠️ stderr is CAPTURED, not discarded. unzip reports its own refusals here — `skipped
        // "../" path component(s)`, `stripped absolute path spec` — which is the evidence that an
        // archive tried to escape its destination. Sending it to /dev/null left only the exit
        // status, so a hostile archive and a corrupt one produced the same message.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        // Kept: an encrypted archive PROMPTS for a password, and a prompt on an inherited stdin
        // waits forever. Reading EOF turns that into a reportable failure instead of a hang.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': unzip could not be launched (\(error.localizedDescription)). Extraction abandoned.")
            throw ZipStagingError.launch(error)
        }
        // ⚠️ READ BEFORE WAIT. Draining the pipe after `waitUntilExit()` is the ~64 KB deadlock
        // this codebase already paid for once across 38 call sites; a verbose unzip on a large
        // archive reaches that comfortably.
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stderrText.isEmpty {
            logger.notice("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': unzip reported: \(stderrText). CONSEQUENCE: entries it names were altered or skipped by unzip itself — treat an archive that triggers path warnings as hostile, not merely malformed.")
        }

        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: workDirectory)
            logger.error("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': unzip exited \(process.terminationStatus)\(stderrText.isEmpty ? "" : " — \(stderrText)"); treating the archive as corrupt. No content extracted.")
            throw ZipStagingError.corrupt
        }

        logger.debug("[ZIPSTAGE] \(format) '\(url.lastPathComponent)': expanded into a private staging directory")
        return StagedArchive(workDirectory: workDirectory, contentRoot: contentRoot)
    }
}
