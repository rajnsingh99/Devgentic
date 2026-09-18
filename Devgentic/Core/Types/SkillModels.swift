// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillModels.swift
//  Devgentic
//
//  Data models for the Skills system.
//  Skills are on-demand task-specific knowledge packages loaded via the `load_skill` tool.
//  Spec: https://agentskills.io/specification
//

import Foundation

// MARK: - Skill Manifest (Discovery Layer)

/// Lightweight metadata for a single skill — always in context for LLM routing.
/// The full skill body is loaded on demand via `LoadSkillTool`.
struct SkillManifest: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let name: String              // From YAML frontmatter — validated per agentskills.io spec
    let description: String       // From YAML frontmatter — used for LLM routing
    /// ⚠️ NOT A PATH AT RUN TIME. On the library path this carries the skill's opaque id
    /// (`skill_…`), set by `SkillResolution.manifest(for:version:)`; it is a real filesystem path
    /// only on the LEGACY arm. Believing the old comment here — "absolute path to skill
    /// subdirectory" — is what produced a `load_skill` that tried to open `skill_<uuid>/SKILL.md`
    /// and failed on every call. `versionID` below is how a reader tells the two apart.
    let folderPath: String
    let resourceCount: Int        // Number of files in reference/ + templates/ + scripts/
    let hasScripts: Bool          // true if scripts/ subdirectory contains any files
    let compatibility: String?    // Optional — environment requirements (e.g. "Requires Python 3.14+")
    var isEnabled: Bool           // User-togglable: controls whether this skill appears in discovery layer

    /// The skill author's `allowed-tools` declaration, VERBATIM as written in the frontmatter.
    ///
    /// ⚠️ Three things this is NOT, each of which someone will assume:
    ///
    /// 1. **Not a permission grant, and not a permission gate.** Nothing consults this before
    ///    dispatching a tool call. It is the author's statement of what the skill needs, carried so
    ///    the user and the model can both see it. Gating on it would let an imported file switch
    ///    off tools the user deliberately enabled — see `SkillToolDeclaration` for the full
    ///    argument, and invariant 14.
    /// 2. **Not normalized, and never translated.** These are whatever names the author wrote —
    ///    usually Claude Code's (`Read`, `Bash`, `Grep`), which are not this app's tool names.
    ///    `SkillToolDeclaration` CLASSIFIES them against what this app knows and shows prose beside
    ///    the foreign ones; it never rewrites one into a native name, because the target depends on
    ///    the profile (`Bash` is `batch_command` in a Code profile, where `execute_shell` is not
    ///    even offered) and because a rewritten name hides the most useful fact about it — that it
    ///    came from somewhere else.
    /// 3. **Set on both paths now.** A manifest reaching a run is built by
    ///    `SkillResolution.manifest(for:version:)`, which carries the resolved version's
    ///    declaration. On the legacy arm it comes from `parseManifest` reading the file. (An earlier
    ///    version of this note said it was nil at run time and re-read from disk — true of the
    ///    retired registry, false since V6.)
    ///
    /// `nil` means the field was absent — the author said nothing. That is meaningfully different
    /// from `[]`, which is `allowed-tools: []`: an author saying the skill needs no tools at all.
    var allowedTools: [String]?

    /// The library version this manifest was resolved from, when it came from the library.
    ///
    /// ⚠️ THIS IS WHAT MAKES `load_skill` WORK, and its absence was a shipped break. `folderPath`
    /// carries a `skill_…` id at run time, not a path, so the disk loader silently became
    /// `String(contentsOf: "skill_abc/SKILL.md")` — every skill load failed. Carrying the version id
    /// lets `LoadSkillTool` fetch the exact snapshot that was resolved, including a PINNED one: the
    /// skill's latest version is not necessarily the version this profile reads.
    ///
    /// `nil` means the manifest came from the LEGACY blob, whose `folderPath` really is a path.
    /// That is the one remaining case the disk loader is for.
    var versionID: String?

}

// MARK: - Skill Package (Full — Loaded On Demand)

/// Complete skill payload returned by `LoadSkillTool`. Contains the full SKILL.md body
/// and optionally all bundled resources.
struct SkillPackage: Codable, Hashable, Sendable {
    let manifest: SkillManifest
    let body: String                        // Full SKILL.md content minus frontmatter
    let resources: [SkillResource]          // Parsed from reference/, templates/, scripts/


}

/// A single resource file bundled with a skill (reference doc, template, or script).
struct SkillResource: Codable, Hashable, Sendable {
    let relativePath: String                // e.g., "reference/editorial-checklist.md"
    let content: String
    let type: SkillResourceType
}

/// Categorizes skill resource files by their subdirectory.
enum SkillResourceType: String, Codable, Sendable {
    case reference      // .md, .txt files in reference/
    case template       // Files in templates/
    case script         // .py, .sh files in scripts/
    case other

