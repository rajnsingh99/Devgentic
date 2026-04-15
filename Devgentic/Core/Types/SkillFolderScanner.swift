//
//  SkillFolderScanner.swift
//  Devgentic
//
//  Scans a skill folder on disk, parses YAML frontmatter from SKILL.md files,
//  and loads full skill packages on demand.
//  Spec: https://agentskills.io/specification
//

import Foundation

// MARK: - Skill Folder Scanner

enum SkillFolderScanner {

    /// Scans a root skill folder and returns manifests for each valid skill subdirectory.
    /// A valid skill subdirectory contains a `SKILL.md` file with proper YAML frontmatter.
    static func scan(rootFolder: URL) throws -> [SkillManifest] {
        try scanDetailed(rootFolder: rootFolder).manifests
    }

    /// Detailed scan that returns accepted manifests + skipped entries with reasons.
    /// Handles two import modes:
    /// - **Multi-skill folder**: Root contains skill subdirectories (e.g. `skills/`)
    /// - **Single-skill folder**: Root itself contains a SKILL.md (e.g. `skills/algorithmic-art/`)
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

        // Multi-skill folder: scan child directories
        let subdirs = try fm.contentsOfDirectory(at: rootFolder, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        var manifests: [SkillManifest] = []
        var skipped: [SkippedSkillEntry] = []

        for dir in subdirs {
            let dirName = dir.lastPathComponent
            let skillFile = dir.appendingPathComponent("SKILL.md")

            guard fm.fileExists(atPath: skillFile.path) else {
                skipped.append(SkippedSkillEntry(directoryName: dirName, reason: .noSkillFile))
                continue
            }

            do {
                let manifest = try parseManifest(from: skillFile, folderPath: dir.path)
                manifests.append(manifest)
            } catch {
                skipped.append(SkippedSkillEntry(directoryName: dirName, reason: .parseError(error.localizedDescription)))
            }
        }

        return SkillScanResult(manifests: manifests, skipped: skipped, totalSubdirectories: subdirs.count, isSingleSkillImport: false)
    }

    /// Parses a single SKILL.md file into a lightweight manifest.
    /// Validates the skill name per the agentskills.io specification.
    static func parseManifest(from skillFile: URL, folderPath: String) throws -> SkillManifest {
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let frontmatter = try YAMLFrontmatterParser.parse(from: content)
        let folderURL = URL(fileURLWithPath: folderPath)
        let resourceCount = countResources(in: folderURL)
        let hasScripts = hasScriptFiles(in: folderURL)
        let directoryName = folderURL.lastPathComponent

        return SkillManifest(
            id: UUID(),
            name: try validateSkillName(frontmatter.name, directoryName: directoryName),
            description: frontmatter.description,
            folderPath: folderPath,
            resourceCount: resourceCount,
            hasScripts: hasScripts,
            compatibility: frontmatter.additionalFields["compatibility"],
            isEnabled: true
        )
    }

    /// Loads the full skill package (body + resources) from disk.
    /// Called at runtime by `LoadSkillTool` — never cached, always reads fresh from disk.
    static func loadFullPackage(for manifest: SkillManifest) throws -> SkillPackage {
        let skillFile = URL(fileURLWithPath: manifest.folderPath).appendingPathComponent("SKILL.md")
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let body = extractBody(from: content)
        let resources = try loadResources(from: URL(fileURLWithPath: manifest.folderPath))
        return SkillPackage(manifest: manifest, body: body, resources: resources)
    }

    // MARK: - Private Helpers

