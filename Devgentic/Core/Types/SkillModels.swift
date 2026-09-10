// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
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
    let folderPath: String        // Absolute path to skill subdirectory
    let resourceCount: Int        // Number of files in reference/ + templates/ + scripts/
    let hasScripts: Bool          // true if scripts/ subdirectory contains any files
    let compatibility: String?    // Optional — environment requirements (e.g. "Requires Python 3.14+")
    var isEnabled: Bool           // User-togglable: controls whether this skill appears in discovery layer

    /// Rough token cost of the one-liner injected into system prompt (UI display only).
    /// Uses ~4 chars/token BPE average — acceptable for display, not for budget enforcement.
    var discoveryTokenCost: Int {
        (name.count + description.count) / 4
    }
}

// MARK: - Skill Package (Full — Loaded On Demand)

/// Complete skill payload returned by `LoadSkillTool`. Contains the full SKILL.md body
/// and optionally all bundled resources.
struct SkillPackage: Codable, Hashable, Sendable {
    let manifest: SkillManifest
    let body: String                        // Full SKILL.md content minus frontmatter
    let resources: [SkillResource]          // Parsed from reference/, templates/, scripts/

    var fullTokenCost: Int {
        (body.count + resources.reduce(0) { $0 + $1.content.count }) / 4
    }
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
}

// MARK: - Skill Folder Configuration (Per-Profile Persistence)

/// Ties skill folder(s) to an agent profile. Persisted as part of `AgentConfig`
/// via the SwiftData JSON blob — no separate persistence layer needed.
/// Supports multiple source folders merged into a single manifests list.
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

    var acceptedCount: Int { manifests.count }
    var skippedCount: Int { skipped.count }
    var isEmpty: Bool { manifests.isEmpty }

    /// Human-readable summary for the UI.
    var summary: String {
        if isSingleSkillImport {
            return manifests.isEmpty ? "Invalid skill folder — SKILL.md could not be parsed." : "1 skill loaded"
        }
        if totalSubdirectories == 0 {
            return "No subdirectories found. Each skill must be a subfolder containing a SKILL.md file."
        }
        if manifests.isEmpty && skipped.isEmpty {
            return "No skill folders found. Each skill must be a subfolder containing a SKILL.md file."
        }
        var parts: [String] = []
        if !manifests.isEmpty {
            parts.append("\(manifests.count) skill\(manifests.count == 1 ? "" : "s") loaded")
        }
        if !skipped.isEmpty {
            parts.append("\(skipped.count) skipped")
        }
        return parts.joined(separator: ", ")
    }
}

/// A subdirectory that was scanned but not accepted as a valid skill.
struct SkippedSkillEntry: Sendable {
    let directoryName: String
    let reason: SkipReason

    enum SkipReason: Sendable {
        case noSkillFile              // No SKILL.md found
        case parseError(String)       // SKILL.md exists but frontmatter is invalid
        /// A valid skill that was dropped because a skill of the same NAME is already loaded from
        /// another folder.
        ///
        /// ⚠️ Register A40. The importer silently filtered these out. Skills are addressed by name,
        /// so two folders offering `code-review` is an ordinary situation — and the user got no
        /// indication which copy won, or that a choice had been made at all. The import simply
        /// appeared to import fewer skills than the folder contained.
        case duplicateName(keptFrom: String)

        var displayText: String {
            switch self {
            case .noSkillFile: return "No SKILL.md file"
            case .parseError(let detail): return detail
            case .duplicateName(let keptFrom):
                return "A skill with this name is already loaded from '\(keptFrom)' — that one is kept"
            }
        }
    }
}