    /// Classifies a stored file by its relative path.
    ///
    /// ⚠️ Display metadata only — nothing branches on this to decide what a file may do. Under V6 a
    /// skill's files live at arbitrary relative paths rather than in five fixed subdirectories, so
    /// anything outside the known prefixes is `.other` rather than being refused.
    static func forPath(_ relativePath: String) -> SkillResourceType {
        let first = relativePath.split(separator: "/").first.map(String.init) ?? ""
        switch first {
        case "reference", "references": return .reference
        case "templates": return .template
        case "scripts": return .script
        default: return .other
        }
    }
}

// MARK: - Skill Folder Configuration (Per-Profile Persistence)

/// ⚠️ LEGACY, READ-ONLY HISTORY. Nothing writes this any more — the profile editor stopped on
/// 2026-09-14 and skills live in the library. It is still DECODED, because a blob stamped v8+ that
/// carries it without `skillSelections` is the one case `SkillResolution`'s legacy arm serves, and
/// because `migrateToV8` derives selections from its manifests.
///
/// It described a per-profile mechanism: folder URLs plus a full copy of every scanned manifest,
/// encoded in the ProfileDetails blob. Five profiles using one folder meant five copies that could
/// disagree about a skill's description — which is why a profile now stores a reference instead.
struct SkillFolderConfig: Codable, Hashable, Sendable {
    /// All source folder URLs the user has imported.
    var folderURLs: [URL]
    var manifests: [SkillManifest]
    var lastScannedAt: Date

    /// Backward-compat: primary folder URL (first in the list).
    var folderURL: URL { folderURLs.first ?? URL(fileURLWithPath: "/") }

    init(folderURL: URL, manifests: [SkillManifest], lastScannedAt: Date) {
        self.folderURLs = [folderURL]
        self.manifests = manifests
        self.lastScannedAt = lastScannedAt
    }

    init(folderURLs: [URL], manifests: [SkillManifest], lastScannedAt: Date) {
        self.folderURLs = folderURLs
        self.manifests = manifests
        self.lastScannedAt = lastScannedAt
    }

    // Custom Codable for backward compat: decode old `folderURL` single field
    private enum CodingKeys: String, CodingKey {
        case folderURL, folderURLs, manifests, lastScannedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifests = try container.decode([SkillManifest].self, forKey: .manifests)
        lastScannedAt = try container.decode(Date.self, forKey: .lastScannedAt)

        // Try multi-folder first, fall back to legacy single-folder
        if let urls = try? container.decode([URL].self, forKey: .folderURLs) {
            folderURLs = urls
        } else if let url = try? container.decode(URL.self, forKey: .folderURL) {
            folderURLs = [url]
        } else {
            folderURLs = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folderURLs, forKey: .folderURLs)
        try container.encode(manifests, forKey: .manifests)
        try container.encode(lastScannedAt, forKey: .lastScannedAt)
    }
}

// MARK: - Skill Selection (what a profile stores about one skill)

/// A profile's reference to one library skill: an ADDRESS, plus the two preferences the profile owns.
///
/// ## Why this is an id and not a path (V6)
///
/// Until V6 this held a `folderPath`, because the skill registry keyed on one. That made identity a
/// statement about the world, and the world moves: rename a parent directory, relocate a repo,
/// unmount a volume, open the store on another machine, and every profile's link broke at once with
/// nothing the user could do but re-link by hand. The library now owns skill content and addresses
/// it by an opaque `skill_…` that describes nothing, so none of those events can break a reference.
///
/// ## Still deliberately NOT a copy of the skill
///
/// For skills the copy IS the payload: `description` is rendered verbatim into `<available_skills>`
/// and is what the model routes on. A stale copy does not sit inert — it routes the model on text
/// that no longer exists. `SkillFolderConfig.manifests` had exactly that problem: edit a SKILL.md
/// and only the profile that happened to Rescan saw it. The library is authoritative for every
/// disk-derived field; the profile supplies only the two below.
struct SkillSelection: Codable, Hashable, Sendable, Identifiable {

    /// The library skill this points at.
    ///
    /// ⚠️ OPTIONAL, and nil means exactly one thing: a selection carried over from a pre-V6 profile
    /// that has not been re-linked yet. A sentinel string would have been tidier to read and worse
    /// to reason about — every consumer would have to know the magic value, and one that forgot
    /// would treat it as a real id and resolve nothing, silently. `nil` cannot be mistaken for an id.
    let skillID: String?

    /// The folder this selection addressed before V6. **Migration input only.**
    ///
    /// ⚠️ Never consulted for resolution, and nothing may start doing so. It exists so the launch
    /// sweep can match a pre-V6 selection to the skill it ingested from that folder and write a real
    /// `skillID` back. Nil for anything created after V6.
    let legacyFolderPath: String?

