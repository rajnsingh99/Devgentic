// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillFolderScanner.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "SkillFolderScanner")

// MARK: - Skill Folder Scanner

/// Scans a skill folder on disk, parses YAML frontmatter from SKILL.md files and loads full skill packages on demand.
/// Follows the agentskills.io specification.
enum SkillFolderScanner {

    /// Scans a root skill folder and returns manifests for each valid skill subdirectory.
    /// A valid skill subdirectory contains a `SKILL.md` file with proper YAML frontmatter.
    static func scan(rootFolder: URL) throws -> [SkillManifest] {
        try scanDetailed(rootFolder: rootFolder).manifests
    }

    /// Detailed scan returning accepted manifests plus skipped entries with reasons.
    /// Handles a multi-skill folder (root contains skill subdirectories) and a single-skill folder (root itself has a
    /// SKILL.md).
    static func scanDetailed(rootFolder: URL) throws -> SkillScanResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: rootFolder.path) else {
            throw SkillParseError.folderNotFound(rootFolder.path)
        }

        // Single-skill detection: if root itself has SKILL.md, treat as single-skill import
        let rootSkillFile = rootFolder.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: rootSkillFile.path) {
            do {
                let manifest = try parseManifest(from: rootSkillFile, folderPath: rootFolder.path)
                return SkillScanResult(manifests: [manifest], skipped: [], totalSubdirectories: 0, isSingleSkillImport: true)
            } catch {
                return SkillScanResult(
                    manifests: [],
                    skipped: [SkippedSkillEntry(directoryName: rootFolder.lastPathComponent, reason: .parseError(error.localizedDescription))],
                    totalSubdirectories: 0,
                    isSingleSkillImport: true
                )
            }
        }

        // Multi-skill folder: bounded recursive walk, general rather than a hardcoded `skills/` + `plugins/` layout,
        // so `repo/skills/<name>/SKILL.md` imports instead of reading as 'this repo has no skills'.
        var manifests: [SkillManifest] = []
        var skipped: [SkippedSkillEntry] = []
        var examined = 0
        var hitTheCap = false

        /// Directories that are never a skill and are expensive or wrong to descend into.
        /// A user can perfectly reasonably point at a checkout rather than a curated folder.
        let ignoredNames: Set<String> = ["node_modules", ".git", ".build", "DerivedData", "__MACOSX", "Pods", "venv", ".venv"]

        func children(of dir: URL) -> [URL] {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
            return entries
                .filter { url in
                    guard !url.lastPathComponent.hasPrefix("."), !ignoredNames.contains(url.lastPathComponent) else { return false }
                    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                    // Symlinked directories are not followed: a walk that follows them can cycle or leave the chosen folder.
                    return values.isDirectory == true && values.isSymbolicLink != true
                }
                // Sorted so an import is deterministic: `contentsOfDirectory` returns filesystem order, which would decide
                // which of two same-named skills wins a collision. Prompt order is owned by `SkillResolution`.
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        /// Returns true when this subtree yielded at least one skill (accepted OR rejected-on-parse),
        /// so the caller can tell "nothing here" from "something here that failed".
        @discardableResult
        func walk(_ dir: URL, depth: Int) -> Bool {
            guard !hitTheCap else { return false }
            guard examined < maxDirectoriesExamined else {
                hitTheCap = true
                return false
            }
            examined += 1

            let skillFile = dir.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillFile.path) {
                // A directory that is a skill is never descended into: its `reference/`, `scripts/` and `assets/` are resources,
                // not nested skills, and this keeps the walk bounded.
                do {
                    manifests.append(try parseManifest(from: skillFile, folderPath: dir.path))
                } catch {
                    skipped.append(SkippedSkillEntry(directoryName: dir.lastPathComponent,
                                                     reason: .parseError(error.localizedDescription)))
                }
                return true
            }

            guard depth < maxScanDepth else { return false }

            var foundAny = false
            for child in children(of: dir) where !hitTheCap {
                if walk(child, depth: depth + 1) { foundAny = true }
            }
            return foundAny
        }

        let topLevel = children(of: rootFolder)
        for child in topLevel {
            // Report a top-level child as skipped only when its whole subtree yielded nothing,
            // so `skills/` is not listed as 'No SKILL.md file' while contributing every skill.
            if !walk(child, depth: 1) && !hitTheCap {
                skipped.append(SkippedSkillEntry(directoryName: child.lastPathComponent, reason: .noSkillFile))
            }
        }

        if hitTheCap {
            logger.error("[SKILL_SCAN] Scan of '\(rootFolder.lastPathComponent)' stopped after examining \(maxDirectoriesExamined) directories. CONSEQUENCE: any skills beyond that point were NOT imported and are not listed as skipped — this folder is almost certainly a source checkout rather than a skills collection. Point at the skills directory itself.")
        }

        return SkillScanResult(manifests: manifests, skipped: skipped,
                               totalSubdirectories: topLevel.count, isSingleSkillImport: false)
    }

    /// How deep below the chosen folder a skill may sit: 4 covers `plugins/<plugin>/skills/<skill>/`.
    /// A bound on a walk over a user-chosen directory, not a statement about what is legal.
    static let maxScanDepth = 4

    // Why: The user picks the folder with an open panel, and a source checkout or home directory would otherwise be walked
    // entirely on the main actor.
    /// Hard ceiling on directories examined in one scan; hitting it is logged rather than silently truncated.
    static let maxDirectoriesExamined = 5_000

    /// Parses a single SKILL.md file into a lightweight manifest.
    /// Validates the skill name per the agentskills.io specification.
    static func parseManifest(from skillFile: URL, folderPath: String) throws -> SkillManifest {
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let frontmatter = try YAMLFrontmatterParser.parse(from: content)
        let folderURL = URL(fileURLWithPath: folderPath)
        let resourceCount = countResources(in: folderURL)
        let hasScripts = hasScriptFiles(in: folderURL)

        return SkillManifest(
            id: UUID(),
            // Shape only: the name need not equal its folder name, which is a transport detail.
            // The charset makes `/`, `.` and `..` unrepresentable, so an archive name cannot traverse.
            name: try validateSkillNameShape(frontmatter.name),
            description: frontmatter.description,
            folderPath: folderPath,
            resourceCount: resourceCount,
            hasScripts: hasScripts,
            compatibility: frontmatter.additionalFields["compatibility"],
            isEnabled: true,
            allowedTools: frontmatter.list("allowed-tools")
        )
    }

    // MARK: - Private Helpers

    // Why: The safety is Foundation's (symlinks are not resolved, `contentsOfDirectory` is empty); the guard logs and pins that.
    // It is not a symlink-escape fix: refuse symlinks at install time.
    /// Lists valid resource files in a subdirectory, excluding hidden files, symlinks and directories.
    /// The symlink check is defence in depth and a log line: Foundation already returns nothing for a symlinked directory.
    private static func validFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let dirValues = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else { return [] }
        guard dirValues.isSymbolicLink != true else {
            logger.notice("[SKILL_SCAN] Resource subdirectory '\(dir.lastPathComponent)' in '\(dir.deletingLastPathComponent().lastPathComponent)' is a SYMLINK and is not traversed. CONSEQUENCE: it contributes no resources — which is what already happened silently, since contentsOfDirectory does not follow a symlinked directory. Replace the symlink with a real directory if those files are meant to ship with the skill.")
            return []
        }
        guard dirValues.isDirectory == true else { return [] }
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        return files.filter { url in
            // Skip hidden files (.DS_Store, .gitkeep, etc.)
            guard !url.lastPathComponent.hasPrefix(".") else { return false }
            // Skip symlinks and directories — only regular files
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return false }
            return true
        }
    }

    /// Counts total resource files across reference/, templates/, and scripts/ subdirectories.
    private static func countResources(in folder: URL) -> Int {
        let subdirs = ["reference", "references", "templates", "scripts", "assets"]
        return subdirs.reduce(0) { count, subdir in
            count + validFiles(in: folder.appendingPathComponent(subdir)).count
        }
    }

    /// Checks whether the skill has any executable script files.
    private static func hasScriptFiles(in folder: URL) -> Bool {
        !validFiles(in: folder.appendingPathComponent("scripts")).isEmpty
    }

    // Why: `SkillMaterializer.write` is the only place a name becomes a filesystem path.
    /// Validates a skill name's shape only, with no directory-equality requirement; callers validate before building a path.
    /// The charset (lowercase letters, digits, hyphens) makes `/`, `.` and `..` unrepresentable, so traversal cannot be
    /// expressed.
    @discardableResult
    static func validateSkillNameShape(_ name: String) throws -> String {
        // The limit comes from `SkillLibraryLimits`, not a literal, so there is one definition of the rule.
        guard name.count <= SkillLibraryLimits.maxNameChars else {
            throw SkillParseError.invalidName("Name exceeds \(SkillLibraryLimits.maxNameChars) characters")
        }
        guard !name.isEmpty else {
            throw SkillParseError.invalidName("Name cannot be empty")
        }
        let allowedChars = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        guard name.unicodeScalars.allSatisfy({ allowedChars.contains($0) }) else {
            throw SkillParseError.invalidName("Name must be lowercase alphanumeric + hyphens only")
        }
        guard !name.hasPrefix("-"), !name.hasSuffix("-") else {
            throw SkillParseError.invalidName("Name must not start or end with a hyphen")
        }
        guard !name.contains("--") else {
            throw SkillParseError.invalidName("Name must not contain consecutive hyphens")
        }
        return name
    }

}

