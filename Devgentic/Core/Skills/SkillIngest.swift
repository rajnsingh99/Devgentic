// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillIngest.swift
//  Devgentic
//
//  Turning something the user pointed at into skills the library can hold.
//
//  ## What this replaces
//
//  V4/V5 never read a skill's files — it INDEXED them and re-read on demand, and even then only
//  from five hardcoded subdirectories (`reference`, `references`, `templates`, `scripts`, `assets`)
//  and only when they decoded as UTF-8. A skill with a `data/` directory contributed nothing; a
//  skill shipping a PNG or a PDF lost it silently.
//
//  Content lives in the store now, so those two behaviours change from "a little lossy at read
//  time" to "the user permanently loses files they imported". This reads EVERY regular file under
//  the skill directory, at any depth, as bytes.
//
//  ## Everything here is a boundary
//
//  The input is an archive, a folder, or a file the user chose — none of it authored by this app.
//  The rules below are the ones that must hold before anything reaches the database, because a
//  stored row is already past the point where refusing helps:
//
//    - The skill NAME is validated for shape BEFORE it is used to build any path.
//    - A file's relative path is DERIVED from the walk, then re-validated to contain no `..`
//      component and no leading separator, so an export that materializes these paths cannot write
//      outside its destination.
//    - Symlinks are never followed and never captured.
//    - Total bytes and file count are capped, and hitting a cap REJECTS the skill rather than
//      importing a truncated one — half a skill is worse than a refusal, because it looks complete.
//
//  ## Partial success is the normal case
//
//  A folder of twenty skills where one has broken frontmatter imports nineteen and REPORTS the
//  twentieth. Refusing the batch would punish the user for someone else's file, and silently
//  dropping it is how V4/V5's importer made a repo look like it contained fewer skills than it did.
//

import Foundation
import os

private let logger = DGLogger(category: "SkillIngest")

// MARK: - What a read produces

/// One skill, fully read into memory, ready to become a `SkillSD` plus its first version.
struct IngestedSkill: Sendable, Equatable {
    let name: String
    let description: String
    let body: String
    let allowedTools: [String]?
    let files: [IngestedFile]

    /// What to call this in a message to the user — a folder name, or an archive entry.
    let sourceLabel: String

    var totalBytes: Int { files.reduce(0) { $0 + $1.content.count } }
}

struct IngestedFile: Sendable, Equatable {
    /// Path relative to the skill root. Never absolute, never containing `..`.
    let relativePath: String
    let content: Data
    let isExecutable: Bool
}

/// One thing that was NOT imported, and why — in words the user can act on.
struct RejectedSkill: Sendable, Equatable {
    let label: String
    let reason: String
}

struct SkillIngestOutcome: Sendable, Equatable {
    var skills: [IngestedSkill] = []
    var rejected: [RejectedSkill] = []

    var isEmpty: Bool { skills.isEmpty && rejected.isEmpty }
}

enum SkillIngestError: LocalizedError, Equatable {
    case notFound(String)
    case noSkillFile(String)
    case invalidFrontmatter(String)
    case invalidName(String)
    case descriptionTooLong(Int)
    case tooManyFiles(Int)
    case tooLarge(Int)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): return "Nothing found at \(path)"
        case .noSkillFile(let name): return "'\(name)' has no SKILL.md file"
        case .invalidFrontmatter(let detail): return detail
        case .invalidName(let detail): return detail
        case .descriptionTooLong(let count):
            return "The description is \(count) characters; the limit is \(SkillLibraryLimits.maxDescriptionChars)"
        case .tooManyFiles(let count):
            return "This skill bundles \(count) files; the limit is \(SkillLibraryLimits.maxFilesPerVersion)"
        case .tooLarge(let bytes):
            return "This skill is \(bytes / 1024 / 1024) MB; the limit is \(SkillLibraryLimits.maxSkillBytes / 1024 / 1024) MB"
        case .unreadable(let detail): return detail
        }
    }
}

// MARK: - Ingest

enum SkillIngest {

    /// Filenames that are never part of a skill.
    ///
    /// ⚠️ Extensionless matches too (`.DS_Store` is caught by the hidden-file rule). These are the
    /// ones that are NOT hidden and would otherwise be captured, stored, and re-exported forever.
    static let ignoredFileNames: Set<String> = ["Icon\r", "Thumbs.db", "desktop.ini"]

    /// Directory names never descended into when collecting a skill's files.
    static let ignoredDirectoryNames: Set<String> = ["node_modules", ".git", "__pycache__", "__MACOSX", ".build"]