    /// Last-known name. Denormalized for two reasons, neither of which is authority: an unresolvable
    /// selection renders as a NAMED, removable row instead of a bare id, and it can be reported
    /// without a store round-trip. The library wins whenever both are present.
    let name: String

    /// Which version this profile reads. **Nil means follow `latest`** — the common case.
    ///
    /// ⚠️ Present from the start rather than added when someone asks for it, because adding a field
    /// to this struct later is another profile-blob version and another migration. Pinning is the
    /// reason versions exist: it is what lets one agent keep a known-good skill while an
    /// `update_skill` write moves everyone else forward.
    var pinnedVersionID: String?

    /// The other thing the profile owns.
    var isEnabled: Bool

    /// ⚠️ Identity is the SKILL ID, on the type, so no call site can key on the wrong field. The
    /// `Tool.id { name }`-plus-separate-`sourceId` split is precisely the shape that once produced
    /// an invisible duplicate skill no UI could remove.
    ///
    /// A not-yet-re-linked selection still needs a stable identity for `ForEach`, so it falls back
    /// to its legacy path — prefixed, so it can never collide with a real `skill_…`.
    var id: String { skillID ?? "legacy:\(legacyFolderPath ?? name)" }

    /// True for a pre-V6 selection the launch sweep has not matched to a library skill yet.
    var isAwaitingRelink: Bool { skillID == nil }

    init(
        skillID: String?,
        legacyFolderPath: String? = nil,
        name: String,
        pinnedVersionID: String? = nil,
        isEnabled: Bool = true
    ) {
        self.skillID = skillID
        self.legacyFolderPath = legacyFolderPath
        self.name = name
        self.pinnedVersionID = pinnedVersionID
        self.isEnabled = isEnabled
    }

    /// The one constructor for linking a real library skill, so a default can be changed in one
    /// place and mutation-checked by flipping it and watching every path move.
    static func link(
        skillID: String,
        name: String,
        pinnedVersionID: String? = nil,
        isEnabled: Bool = true
    ) -> SkillSelection {
        SkillSelection(skillID: skillID, legacyFolderPath: nil, name: name,
                       pinnedVersionID: pinnedVersionID, isEnabled: isEnabled)
    }

    /// Returns a copy pointing at a library skill, preserving the user's own preferences.
    ///
    /// ⚠️ Keeps `isEnabled` and `pinnedVersionID`. Re-linking is a repair of an ADDRESS; silently
    /// re-enabling a skill the user had switched off, or dropping a pin they set, would make a
    /// repair look like a settings reset.
    func relinked(to skillID: String, name: String) -> SkillSelection {
        SkillSelection(skillID: skillID, legacyFolderPath: nil, name: name,
                       pinnedVersionID: pinnedVersionID, isEnabled: isEnabled)
    }
}

// MARK: - Errors


/// Errors encountered during skill parsing and validation.
enum SkillParseError: LocalizedError {
    case noFrontmatter
    case unclosedFrontmatter
    case missingRequiredField(String)
    case invalidName(String)
    case folderNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noFrontmatter:
            return "SKILL.md must start with YAML frontmatter (---)"
        case .unclosedFrontmatter:
            return "SKILL.md frontmatter is not closed (missing ---)"
        case .missingRequiredField(let field):
            return "SKILL.md missing required field: \(field)"
        case .invalidName(let reason):
            return "Invalid skill name: \(reason)"
        case .folderNotFound(let path):
            return "Skill folder not found: \(path)"
        }
    }
}

// MARK: - Scan Result (Detailed Feedback)

/// Detailed result from a skill folder scan, providing transparency on what was
/// accepted and what was skipped. Used by the UI to show scan feedback.
struct SkillScanResult: Sendable {
    let manifests: [SkillManifest]
    let skipped: [SkippedSkillEntry]
    let totalSubdirectories: Int
    let isSingleSkillImport: Bool

    init(manifests: [SkillManifest], skipped: [SkippedSkillEntry], totalSubdirectories: Int, isSingleSkillImport: Bool = false) {
        self.manifests = manifests
        self.skipped = skipped
        self.totalSubdirectories = totalSubdirectories
        self.isSingleSkillImport = isSingleSkillImport
    }


}

/// A subdirectory that was scanned but not accepted as a valid skill.
struct SkippedSkillEntry: Sendable {
    let directoryName: String
    let reason: SkipReason

    enum SkipReason: Sendable {
        case noSkillFile              // No SKILL.md found
        case parseError(String)       // SKILL.md exists but frontmatter is invalid

        var displayText: String {
            switch self {
            case .noSkillFile: return "No SKILL.md file"
            case .parseError(let detail): return detail
            }
        }
    }
}