// MARK: - YAML Frontmatter Parser

/// Parses the YAML frontmatter of a SKILL.md: flat key-values, block scalars (`>` and `|`), quoted scalars, continuations
/// and one-level sequences (block `- item` and flow `[a, b]`).
/// Not a full YAML parser (no nested maps, anchors or escapes) and total: unrecognised constructs degrade to a scalar.
enum YAMLFrontmatterParser {

    struct Frontmatter {
        let name: String
        let description: String

        /// Every field as a SCALAR. A sequence-valued field appears here too, joined with `", "`,
        /// so a caller that only wants to show the value never has to know which spelling the
        /// author used.
        let additionalFields: [String: String]

        /// Sequence-valued fields with their elements preserved.
        /// Separate from `additionalFields` because joining is lossy: `["Read, write"]` and `["Read", "write"]` join alike.
        /// Anything that addresses elements individually (`allowed-tools`) must read this.
        let listFields: [String: [String]]

        /// Reads a field as a list of elements, whichever YAML spelling produced it.
        /// Accepts block sequences, flow sequences and a plain comma-separated scalar (`allowed-tools: Read, Grep`).
        /// The comma scalar is not YAML but is what authors write; reading it as one tool would silently misparse.
        func list(_ key: String) -> [String]? {
            if let elements = listFields[key] { return elements }
            guard let scalar = additionalFields[key] else { return nil }
            let parts = splitTopLevel(scalar).map(unquote)
            return parts.isEmpty ? nil : parts
        }
    }

