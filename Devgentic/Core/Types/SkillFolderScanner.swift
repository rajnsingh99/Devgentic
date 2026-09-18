// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillFolderScanner.swift
//  Devgentic
//
//  Scans a skill folder on disk, parses YAML frontmatter from SKILL.md files,
//  and loads full skill packages on demand.
//  Spec: https://agentskills.io/specification
//

import Foundation
import OSLog

private let logger = DGLogger(category: "SkillFolderScanner")

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

        // Multi-skill folder: bounded recursive walk.
        //
        // ⚠️ RECURSIVE SINCE 2026-09-14, and the previous depth-1 rule was the single biggest
        // usability gap in the feature. The layout Anthropic's own plugins ship — and the one a user
        // gets by cloning any skills repository — is `repo/skills/<name>/SKILL.md`. Under depth-1
        // that imported as ZERO skills plus one "No SKILL.md file" skip for `skills/`, which reads
        // as "this repo has no skills in it".
        //
        // The walk is general rather than a hardcoded `skills/` + `plugins/` special case, because
        // every layout this app has been shown so far was someone's convention rather than a spec.
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
                    // ⚠️ Symlinked directories are not followed. A walk that follows them can cycle,
                    // and it can leave the folder the user actually chose.
                    return values.isDirectory == true && values.isSymbolicLink != true
                }
                // ⚠️ SORTED, so an import is deterministic: `contentsOfDirectory` returns filesystem
                // order, which is neither alphabetical nor stable across machines, and that would
                // otherwise decide which of two same-named skills wins a collision.
                //
                // ⚠️ It no longer decides PROMPT order — an earlier version of this note claimed it
                // did. `SkillResolution` sorts by name immediately before rendering ("this becomes
                // prompt bytes"), so that guarantee is owned there. Two places claiming the same
                // guarantee is how one of them stops being true without anyone noticing.
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
                // ⚠️ A directory that IS a skill is never descended into. Its `reference/`,
                // `scripts/` and `assets/` are resources, not nested skills — and this is also what
                // keeps the walk naturally bounded on real skill folders.
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
            // Report a top-level child as skipped only when its WHOLE subtree yielded nothing —
            // otherwise `skills/` would be listed as "No SKILL.md file" while contributing every
            // skill in the import.
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

    /// How deep below the chosen folder a skill may sit.
    ///
    /// 4 covers every layout seen in the wild with room to spare: `<skill>/` (1),
    /// `skills/<skill>/` (2), `plugins/<plugin>/skills/<skill>/` (4). It is a bound on a walk over a
    /// user-chosen directory, not a statement about what is legal — the cost of being wrong is an
    /// unbounded traversal of someone's home folder.
    static let maxScanDepth = 4

    /// Hard ceiling on directories examined in one scan.
    ///
    /// ⚠️ Not a nicety. The user picks this folder with an open panel, and picking a source checkout
    /// or a home directory is an ordinary mistake. Without a cap the scan walks it all, on the main
    /// actor, with no way to stop. Hitting the cap is LOGGED rather than silently truncated — a scan
    /// that quietly stopped halfway would look like "this repo only has three skills".
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
            // ⚠️ SHAPE ONLY — the "name must equal its folder name" rule was DROPPED 2026-09-14.
            //
            // It came from the agentskills.io spec, and it made sense while a folder path WAS the
            // skill's identity: two skills in one directory, or a folder whose name disagreed with
            // the manifest, broke the key. Under the V6 library identity is an opaque `skill_…` and
            // the folder is a transport detail discarded at ingest, so the rule bought nothing and
            // cost real imports — Anthropic's own Skills API requires only that SKILL.md sit at the
            // root or in a top-level folder, so `my-skill-v2/SKILL.md` declaring `name: my-skill`
            // is a valid package there and was refused here.
            //
            // The SHAPE check stays and is the one that matters: lowercase letters, digits and
            // hyphens make `/`, `.` and `..` unrepresentable, so a name from an untrusted archive
            // cannot become a path traversal.
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

    /// Loads the full skill package (body + resources) from disk.
    /// Called at runtime by `LoadSkillTool` — never cached, always reads fresh from disk.
    static func loadFullPackage(for manifest: SkillManifest) throws -> SkillPackage {
        let skillFile = URL(fileURLWithPath: manifest.folderPath).appendingPathComponent("SKILL.md")
        let content = try String(contentsOf: skillFile, encoding: .utf8)
        let body = extractBody(from: content)
        let resources = try loadResources(from: URL(fileURLWithPath: manifest.folderPath))

        // ⚠️ `try?`, and the swallow is deliberate. A frontmatter that no longer parses must NOT
        // take the body down with it.
        //
        // ⚠️ This whole function is the LEGACY arm now — `LoadSkillTool` reaches it only for a
        // manifest with no `versionID`, i.e. one from a pre-library profile blob. The library path
        // reads `SkillVersionSD` and never touches disk. The user
        // edited their SKILL.md and broke a colon; the instructions are still there and still
        // loadable, and refusing the whole skill over a metadata line would be the app deciding a
        // recoverable problem is fatal. The declaration simply reads as absent, and the scan that
        // populates the library reports the parse error where the user can act on it.
        let declared = (try? YAMLFrontmatterParser.parse(from: content))?.list("allowed-tools")
        if declared == nil, manifest.allowedTools != nil {
            logger.notice("[SKILL_LOAD] Skill '\(manifest.name)' declared allowed-tools when it was scanned but its frontmatter no longer parses that field. CONSEQUENCE: the body still loads and the run is unaffected — only the declaration shown alongside it is missing. Re-check the frontmatter in \(skillFile.path).")
        }

        return SkillPackage(manifest: manifest, body: body, resources: resources)
    }

    // MARK: - Private Helpers

    /// Extracts the markdown body from SKILL.md content.
    ///
    /// ⚠️ DELEGATES. This used to be its own copy of the split rule, and `SkillIngest` claimed to be
    /// "the one that remains" while this one was still live on the legacy load path — a comment
    /// asserting an invariant the code did not hold. One implementation, so a split can never
    /// disagree with itself about where the frontmatter ends.
    private static func extractBody(from content: String) -> String {
        SkillBodyExtraction.body(of: content)
    }

    /// Maximum file size (in bytes) for a single resource file. Files larger than this are skipped.
    private static let maxResourceFileSize: Int = 10 * 1024 * 1024 // 10 MB

    /// Lists valid resource files in a subdirectory (excluding hidden files, symlinks, directories).
    ///
    /// ## The subdirectory check is defence-in-depth and a LOG, not a vulnerability fix
    ///
    /// It looks like a symlinked resource directory (`reference -> ~/.ssh`) would be followed and
    /// its contents read into the model's context. **It is not, and it never was** — verified on
    /// macOS 26, Foundation:
    ///
    ///   - `URL.resourceValues(forKeys: [.isDirectoryKey])` does NOT resolve a symlink:
    ///     a symlink to a directory reports `isDirectory == false`, `isSymbolicLink == true`.
    ///   - `FileManager.contentsOfDirectory(at:)` on that URL returns ZERO entries rather than the
    ///     target's contents.
    ///
    /// So both the enumeration above and this function already came back empty. The guard below
    /// changes no outcome; it is here for two reasons only, and neither is "closes a hole":
    ///
    ///   1. **It says so out loud.** Without it, a user whose skill legitimately symlinks its
    ///      `reference/` directory gets zero resources, silently, with nothing in the log to
    ///      explain why. That is the silent-skip shape this codebase logs everywhere else.
    ///   2. **It pins the assumption.** The safety here is Foundation's, not ours. If that
    ///      behaviour ever changes, or if this function is rewritten onto an API that does follow
    ///      symlinks (`enumerator(at:)` with different options, or a raw `opendir`), the guard is
    ///      already in place and the characterization tests in
    ///      `SkillFolderScannerHygieneTests` say what is being relied on.
    ///
    /// ⚠️ Do not read this as "symlink escape is handled". A skill package that ships a symlink is
    /// still worth refusing at INSTALL time, where the file is written — see the zip-install work.
    /// A guard here is a guard on this one read path, not on the capability.
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

    /// Validates a skill name's SHAPE only — no directory-equality requirement.
    ///
    /// ⚠️ Split out so a caller that has a name but no directory yet can validate BEFORE building a
    /// path from it. The importer used to need exactly that — it derived a directory name from an
    /// untrusted archive's frontmatter, and without this check a `name` of `../../../victim` became
    /// a real path that reached `removeItem`. That code is gone with the promote half; the live
    /// callers are `SkillIngest.parse`, `SkillCreateSheet`, and `SkillMaterializer.write`, which is
    /// now the only place a name becomes a filesystem path. The charset below — lowercase letters, digits and
    /// hyphens — is what makes `/`, `.` and `..` unrepresentable, so traversal cannot be expressed
    /// rather than having to be filtered.
    @discardableResult
    static func validateSkillNameShape(_ name: String) throws -> String {
        // ⚠️ The limit comes from `SkillLibraryLimits`, not a literal. It was declared there and
        // enforced here with a hardcoded 64 — two definitions of one rule, and the kind that drifts
        // silently because the constant had no readers to fail when it changed.
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

/// Parses the YAML frontmatter block from a SKILL.md file.
///
/// Handles flat key-value pairs, folded/literal block scalars (`>` and `|`), single-level
/// continuation lines, single-quoted and double-quoted scalars, and one-level SEQUENCES in both
/// spellings — block (`- item`) and flow (`[a, b]`).
///
/// ⚠️ Still NOT a YAML parser. No nested maps, no anchors, no multi-document, no escape processing
/// inside quoted scalars, and a literal block (`|`) is FOLDED rather than newline-preserving. It
/// covers the agentskills.io spec's required fields (name, description) and the optional ones that
/// carry meaning here (license, compatibility, allowed-tools) — and it is deliberately total: an
/// unrecognised construct degrades to a scalar rather than throwing, because refusing to import a
/// skill over a frontmatter nicety is worse than importing it with one field read loosely.
enum YAMLFrontmatterParser {

    struct Frontmatter {
        let name: String
        let description: String

        /// Every field as a SCALAR. A sequence-valued field appears here too, joined with `", "`,
        /// so a caller that only wants to show the value never has to know which spelling the
        /// author used.
        let additionalFields: [String: String]

        /// Sequence-valued fields with their elements preserved.
        ///
        /// ⚠️ Kept SEPARATE from `additionalFields` rather than replacing it, because joining is
        /// lossy in one direction only: `["Read, write"]` and `["Read", "write"]` join to the same
        /// string. Anything that must address elements individually — `allowed-tools` does, it is
        /// matched against tool names — has to read this.
        let listFields: [String: [String]]

        /// Reads a field as a list of elements, whichever YAML spelling produced it.
        ///
        /// Accepts all three shapes a skill author plausibly writes:
        ///   - block sequence   `allowed-tools:\n  - Read\n  - Grep`
        ///   - flow sequence    `allowed-tools: [Read, Grep]`
        ///   - comma scalar     `allowed-tools: Read, Grep`
        ///
        /// The third is not a YAML list at all — it is one scalar string — but it is what people
        /// write, and reading it as a single tool named "Read, Grep" would be a silent
        /// misparse rather than an error anyone could see.
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
        /// True while the open key was introduced with an explicit block-scalar indicator
        /// (`>` or `|`). ⚠️ Load-bearing: without it a folded description whose first line begins
        /// with a dash — an ordinary bulleted description — would be read as a block SEQUENCE and
        /// the prose would silently become a list. See `testAFoldedDescriptionOfBulletsIsNotAList`.
        var currentIsBlockScalar = false
        /// Whether the open key was written as a SEQUENCE at all.
        ///
        /// ⚠️ Tracked separately from `currentList.isEmpty`, and the difference is the whole point.
        /// `allowed-tools: []` is an author saying "this skill needs no tools"; an absent key is an
        /// author saying nothing. Keying the flush on emptiness collapses the first into the second
        /// — the list never lands in `lists`, `list()` falls through to comma-splitting `""`, and
        /// the declaration reads as absent. That inverts an explicit statement into silence, which
        /// is the one direction this parser must never fail in.
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

            // A block-sequence item, at ANY indentation.
            //
            // ⚠️ Zero-indent items (`- Read` flush left) used to be dropped on the floor: they
            // match neither the continuation branch (no leading spaces) nor `findFieldSeparator`
            // (no colon), so the whole list vanished and the key parsed as empty. That is the
            // shape GitHub's own YAML examples use, so it was the common case, not an edge one.
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

                // ⚠️ `|` joins `>` here. It was previously unhandled, so `description: |` parsed as
                // the literal value "|" and every following line was appended to it — the prompt
                // got `| Line one. Line two.` with a stray pipe at the front. Folding a literal
                // block rather than preserving its newlines is deliberate: every consumer of these
                // values collapses newlines anyway (`SkillDiscoveryRendering`), so the distinction
                // has no observable effect beyond that leading character.
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

    /// Strips ONE layer of matching surrounding quotes.
    ///
    /// ⚠️ `name: "code-review"` used to be REJECTED at import: the quotes survived into the value,
    /// and `validateSkillNameShape` refuses anything outside `[a-z0-9-]`, so a perfectly valid quoted
    /// skill failed with "Name must be lowercase alphanumeric + hyphens only" — an error message
    /// pointing at the wrong thing entirely. Quoting a scalar is ordinary YAML and mandatory for
    /// values starting with `[`, `{`, `*`, `&`, or `%`.
    ///
    /// ⚠️⚠️ THE `''` COLLAPSE IS ONE HALF OF AN ENCODING — it must stay in step with
    /// `SkillMaterializer.yamlScalar`, which emits single-quoted scalars and doubles every
    /// apostrophe inside one. Shipping either half alone CREATES a corruption rather than fixing
    /// one: without this collapse, exporting `Reviews the user's code` and re-importing it yields
    /// `the user''s code`.
    ///
    /// It is also plain YAML — `''` is exactly how a single-quoted scalar spells one quote — so a
    /// third-party SKILL.md that already used it was being misread before this.
    ///
    /// ⚠️ DOUBLE-quoted scalars still get NO escape processing: `\"` and `\\` stay literal. That gap
    /// is deliberate and separate. Closing it correctly would mean making the `first == last` strip
    /// above an escape-aware scan — `"He said \""` currently loses its final character — and this
    /// app no longer emits that shape, so the gap only affects hand-written frontmatter.
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

    /// Parses a YAML flow sequence — `[a, b]` — returning nil when the value is not one.
    ///
    /// Returns an EMPTY array for `[]`, which is meaningfully different from nil: `allowed-tools: []`
    /// is an author saying "this skill needs no tools", and collapsing that to "unspecified" would
    /// invert the declaration.
    private static func parseFlowSequence(_ value: String) -> [String]? {
        guard value.hasPrefix("["), value.hasSuffix("]"), value.count >= 2 else { return nil }
        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return [] }
        return splitTopLevel(inner).map(unquote)
    }

    /// Splits on commas that are NOT inside parentheses, brackets, braces or quotes.
    ///
    /// ⚠️ Naive `split(separator: ",")` was wrong for the one field this parser exists to read.
    /// Real `allowed-tools` declarations carry SCOPED forms — `Bash(git add:*, git commit:*)` — and
    /// splitting them on every comma produces two fragments that are not tools and match nothing:
    /// `Bash(git add:*` and `git commit:*)`. Both would then be shown to the user as things the
    /// skill declared, which is a misquote of their own file.
    ///
    /// Depth-counted rather than regex-matched, and it never throws on unbalanced input: an
    /// unclosed `(` simply means the remainder is one element. A frontmatter typo must degrade to
    /// a slightly-wrong reading, never to a refused import.
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
