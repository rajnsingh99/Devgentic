// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillPackageExporter.swift
//  Devgentic
//
//  Exports one skill as a .zip of a folder written for the purpose.
//
//  ## Exports the FOLDER, never a rebuilt package
//
//  The tempting alternative — serialize a `SkillPackage` from `loadFullPackage` — silently loses
//  most of a real skill. `loadResources` is lossy by design: five named subdirectories, one level
//  deep, no hidden files, no symlinks, nothing over 10 MB, and every non-UTF-8 file skipped. A
//  recipient would get a skill missing its images and binaries, with no error anywhere to say so.
//  Copying the bytes is the only export that round-trips.
//
//  ## `--keepParent`: defence in depth, NOT load-bearing
//
//  It preserves the skill's directory name inside the zip root, which keeps an exported archive
//  recognisable to a human and to other tools. It used to be REQUIRED, because
//  `SkillFolderScanner` requires the frontmatter `name` to EQUAL the directory name.
//
//  ⚠️ An earlier version of this comment claimed dropping the flag would break every recipient's
//  import. **Mutation testing disproved that**: removing it leaves all 12 installer tests green,
//  because the importer tolerates a contents-only archive — `SkillIngest.readTree` finds SKILL.md
//  wherever it sits in the staged tree. (It used to tolerate it by RENAMING the staging directory;
//  that step went with the promote half.) The original note read:
//  by renaming the staging directory to the declared `name`. Both shapes install.
//
//  The flag still earns its place — it makes the archive SELF-DESCRIBING, so the skill's identity
//  travels in the bytes rather than depending on a frontmatter re-parse or on whatever the
//  recipient's unarchiver happens to name the folder — but it is not the only thing standing
//  between an export and a broken import, and the comment should not claim it is.
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

enum SkillPackageExporter {


    /// Zips a skill folder to `destination`, replacing anything already there.
    ///
    /// ⚠️ The folder is a THROWAWAY written by `SkillMaterializer` into a temp directory — a skill
    /// has no folder on disk any more. The caller owns that directory and deletes it afterwards.
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
