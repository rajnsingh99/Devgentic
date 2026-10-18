// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillLibrarySD.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "SkillLibrarySD")

// MARK: - How a skill got here

/// Where a skill came from: recorded for display only; it grants nothing and gates nothing.
/// Stored raw so a future case cannot make older rows undecodable; an unknown value reads as
/// `.imported`.
enum SkillOrigin: String, Codable, Sendable, CaseIterable {

    /// Authored in Devgentic's own editor.
    case created

    /// Unpacked from a `.zip`/`.skill` archive, a bare `.md`, or a folder the user pointed at.
    /// Imported does not mean trusted; it only means the bytes arrived from outside.
    case imported

    static func tolerant(_ raw: String) -> SkillOrigin {
        guard let origin = SkillOrigin(rawValue: raw) else {
            logger.notice("[SKILL_LIBRARY] Unknown skill origin '\(raw)' — reading it as '.imported'. CONSEQUENCE: the skill still appears and works; only the provenance label is affected.")
            return .imported
        }
        return origin
    }
}

// MARK: - Skill (the addressable unit)

/// One skill in the library. Holds IDENTITY and USER STATE; every byte of content lives on a version.
@Model
final class SkillSD {

    /// Opaque identity, `skill_<uuid>`: never a path and never the name.
    /// Stable when folders move or the store opens on another machine, since it describes nothing about the
    /// world.
    @Attribute(.unique)
    var id: String

    /// The skill's addressable name, matched by `load_skill` and stated in the frontmatter.
    /// Immutable across versions (a renaming version is rejected) and not unique at the schema level;
    /// collisions are resolved and reported at resolve time.
    var name: String

    /// Human-facing label. Free-form, editable, defaults to `name`.
    var displayName: String

    var createdAt: Date

    /// `SkillOrigin.rawValue`.
    var originRaw: String

    /// Points at the newest `SkillVersionSD.id`.
    /// A plain id, not a second `@Relationship`: SwiftData cannot infer an inverse between the same pair of
    /// entities.
    var latestVersionID: String?

    /// A skill that exists but is not offered to any agent yet.
    /// A library-level state, so a half-written skill cannot be linked to any profile.
    var isDraft: Bool = false

    /// Whether an agent may add versions via `update_skill`; default deny.
    /// Stored on the database row, not in the SKILL.md body: a permission in content is one the model could
    /// grant itself.
    var isAgentWritable: Bool = false

    /// Every version, newest and oldest alike; cascade-deleted with the skill.
    /// Unordered: relationship arrays carry no ordering guarantee, so sort by `createdAt` wherever order is
    /// observable.
    @Relationship(deleteRule: .cascade, inverse: \SkillVersionSD.skill)
    var versions: [SkillVersionSD]

    /// How this skill got here: the typed reader for `originRaw`, shown in the detail sheet.
    var origin: SkillOrigin { SkillOrigin.tolerant(originRaw) }

    init(
        id: String = SkillSD.newID(),
        name: String,
        displayName: String? = nil,
        createdAt: Date = Date(),
        origin: SkillOrigin = .imported,
        latestVersionID: String? = nil,
        isDraft: Bool = false,
        isAgentWritable: Bool = false,
        versions: [SkillVersionSD] = []
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.createdAt = createdAt
        self.originRaw = origin.rawValue
        self.latestVersionID = latestVersionID
        self.isDraft = isDraft
        self.isAgentWritable = isAgentWritable
        self.versions = versions
    }

    static func newID() -> String { "skill_\(UUID().uuidString.lowercased())" }

    /// The newest version, resolved through `latestVersionID` with a fallback to the newest by date.
    /// `latestVersionID` is a soft pointer; the fallback keeps a skill usable and logs the inconsistency.
    var latestVersion: SkillVersionSD? {
        if let latestVersionID, let match = versions.first(where: { $0.id == latestVersionID }) {
            return match
        }
        let newest = versions.max(by: { $0.createdAt < $1.createdAt })
        if latestVersionID != nil, newest != nil {
            logger.error("[SKILL_LIBRARY] Skill '\(self.name)' (\(self.id)) names latest version '\(self.latestVersionID ?? "nil")', which is not among its \(self.versions.count) stored version(s). CONSEQUENCE: the newest version by date is used instead so the skill still loads — the pointer is stale and will be corrected on the next write.")
        }
        return newest
    }
}

// MARK: - Version (an immutable snapshot)

/// One complete, immutable snapshot of a skill; editing a skill creates a new version, which keeps
/// `update_skill` append-only. Properties are `var` only because SwiftData requires it; treat every one
/// as `let`.
@Model
final class SkillVersionSD {

    /// Opaque identity, `skver_<uuid>` — the value a profile pins when it does not want `latest`.
    @Attribute(.unique)
    var id: String

