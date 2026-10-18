// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ZipArchiveStaging.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: argv closes the shell, not `unzip`'s own parser: a literal `a*.docx` can make it extract other archives.
    /// Expands the zip at `url` into a fresh private directory; throws `DocumentExtractionError` on failure. The
    /// archive is reached through a symlink with a name this code chooses, and `stdin` is closed so an encrypted
    /// archive fails instead of prompting. The size written to disk is not bounded here.
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

    /// Expands a zip into a caller-chosen destination and throws a typed error. `workDirectory` belongs to the caller
    /// and is never removed here. Performs no content validation (size, symlinks, entry paths); the installer must
    /// check the extracted tree.
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
        // Capture stderr: unzip reports refusals of escaping paths there, which distinguishes a hostile archive from a
        // corrupt one.
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
        // Read before wait: draining the pipe after `waitUntilExit()` deadlocks once output exceeds the ~64 KB pipe
        // buffer.
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
