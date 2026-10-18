// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillIngest.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    case tooLarge(path: String)
    case unusablePath(String)
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
        case .tooLarge(let path):
            // Names the file rather than a byte total: the walk refuses on the first breach, so any total would be
            // partial.
            return "'\(path)' would push this skill past the \(SkillLibraryLimits.maxSkillBytes / 1024 / 1024) MB limit"
        case .unusablePath(let path):
            return "'\(path)' cannot be stored as a skill file path. Rename it and import again."
        case .unreadable(let detail): return detail
        }
    }
}

// MARK: - Ingest

enum SkillIngest {

    /// Filenames that are never part of a skill.
    /// Matched by extension-less name; hidden files such as `.DS_Store` are caught by the hidden-file rule.
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

        // The body is counted against the size bound: `SkillVersionSD.body` is a plain `String` stored in
        // SQLite itself, and the walk skips SKILL.md, so an uncounted body would bloat the store unreported.
        let raw: String
        do {
            raw = try SkillBoundedRead.text(at: skillFile, limit: SkillLibraryLimits.maxSkillBytes)
        } catch let refusal as SkillBoundedRead.Refusal {
            logger.error("[SKILL_INGEST] REFUSED '\(label)': its SKILL.md alone is \(refusal.bytes ?? -1) bytes, over the \(SkillLibraryLimits.maxSkillBytes) limit. CONSEQUENCE: nothing was imported and nothing was read into memory past the cap — the body is stored in the database itself, so an oversized one would bloat the store rather than the blob sidecar.")
            throw SkillIngestError.tooLarge(path: "SKILL.md")
        } catch {
            throw SkillIngestError.unreadable("SKILL.md in '\(label)' is missing or is not UTF-8 text")
        }

        let (name, description, allowedTools, body) = try parse(raw, label: label)

        // One envelope for the whole version: `maxSkillBytes` is per version, so the body's bytes are spent
        // from the same budget the walk draws on, and the cap is reached during the walk.
        let files = try collectFiles(under: directory, excluding: skillFile,
                                     alreadyUsedBytes: raw.utf8.count)