    static func parse(from content: String) throws -> Frontmatter {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { throw SkillParseError.noFrontmatter }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw SkillParseError.unclosedFrontmatter
        }

        let yamlLines = Array(lines[1..<closingIndex])
        var fields: [String: String] = [:]
        var lists: [String: [String]] = [:]
        var currentKey: String?
        var currentValue: String = ""
        var currentList: [String] = []
        // Why: Without it a folded description starting with a dash would be read as a block sequence.
        /// True while the open key was introduced with an explicit block-scalar indicator (`>` or `|`).
        var currentIsBlockScalar = false
        // Why: Tracked separately from `currentList.isEmpty`: `allowed-tools: []` (needs no tools) must not collapse into an absent
        // key.
        /// Whether the open key was written as a sequence at all.
        var currentIsSequence = false

        func flush() {
            guard let key = currentKey else { return }
            if currentIsSequence {
                lists[key] = currentList
                fields[key] = currentList.joined(separator: ", ")
            } else {
                fields[key] = currentValue.trimmingCharacters(in: .whitespaces)
            }
        }

        for line in yamlLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // A block-sequence item at any indentation, including flush-left `- Read`, which matches neither the continuation
            // branch nor `findFieldSeparator` and would otherwise vanish.
            if currentKey != nil, !currentIsBlockScalar, currentValue.isEmpty,
               trimmed == "-" || trimmed.hasPrefix("- ") {
                currentIsSequence = true
                let element = unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                if !element.isEmpty { currentList.append(element) }
                continue
            }

