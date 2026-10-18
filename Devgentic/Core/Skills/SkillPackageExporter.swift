// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillPackageExporter.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillPackageExporter")

enum SkillExportError: LocalizedError, Equatable {
    case sourceMissing(String)
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path): return "The skill folder is no longer on disk: \(path)"
        case .zipFailed(let reason): return "Couldn't create the archive: \(reason)"
        }
    }
}

/// Exports one skill as a .zip of a folder written for the purpose.
/// Exports the folder itself, never a rebuilt package: a rebuild would drop hidden files, symlinks and non-UTF-8 files.
/// `--keepParent` keeps the skill's directory name in the zip root, so the archive is self-describing.
enum SkillPackageExporter {


    /// Zips a skill folder to `destination`, replacing anything already there.
    /// The folder is a throwaway written by `SkillMaterializer` into a temp directory; the caller owns and deletes it.
    static func export(skillAt folderPath: String, to destination: URL) throws {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: folderPath)

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkillExportError.sourceMissing(source.path)
        }

        // ditto refuses to overwrite; the save panel has already asked about replacement.
        try? fm.removeItem(at: destination)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -c create, -k zip format, --sequesterRsrc handles macOS metadata,
        // --keepParent preserves the skill's directory name inside the zip root (see header).
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SkillExportError.zipFailed("ditto could not be launched: \(error.localizedDescription)")
        }

        // Read before wait — the ~64 KB pipe deadlock this codebase has already paid for once.
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            logger.error("[SKILL_EXPORT] ditto exited \(process.terminationStatus) exporting '\(source.lastPathComponent)'\(detail.isEmpty ? "" : ": \(detail)"). CONSEQUENCE: no archive was written — the destination is left as it was rather than holding a truncated file.")
            throw SkillExportError.zipFailed(detail.isEmpty ? "ditto exit code \(process.terminationStatus)" : detail)
        }

        logger.info("[SKILL_EXPORT] Exported '\(source.lastPathComponent)' to \(destination.lastPathComponent).")
    }
}
