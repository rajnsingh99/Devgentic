// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillModels.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Skill Manifest (Discovery Layer)

/// Lightweight metadata for a single skill — always in context for LLM routing.
/// The full skill body is loaded on demand via `LoadSkillTool`.
struct SkillManifest: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let name: String              // From YAML frontmatter — validated per agentskills.io spec
    let description: String       // From YAML frontmatter — used for LLM routing
    /// A filesystem path only while a folder is scanned for ingest; at run time it carries the skill's opaque
    /// id (`skill_...`), set by `SkillResolution.manifest(for:version:)`.
    let folderPath: String
    let resourceCount: Int        // Number of files in reference/ + templates/ + scripts/
    let hasScripts: Bool          // true if scripts/ subdirectory contains any files
    let compatibility: String?    // Optional — environment requirements (e.g. "Requires Python 3.14+")
    var isEnabled: Bool           // User-togglable: controls whether this skill appears in discovery layer

    /// The skill author's `allowed-tools` declaration, verbatim from the frontmatter; nil means the field was absent.
    /// Not a permission grant or gate, and never translated to native tool names; `SkillToolDeclaration` classifies it.
    /// `[]` means the author declared that the skill needs no tools.
    var allowedTools: [String]?

    /// The library version this manifest was resolved from; nil only for a manifest parsed from a folder during ingest.
    /// Lets `LoadSkillTool` fetch the exact snapshot resolved, including a pinned one.
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
    /// Display metadata only; paths outside the known prefixes are `.other`, not refused.
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

// MARK: - Skill Selection (what a profile stores about one skill)

/// A profile's reference to one library skill: an opaque id, plus the two preferences the profile owns.
/// Not a copy of the skill: the library is authoritative for `description` and every other derived field.
struct SkillSelection: Codable, Hashable, Sendable, Identifiable {

    /// The library skill this points at.
    let skillID: String

    /// Last-known name. Denormalized for two reasons, neither of which is authority: an unresolvable
    /// selection renders as a NAMED, removable row instead of a bare id, and it can be reported
    /// without a store round-trip. The library wins whenever both are present.
    let name: String

    /// Which version this profile reads; nil follows `latest`.
    /// Pinning lets one agent keep a known-good skill while `update_skill` moves everyone else forward.
    var pinnedVersionID: String?

    /// The other thing the profile owns.
    var isEnabled: Bool

    /// Identity is the skill ID, defined on the type so no call site can key on the wrong field.
    var id: String { skillID }

    init(
        skillID: String,
        name: String,
        pinnedVersionID: String? = nil,
        isEnabled: Bool = true
    ) {
        self.skillID = skillID
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
        SkillSelection(skillID: skillID, name: name,
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