            if line.hasPrefix("  ") && currentKey != nil && !currentIsSequence {
                // Continuation line — append to current key's value.
                currentValue += " " + trimmed
            } else if let fieldSeparator = findFieldSeparator(in: line) {
                // New key-value pair — save previous if exists.
                flush()
                currentList = []
                currentIsSequence = false
                currentKey = String(line[line.startIndex..<fieldSeparator]).trimmingCharacters(in: .whitespaces)
                let afterColon = String(line[line.index(after: fieldSeparator)...]).trimmingCharacters(in: .whitespaces)

                // `|` joins `>` here: a literal block is folded rather than newline-preserving, which is harmless since consumers
                // collapse newlines anyway (`SkillDiscoveryRendering`).
                currentIsBlockScalar = (afterColon == ">" || afterColon == "|")
                if currentIsBlockScalar {
                    currentValue = ""
                } else if let flow = parseFlowSequence(afterColon) {
                    currentList = flow
                    currentIsSequence = true
                    currentValue = ""
                } else {
                    currentValue = unquote(afterColon)
                }
            }
        }
        flush()

        guard let name = fields["name"], !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParseError.missingRequiredField("description")
        }

        return Frontmatter(name: name, description: description, additionalFields: fields, listFields: lists)
    }

    // Why: Keep the `''` collapse in step with `SkillMaterializer.yamlScalar`, or an export-then-import corrupts apostrophes.
    /// Strips one layer of matching surrounding quotes.
    /// The `''` collapse mirrors `SkillMaterializer.yamlScalar`, which doubles apostrophes in single-quoted scalars;
    /// double-quoted scalars get no escape processing.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        guard let first = value.first, let last = value.last, first == last,
              first == "\"" || first == "'" else { return value }
        let inner = String(value.dropFirst().dropLast())
        // Applies only INSIDE a single-quoted scalar, which is YAML's own rule — an unquoted value
        // containing `''` is left exactly as written.
        guard first == "'" else { return inner }
        return inner.replacingOccurrences(of: "''", with: "'")
    }

    /// Parses a YAML flow sequence (`[a, b]`), returning nil when the value is not one.
    /// Returns an empty array for `[]`, which differs from nil: `allowed-tools: []` declares that no tools are needed.
    private static func parseFlowSequence(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 else { return nil }
        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return splitTopLevel(inner).map(unquote)
    }

    /// Splits on commas that are not inside parentheses, brackets, braces or quotes, so `Bash(git add:*, git commit:*)`
    /// stays whole.
    /// Depth-counted, never throws on unbalanced input: an unclosed `(` makes the remainder one element.
    static func splitTopLevel(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in value {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Finds the YAML field separator colon: one whose key part is a simple bare word.
    /// This keeps colons inside values (e.g. URLs) from being read as separators.
    private static func findFieldSeparator(in line: String) -> String.Index? {
        // Skip indented lines (handled as continuation)
        guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { return nil }
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }

        // The key (before the colon) must be a simple identifier: letters, digits, hyphens, underscores
        let key = line[line.startIndex..<colonIndex]
        guard !key.isEmpty else { return nil }
        let keyAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard key.unicodeScalars.allSatisfy({ keyAllowed.contains($0) }) else { return nil }

        return colonIndex
    }
}