    var createdAt: Date

    /// One line on what changed. Written by whoever created the version, agent included.
    var note: String

    /// The routing key, rendered into `<available_skills>` and matched against tasks by the model.
    /// Per version because it is frontmatter: a pinned version must not advertise text from a newer one.
    var skillDescription: String

    // Why: not `[String]?`: below macOS 26.1 that persists as Binary Data and a store opened on 26.1+ fails
    // with 134140.
    /// The author's `allowed-tools` declaration, verbatim, as a JSON array in text; private, read through
    /// `allowedTools`. JSON because elements can contain commas, such as `Bash(git add:*, git commit:*)`.
    private var allowedToolsJSON: String?

    /// The SKILL.md body — everything below the frontmatter.
    var body: String

    /// Every bundled file in this snapshot; cascade-deleted with the version.
    /// Unordered, like `SkillSD.versions`: sort by `relativePath` wherever order is observable.
    @Relationship(deleteRule: .cascade, inverse: \SkillFileSD.version)
    var files: [SkillFileSD]

    var skill: SkillSD?

    init(
        id: String = SkillVersionSD.newID(),
        createdAt: Date = Date(),
        note: String = "",
        skillDescription: String,
        allowedTools: [String]? = nil,
        body: String,
        files: [SkillFileSD] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.note = note
        self.skillDescription = skillDescription
        self.allowedToolsJSON = Self.encode(allowedTools)
        self.body = body
        self.files = files
    }

    /// The declaration as elements; computed, never persisted in its native form and get-only.
    /// `nil` (field absent) and `[]` (declares no tools) are different statements and both survive the
    /// round trip.
    var allowedTools: [String]? {
        get {
            guard let allowedToolsJSON, let data = allowedToolsJSON.data(using: .utf8) else { return nil }
            guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                logger.error("[SKILL_LIBRARY] Version '\(self.id)' has an unreadable allowed-tools value. CONSEQUENCE: the declaration reads as absent — the skill still loads and runs exactly as before, since the declaration gates nothing.")
                return nil
            }
            return decoded
        }
    }

    private static func encode(_ tools: [String]?) -> String? {
        guard let tools else { return nil }
        guard let data = try? JSONEncoder().encode(tools) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func newID() -> String { "skver_\(UUID().uuidString.lowercased())" }

    /// Files in a deterministic order. Use this, never `files` directly, anywhere order is visible.
    var orderedFiles: [SkillFileSD] {
        files.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    /// Derived rather than stored — `resourceCount` and `hasScripts` were stored columns in V4/V5
    /// and could therefore disagree with the files they described.
    var resourceCount: Int { files.count }

    var hasScripts: Bool { files.contains { $0.relativePath.hasPrefix("scripts/") } }

}

// MARK: - File (bytes)

/// One bundled file inside a version.
@Model
final class SkillFileSD {

    // Why: a `..` or leading `/` would escape the destination when an export recreates directories.
    /// Path relative to the skill root, e.g. `scripts/analyze.py`; structure lives entirely in this string,
    /// with no directory rows. `SkillStore` refuses newly unsafe paths itself; existing rows are not
    /// re-validated, and `SkillMaterializer` re-checks at write time.
    var relativePath: String

    // Why: a delete-then-recreate upsert re-clones external blobs; versions are append-only, so do not add an
    // update path.
    /// The file's bytes: `Data`, not `String`, so binary files (images, PDFs, helpers) are not dropped on
    /// export. `.externalStorage` keeps blobs out of SQLite.
    @Attribute(.externalStorage)
    var content: Data

    /// Whether the file carried the executable bit, carried so export can restore it and scripts keep
    /// working.
    var isExecutable: Bool = false

    var version: SkillVersionSD?

    init(relativePath: String, content: Data, isExecutable: Bool = false) {
        self.relativePath = relativePath
        self.content = content
        self.isExecutable = isExecutable
    }

    /// The bytes as text, when they are text. `nil` for binary — the caller decides what that means.
    var asText: String? { String(data: content, encoding: .utf8) }
}

// MARK: - Limits

/// Ingest limits, matching the reference API so a skill that is valid there is valid here.
enum SkillLibraryLimits {

    /// Total uncompressed bytes per skill version.
    static let maxSkillBytes = 30 * 1024 * 1024

    /// `name`: lowercase letters, digits and hyphens.
    static let maxNameChars = 64

    /// `description`: also the cap `SkillDiscoveryRendering` already applies when rendering it.
    static let maxDescriptionChars = 1024

    /// Files per version. Not specified by the reference API; a bound is still required, because
    /// the alternative is an unbounded loop over an untrusted archive's contents.
    static let maxFilesPerVersion = 500
}