    /// Extracts the markdown body from SKILL.md content (everything after the closing `---` of frontmatter).
    private static func extractBody(from content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { return content }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else { return content }
        return lines[(closingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Maximum file size (in bytes) for a single resource file. Files larger than this are skipped.
    private static let maxResourceFileSize: Int = 10 * 1024 * 1024 // 10 MB

    /// Lists valid resource files in a subdirectory (excluding hidden files, symlinks, directories).
    private static func validFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
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

    /// Loads all resource files from known subdirectories as `SkillResource` entries.
    /// Skips binary files (non-UTF-8), hidden files, symlinks, and files exceeding size limit.
    private static func loadResources(from folder: URL) throws -> [SkillResource] {
        let fm = FileManager.default
        let subdirTypes: [(String, SkillResourceType)] = [
            ("reference", .reference),
            ("references", .reference),
            ("templates", .template),
            ("scripts", .script),
            ("assets", .other)
        ]
        var resources: [SkillResource] = []
        for (subdir, type) in subdirTypes {
            let dir = folder.appendingPathComponent(subdir)
            for file in validFiles(in: dir) {
                // Skip files exceeding size limit
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let size = attrs[.size] as? Int, size > maxResourceFileSize {
                    continue
                }
                // Skip binary/non-UTF-8 files gracefully
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
                resources.append(SkillResource(
                    relativePath: "\(subdir)/\(file.lastPathComponent)",
                    content: content,
                    type: type
                ))
            }
        }
        return resources
    }

    /// Validates a skill name per the agentskills.io specification:
    /// - Max 64 chars, lowercase alphanumeric + hyphens only
    /// - Must not start/end with hyphen, no consecutive hyphens
    /// - Must match the parent directory name
    private static func validateSkillName(_ name: String, directoryName: String) throws -> String {
        guard name.count <= 64 else {
            throw SkillParseError.invalidName("Name exceeds 64 characters")
        }
        guard !name.isEmpty else {
            throw SkillParseError.invalidName("Name cannot be empty")
        }

        // Lowercase alphanumeric and hyphens only, no leading/trailing hyphens
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
        guard name == directoryName else {
            throw SkillParseError.invalidName("Name '\(name)' must match directory name '\(directoryName)'")
        }
        return name
    }
}

// MARK: - YAML Frontmatter Parser

/// Parses the YAML frontmatter block from a SKILL.md file.
/// Handles flat key-value pairs and single-level continuation lines (via `>`).
/// Does NOT support nested YAML, arrays, or complex scalars — sufficient for
/// the agentskills.io spec's required fields (name, description) and useful
/// optional fields (license, compatibility, allowed-tools).
enum YAMLFrontmatterParser {

    struct Frontmatter {
        let name: String
        let description: String
        let additionalFields: [String: String]
    }

    static func parse(from content: String) throws -> Frontmatter {
        let lines = content.components(separatedBy: "\n")
        guard lines.first == "---" else { throw SkillParseError.noFrontmatter }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw SkillParseError.unclosedFrontmatter
        }

        let yamlLines = Array(lines[1..<closingIndex])
        var fields: [String: String] = [:]
        var currentKey: String?
        var currentValue: String = ""

        for line in yamlLines {
            if line.hasPrefix("  ") && currentKey != nil {
                // Continuation line — append to current key's value
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let fieldSeparator = findFieldSeparator(in: line) {
                // New key-value pair — save previous if exists
                if let key = currentKey {
                    fields[key] = currentValue.trimmingCharacters(in: .whitespaces)
                }
                currentKey = String(line[line.startIndex..<fieldSeparator]).trimmingCharacters(in: .whitespaces)
                let afterColon = String(line[line.index(after: fieldSeparator)...]).trimmingCharacters(in: .whitespaces)
                // Handle block scalar indicator (>)
                currentValue = afterColon == ">" ? "" : afterColon
            }
        }
        // Save the last key-value pair
        if let key = currentKey {
            fields[key] = currentValue.trimmingCharacters(in: .whitespaces)
        }

        guard let name = fields["name"], !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParseError.missingRequiredField("description")
        }

        return Frontmatter(name: name, description: description, additionalFields: fields)
    }

    /// Finds the YAML field separator colon in a line.
    /// A valid field separator is a colon where the key portion (before the colon) is a
    /// simple bare word (no spaces, no special chars). This prevents colons inside values
    /// (e.g., URLs like "https://example.com") from being misinterpreted as field separators.
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