        return IngestedSkill(name: name, description: description, body: body,
                             allowedTools: allowedTools, files: files, sourceLabel: label)
    }

    // MARK: A bare .md

    /// Reads a single `.md` file as a skill with no bundled files.
    /// The name comes from the frontmatter, not the filename, and is reported back to the user.
    static func readBareMarkdown(at file: URL) throws -> IngestedSkill {
        let label = file.lastPathComponent
        // Bounded too: a bare `.md` is held to the same size limit as every other import shape.
        let raw: String
        do {
            raw = try SkillBoundedRead.text(at: file, limit: SkillLibraryLimits.maxSkillBytes)
        } catch let refusal as SkillBoundedRead.Refusal {
            logger.error("[SKILL_INGEST] REFUSED '\(label)': \(refusal.bytes ?? -1) bytes, over the \(SkillLibraryLimits.maxSkillBytes) limit. CONSEQUENCE: nothing was imported.")
            throw SkillIngestError.tooLarge(path: label)
        } catch {
            throw SkillIngestError.unreadable("'\(label)' is missing or is not UTF-8 text")
        }
        let (name, description, allowedTools, body) = try parse(raw, label: label)
        return IngestedSkill(name: name, description: description, body: body,
                             allowedTools: allowedTools, files: [], sourceLabel: label)
    }

    // MARK: A tree that may hold many skills

    /// Reads every skill under a root the user chose, reporting what it could not take.
    /// Uses the scanner's bounded recursive walk to locate skills, so layout rules are not re-derived here.
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

    /// A top-level folder that is simply not a skill is not reported as a failure.
    /// Only `.noSkillFile` is filtered; a `.parseError` means the user intended a skill and it did not
    /// load.
    private static func isNoise(_ entry: SkippedSkillEntry) -> Bool {
        if case .noSkillFile = entry.reason { return true }
        return false
    }

    // MARK: An archive

    /// Reads every skill out of a `.zip` / `.skill` archive, then discards the extraction.
    /// Extraction goes through `SkillArchiveStaging.stageValidated`, the single validated path: size budget measured
    /// on what landed, and refusal of symlinks and escaping paths. Nothing is promoted to Application Support.
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

        // `readTree`, not "find the one skill root": an archive holding several skills is ordinary.
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
    /// Archives and markdown are chosen by extension (`.skill` is a renamed zip); any other directory is
    /// walked.
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

    // Why: `Task.detached`, not a nonisolated async func: whether that leaves the caller's actor depends on the
    // language mode.
    /// The off-caller-actor form of `read(contentsOf:)`, and the only form a UI or launch path should call.
    /// The read walks every file and can block for a volume's mount timeout, so the hop is a named
    /// function, not a per-call-site detached task.
    static func readOffCallerActor(contentsOf url: URL) async -> SkillIngestOutcome {
        await Task.detached(priority: .userInitiated) {
            read(contentsOf: url)
        }.value
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

        // Shape first, before the name is used anywhere: the charset (lowercase letters, digits, hyphens)
        // makes `/`, `.` and `..` unrepresentable, so an untrusted name cannot become a traversal.
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
    static func collectFiles(under directory: URL, excluding skillFile: URL,
                             alreadyUsedBytes: Int = 0) throws -> [IngestedFile] {
        let fm = FileManager.default
        var collected: [IngestedFile] = []
        let rootPath = directory.standardizedFileURL.path
        // Bytes are spent during the walk, not summed after it; see `SkillBoundedRead`.
        var usedBytes = alreadyUsedBytes
        var fileCount = 0

        func walk(_ dir: URL, prefix: String) throws {
            // Both reads throw: a subfolder that cannot be listed (permissions, an undownloaded cloud placeholder)
            // must refuse the skill rather than store it without that folder, looking complete.
            let folder = prefix.isEmpty ? "the skill folder" : "'\(prefix)'"
            let entries: [URL]
            do {
                entries = try fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
            } catch {
                logger.error("[SKILL_INGEST] REFUSED: \(folder) could not be read — \(error.localizedDescription). CONSEQUENCE: the WHOLE skill is refused and reported, rather than imported without that folder's files.")
                throw SkillIngestError.unreadable("\(folder.prefix(1).uppercased() + folder.dropFirst()) could not be read (\(error.localizedDescription)), so the skill was not imported. Check its permissions, or download it if it lives in cloud storage, and import again.")
            }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let component = entry.lastPathComponent
                guard !component.hasPrefix("."), !ignoredFileNames.contains(component) else { continue }
                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                } catch {
                    let path = prefix.isEmpty ? component : "\(prefix)/\(component)"
                    logger.error("[SKILL_INGEST] REFUSED: '\(path)' could not be inspected — \(error.localizedDescription). CONSEQUENCE: the WHOLE skill is refused and reported, rather than imported without it.")
                    throw SkillIngestError.unreadable("'\(path)' could not be read (\(error.localizedDescription)), so the skill was not imported.")
                }

                // Symlinks are not followed: Foundation does not resolve them for `isDirectory`/`isRegularFile`, so they fall out below.
                // This guard keeps the log line and pins that assumption.
                if values.isSymbolicLink == true {
                    logger.notice("[SKILL_INGEST] '\(component)' in '\(dir.lastPathComponent)' is a SYMLINK and was not imported. CONSEQUENCE: the skill is stored without it — replace it with a real file if it is meant to ship.")
                    continue
                }

                if values.isDirectory == true {
                    guard !ignoredDirectoryNames.contains(component) else { continue }
                    // The directory name is checked too: an unusable component would be carried into the path of every
                    // file beneath it.
                    let childPrefix = prefix.isEmpty ? component : "\(prefix)/\(component)"
                    guard isSafeRelativePath(childPrefix) else {
                        throw SkillIngestError.unusablePath(childPrefix)
                    }
                    try walk(entry, prefix: childPrefix)
                    continue
                }

                guard values.isRegularFile == true else { continue }
                guard entry.standardizedFileURL.path != skillFile.standardizedFileURL.path else { continue }

                let relativePath = prefix.isEmpty ? component : "\(prefix)/\(component)"
                // Throws rather than `continue`: a dropped file records no `RejectedSkill` and the import would look complete.
                // `readTree` catches per skill, so the rest of a multi-skill import still succeeds.
                guard isSafeRelativePath(relativePath) else {
                    logger.error("[SKILL_INGEST] REFUSED the skill in '\(dir.lastPathComponent)': the bundled file '\(relativePath)' has a path that cannot be stored — most often a control character or a stray carriage return from a Windows-authored archive. CONSEQUENCE: the WHOLE skill is refused and reported to the user with this path named, rather than imported without the file; a skill missing a file it names in its instructions fails later at run time with no way to trace it back here.")
                    throw SkillIngestError.unusablePath(relativePath)
                }
                // Belt and braces: the walk cannot leave the root, and this proves it did not.
                guard entry.standardizedFileURL.path.hasPrefix(rootPath) else { continue }

                // Counted before the read: an untrusted tree can hold a million tiny files, so the bound must stop the
                // walk.
                fileCount += 1
                guard fileCount <= SkillLibraryLimits.maxFilesPerVersion else {
                    throw SkillIngestError.tooManyFiles(fileCount)
                }

                let content: Data
                do {
                    content = try SkillBoundedRead.data(
                        at: entry, limit: max(0, SkillLibraryLimits.maxSkillBytes - usedBytes))
                } catch let refusal as SkillBoundedRead.Refusal {
                    logger.error("[SKILL_INGEST] REFUSED at '\(relativePath)': it is \(refusal.bytes ?? -1) bytes with only \(max(0, SkillLibraryLimits.maxSkillBytes - usedBytes)) left in this skill's \(SkillLibraryLimits.maxSkillBytes)-byte budget. CONSEQUENCE: the skill is refused whole and the walk stopped here — nothing past the cap was read into memory, and a partial import is never stored because half a skill looks complete and fails later.")
                    throw SkillIngestError.tooLarge(path: relativePath)
                } catch {
                    throw SkillIngestError.unreadable("Could not read '\(relativePath)'")
                }
                usedBytes += content.count

                collected.append(IngestedFile(relativePath: relativePath,
                                              content: content,
                                              isExecutable: isExecutable(entry)))
            }
        }

        try walk(directory, prefix: "")
        return collected
    }

    /// A relative path safe to materialize under a destination directory and safe to print.
    /// Control characters are refused: a newline in a filename would forge a heading in `LoadSkillTool`'s output.
    /// Refused, not sanitised, because renaming would break the exported tree's match with the stored paths.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        guard path.rangeOfCharacter(from: .controlCharacters) == nil,
              path.rangeOfCharacter(from: .newlines) == nil else { return false }
        let components = path.components(separatedBy: "/")
        guard !components.contains(".."), !components.contains("."), !components.contains("") else { return false }
        return true
    }

    private static func isExecutable(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return false }
        return permissions.int16Value & 0o111 != 0
    }

}

// MARK: - Body extraction

/// Splits a SKILL.md into frontmatter and body.
/// The single implementation, so every reader stores the body the file shows.
enum SkillBodyExtraction {

    static func body(of raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first == "---",
              let closing = lines.dropFirst().firstIndex(of: "---") else { return raw }
        return lines[(closing + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