    // MARK: Folder containing a SKILL.md

    /// Reads ONE skill directory — a folder that directly contains `SKILL.md`.
    static func readSkillDirectory(at directory: URL) throws -> IngestedSkill {
        let fm = FileManager.default
        let label = directory.lastPathComponent
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillFile.path) else { throw SkillIngestError.noSkillFile(label) }

        guard let raw = try? String(contentsOf: skillFile, encoding: .utf8) else {
            throw SkillIngestError.unreadable("SKILL.md in '\(label)' is missing or is not UTF-8 text")
        }

        let (name, description, allowedTools, body) = try parse(raw, label: label)

        let files = try collectFiles(under: directory, excluding: skillFile)
        try checkLimits(files: files, label: label)

        return IngestedSkill(name: name, description: description, body: body,
                             allowedTools: allowedTools, files: files, sourceLabel: label)
    }

    // MARK: A bare .md

    /// Reads a single `.md` file as a skill with no bundled files.
    ///
    /// ⚠️ The name comes from the FRONTMATTER, not the filename — a bare file has no directory to
    /// agree with, so the directory-match rule cannot apply and the frontmatter is the only claim.
    /// This is the one import shape where a skill's name is not visible in the path the user picked,
    /// so the name is reported back to them.
    static func readBareMarkdown(at file: URL) throws -> IngestedSkill {
        let label = file.lastPathComponent
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else {
            throw SkillIngestError.unreadable("'\(label)' is missing or is not UTF-8 text")
        }
        let (name, description, allowedTools, body) = try parse(raw, label: label)
        return IngestedSkill(name: name, description: description, body: body,
                             allowedTools: allowedTools, files: [], sourceLabel: label)
    }

    // MARK: A tree that may hold many skills

    /// Reads every skill under a root the user chose, reporting what it could not take.
    ///
    /// Uses the scanner's bounded recursive walk to LOCATE skills — the layout rules (a directory
    /// that is a skill is never descended into, depth and count caps, noise denylist) are already
    /// settled there and must not be re-derived here and drift.
    static func readTree(at root: URL) -> SkillIngestOutcome {
        var outcome = SkillIngestOutcome()

        let scan: SkillScanResult
        do {
            scan = try SkillFolderScanner.scanDetailed(rootFolder: root)
        } catch {
            outcome.rejected.append(RejectedSkill(label: root.lastPathComponent,
                                                  reason: error.localizedDescription))
            logger.error("[SKILL_INGEST] Could not scan '\(root.lastPathComponent)': \(error.localizedDescription). CONSEQUENCE: nothing was imported from it and the library is unchanged.")
            return outcome
        }

        for manifest in scan.manifests {
            let directory = URL(fileURLWithPath: manifest.folderPath)
            do {
                outcome.skills.append(try readSkillDirectory(at: directory))
            } catch {
                outcome.rejected.append(RejectedSkill(label: directory.lastPathComponent,
                                                      reason: error.localizedDescription))
            }
        }

        // A directory the SCANNER rejected is still something the user expected to import.
        for skipped in scan.skipped where !isNoise(skipped) {
            outcome.rejected.append(RejectedSkill(label: skipped.directoryName,
                                                  reason: skipped.reason.displayText))
        }

        logger.info("[SKILL_INGEST] '\(root.lastPathComponent)': read \(outcome.skills.count) skill(s), rejected \(outcome.rejected.count). CONSEQUENCE: every rejection is reported to the user with its reason — a partial import must never look like a complete one.")
        return outcome
    }

    /// A top-level folder that simply is not a skill is not worth reporting as a failure.
    ///
    /// ⚠️ Only `.noSkillFile` is filtered. A `.parseError` means the user DID intend a skill and it
    /// did not load — exactly the case V4/V5 swallowed, making a repo look emptier than it was.
    ///
    /// ⚠️ A NAME COLLISION is not a skip any more. It used to be reported here as
    /// `.duplicateName(keptFrom:)` and silently resolved; the user now CHOOSES — see
    /// `SkillImportPlan`, which offers add-a-version / import-as-new / skip per colliding skill.
    private static func isNoise(_ entry: SkippedSkillEntry) -> Bool {
        if case .noSkillFile = entry.reason { return true }
        return false
    }

    // MARK: An archive

    /// Reads every skill out of a `.zip` / `.skill` archive, then discards the extraction.
    ///
    /// ⚠️ Nothing is promoted to Application Support. The bytes go into the store and the staging
    /// directory is deleted — which is the whole point of V6: there is no folder left behind to
    /// dangle, move, or disagree with the database.
    ///
    /// ⚠️ Extraction goes through `SkillArchiveStaging.stageValidated`, which is the SINGLE
    /// validated path: table-of-contents pre-flight, a size budget measured on what actually landed
    /// (never on the sizes the archive declares — an attacker controls those), and a refusal of
    /// symlinks and escaping paths. Re-implementing any of that here would give this codebase two
    /// copies of a check to keep in sync.
    static func readArchive(at url: URL) throws -> SkillIngestOutcome {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("skill-ingest", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            do { try fm.removeItem(at: staging) }
            catch CocoaError.fileNoSuchFile {}
            catch {
                logger.error("[SKILL_INGEST] Could not remove the staging directory at \(staging.path): \(error.localizedDescription). CONSEQUENCE: the skill imported correctly, but a temporary copy of its files is left in the system temp directory until the OS clears it.")
            }
        }

        let contentRoot = try SkillArchiveStaging.stageValidated(zipAt: url, into: staging)

        // ⚠️ `readTree`, not "find the one skill root". An archive holding several skills is
        // ordinary — it is what exporting a folder produces — and taking only the first would
        // import one skill from a bundle of ten with nothing said about the rest.
        var outcome = readTree(at: contentRoot)

        // The archive's own name is what the user recognises; a staging UUID is not.
        if outcome.isEmpty {
            outcome.rejected.append(RejectedSkill(
                label: url.lastPathComponent,
                reason: "No SKILL.md was found anywhere in this archive."))
        }
        return outcome
    }

    // MARK: Whatever the user dropped

    /// Reads any of the three shapes the import panel accepts, dispatching on what it is.
    ///
    /// ⚠️ Dispatches on the EXTENSION for archives and markdown, and on being a directory otherwise
    /// — not on a guessed content type. `.skill` is just a renamed zip, so both extensions take the
    /// archive path; anything else that is a directory is walked.
    static func read(contentsOf url: URL) -> SkillIngestOutcome {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return SkillIngestOutcome(skills: [], rejected: [
                RejectedSkill(label: url.lastPathComponent, reason: SkillIngestError.notFound(url.path).localizedDescription)
            ])
        }

        if isDirectory.boolValue {
            // A directory that IS a skill, or a tree that contains some.
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path) {
                do { return SkillIngestOutcome(skills: [try readSkillDirectory(at: url)], rejected: []) }
                catch {
                    return SkillIngestOutcome(skills: [], rejected: [
                        RejectedSkill(label: url.lastPathComponent, reason: error.localizedDescription)])
                }
            }
            return readTree(at: url)
        }

        switch url.pathExtension.lowercased() {
        case "zip", "skill":
            do { return try readArchive(at: url) }
            catch {
                return SkillIngestOutcome(skills: [], rejected: [
                    RejectedSkill(label: url.lastPathComponent, reason: error.localizedDescription)])
            }
        case "md", "markdown":
            do { return SkillIngestOutcome(skills: [try readBareMarkdown(at: url)], rejected: []) }
            catch {
                return SkillIngestOutcome(skills: [], rejected: [
                    RejectedSkill(label: url.lastPathComponent, reason: error.localizedDescription)])
            }
        default:
            return SkillIngestOutcome(skills: [], rejected: [
                RejectedSkill(label: url.lastPathComponent,
                              reason: "Not a skill. Drop a folder, a .zip or .skill archive, or a .md file with YAML frontmatter.")])
        }
    }

    // MARK: - Parsing

    private static func parse(
        _ raw: String, label: String
    ) throws -> (name: String, description: String, allowedTools: [String]?, body: String) {
        let frontmatter: YAMLFrontmatterParser.Frontmatter
        do {
            frontmatter = try YAMLFrontmatterParser.parse(from: raw)
        } catch {
            throw SkillIngestError.invalidFrontmatter("'\(label)': \(error.localizedDescription)")
        }

        // ⚠️ SHAPE FIRST, before the name is used anywhere. The charset — lowercase letters, digits
        // and hyphens — makes `/`, `.` and `..` unrepresentable, so a name from an untrusted archive
        // cannot become a traversal. An earlier build built a path from this value and reached
        // `removeItem` with it.
        do { try SkillFolderScanner.validateSkillNameShape(frontmatter.name) }
        catch { throw SkillIngestError.invalidName("'\(label)': \(error.localizedDescription)") }

        guard frontmatter.description.count <= SkillLibraryLimits.maxDescriptionChars else {
            throw SkillIngestError.descriptionTooLong(frontmatter.description.count)
        }

        return (frontmatter.name,
                frontmatter.description,
                frontmatter.list("allowed-tools"),
                SkillBodyExtraction.body(of: raw))
    }

    // MARK: - Files

    /// Walks a skill directory and captures every regular file as bytes.
    static func collectFiles(under directory: URL, excluding skillFile: URL) throws -> [IngestedFile] {
        let fm = FileManager.default
        var collected: [IngestedFile] = []
        let rootPath = directory.standardizedFileURL.path

        func walk(_ dir: URL, prefix: String) throws {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
            ) else { return }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let component = entry.lastPathComponent
                guard !component.hasPrefix("."), !ignoredFileNames.contains(component) else { continue }
                guard let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]) else { continue }

                // ⚠️ Symlinks are neither followed nor captured — but this branch is NOT what
                // achieves that, and saying otherwise would be the second time this codebase made
                // that mistake about this exact API. Verified by mutation: delete this guard and the
                // behaviour is unchanged, because Foundation does not resolve a symlink for
                // `isDirectory`/`isRegularFile`, so a symlinked file falls out at the
                // `isRegularFile` check below and a symlinked directory is never recursed into.
                //
                // It stays for the LOG and to pin the assumption. Without it a user whose skill
                // legitimately symlinks a file gets nothing, silently, with no way to find out why —
                // and if this walk is ever rewritten onto an API that DOES follow symlinks, the
                // guard is already in place. See the same note on `SkillFolderScanner.validFiles`.
                if values.isSymbolicLink == true {
                    logger.notice("[SKILL_INGEST] '\(component)' in '\(dir.lastPathComponent)' is a SYMLINK and was not imported. CONSEQUENCE: the skill is stored without it — replace it with a real file if it is meant to ship.")
                    continue
                }

                if values.isDirectory == true {
                    guard !ignoredDirectoryNames.contains(component) else { continue }
                    try walk(entry, prefix: prefix.isEmpty ? component : "\(prefix)/\(component)")
                    continue
                }

                guard values.isRegularFile == true else { continue }
                guard entry.standardizedFileURL.path != skillFile.standardizedFileURL.path else { continue }

                let relativePath = prefix.isEmpty ? component : "\(prefix)/\(component)"
                guard isSafeRelativePath(relativePath) else {
                    logger.error("[SKILL_INGEST] Refused a file whose relative path is unsafe: '\(relativePath)'. CONSEQUENCE: it was not imported — a path like this would escape the destination when the skill is exported.")
                    continue
                }
                // Belt and braces: the walk cannot leave the root, and this proves it did not.
                guard entry.standardizedFileURL.path.hasPrefix(rootPath) else { continue }

                guard let content = try? Data(contentsOf: entry) else {
                    throw SkillIngestError.unreadable("Could not read '\(relativePath)'")
                }
                collected.append(IngestedFile(relativePath: relativePath,
                                              content: content,
                                              isExecutable: isExecutable(entry)))
            }
        }

        try walk(directory, prefix: "")
        return collected
    }

    /// A relative path safe to materialize under a destination directory.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.components(separatedBy: "/")
        guard !components.contains(".."), !components.contains("."), !components.contains("") else { return false }
        return true
    }

    private static func isExecutable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.int16Value & 0o111 != 0
    }

    private static func checkLimits(files: [IngestedFile], label: String) throws {
        guard files.count <= SkillLibraryLimits.maxFilesPerVersion else {
            throw SkillIngestError.tooManyFiles(files.count)
        }
        let total = files.reduce(0) { $0 + $1.content.count }
        guard total <= SkillLibraryLimits.maxSkillBytes else {
            // ⚠️ REJECT, never truncate. A skill imported without the files that push it over the
            // cap looks complete in the library and fails later, somewhere unrelated.
            throw SkillIngestError.tooLarge(total)
        }
    }
}

// MARK: - Body extraction

/// Splitting a SKILL.md into frontmatter and body.
///
/// ⚠️ Its own type because THREE places used to implement this rule independently —
/// `SkillFolderScanner.extractBody`, the old on-disk editor's `split`, and ingest. A split that
/// disagreed with the scanner would store a body different from what the file shows.
///
/// The editor's copy went with the editor; the scanner's now DELEGATES here. This is the only
/// implementation, and an earlier version of this comment claimed that before it was true.
enum SkillBodyExtraction {

    static func body(of raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return raw }
        return lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
