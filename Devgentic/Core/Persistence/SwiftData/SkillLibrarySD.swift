// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SkillLibrarySD.swift
//  Devgentic
//
//  The skill library: Devgentic OWNS skill content (schema V6).
//
//  ## What changed, and why it is a replacement rather than an evolution
//
//  V4/V5's `SkillSourceSD` + `SkillManifestSD` were an INDEX. Content lived on disk, the database
//  held routing metadata, and a `folderPath` was the identity. That design carried a permanent tax:
//  disk and database could disagree, so it needed reconciliation, tombstoning, staleness detection
//  with an mtime tolerance and a future-clamp, a refcounted filesystem watcher, security-scoped
//  bookmarks, and a protocol for telling "the volume is unmounted" apart from "the user deleted it".
//  Every one of those exists only to paper over having two sources of truth.
//
//  Here there is one. A skill's bytes live in the store. Nothing points at a folder, so nothing
//  dangles, and the entire reconciliation category disappears.
//
//  ## The model is Anthropic's Skills API, deliberately
//
//  Verified against the published API rather than invented, because matching it is what lets skills
//  move between Claude and Devgentic without a translation layer:
//
//    - A skill is addressed by an OPAQUE ID (`skill_…`), never by a name or a path.
//    - A version is an IMMUTABLE COMPLETE SNAPSHOT (`skver_…`) — every upload is the whole file set,
//      not a delta, and omitted files are not carried forward.
//    - The skill row holds a pointer to the latest version; a reference may pin a specific version
//      or follow `latest`.
//    - `name` cannot change across versions. `displayName` can.
//    - Limits: 30 MB uncompressed per skill, name ≤64 chars of `[a-z0-9-]`, description ≤1024 chars.
//
//  ⚠️ **Versions are what make an agent-writable skill tolerable.** `update_skill` previously
//  overwrote SKILL.md and kept ONE backup in a `.history` file keyed by NAME, so two skills sharing
//  a name shared a single revert slot and a second edit destroyed the only copy of the first. An
//  append-only version chain removes that whole problem: the agent adds a version, and nothing that
//  existed before is mutated.
//
//  ## Rule 5b: why V5 needs no frozen copies for this change
//
//  V6 RETIRES `SkillSourceSD` and `SkillManifestSD` — it does not evolve them. Their live classes
//  stay in `SkillRegistrySD.swift`, unlisted by V6 but still listed by V5, so V5 keeps rendering
//  exactly the shape it recorded and no two versions collide. That is the whole reason those classes
//  are not deleted outright yet; they are V5's definition and the migration's read path. Contrast
//  V4, which DID need frozen copies, because V5 evolved an entity V4 also listed.
//
//  Entity retirement itself is lightweight-safe and proven against a real store —
//  `SchemaMigrationTests.testRetiredCodeViewerEntityDropsWithoutLosingConversations`.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "SkillLibrarySD")

// MARK: - How a skill got here

/// Where a skill came from. Recorded for display only — it grants nothing and gates nothing.
///
/// Stored raw for the same reason `SkillSourceKind` was: a future case must not make older rows
/// undecodable, and an unknown value reads as `.imported`, the conservative choice.
enum SkillOrigin: String, Codable, Sendable, CaseIterable {

    /// Authored in Devgentic's own editor.
    case created

    /// Unpacked from a `.zip`/`.skill` archive, a bare `.md`, or a folder the user pointed at.
    /// ⚠️ Imported ≠ trusted. It only means the bytes arrived from outside.
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

    /// Opaque identity, `skill_<uuid>`. **Never a path and never the name.**
    ///
    /// ⚠️ This is the change that makes the whole design work. V4/V5 keyed on `folderPath`, so
    /// identity broke whenever a folder moved, a parent was renamed, a volume was unmounted, or the
    /// store was opened on another machine — and every profile's reference broke with it. An opaque
    /// id is stable under all of those because it describes nothing about the world.
    @Attribute(.unique)
    var id: String

    /// The skill's addressable name — what `load_skill` matches on, and what the frontmatter says.
    ///
    /// ⚠️ IMMUTABLE across versions, matching the reference API: a new version whose SKILL.md
    /// renames the skill is rejected rather than applied. Renaming would silently repoint every
    /// profile that linked the old name.
    ///
    /// ⚠️ NOT unique at the schema level, also matching the reference API. Two skills may legitimately
    /// be called `code-review`. A unique constraint would turn an ordinary import into a failure;
    /// instead the collision is resolved deterministically and REPORTED at resolve time.
    var name: String

    /// Human-facing label. Free-form, editable, defaults to `name`.
    var displayName: String

    var createdAt: Date

    /// `SkillOrigin.rawValue`.
    var originRaw: String

    /// Points at the newest `SkillVersionSD.id`.
    ///
    /// ⚠️ A plain id rather than a second `@Relationship`. SwiftData cannot infer an inverse when
    /// two relationships join the same pair of entities, and the ambiguity surfaces as corrupted
    /// back-references rather than a compile error. `versions` below is the only relationship.
    var latestVersionID: String?

    /// A skill that exists but is not offered to any agent yet.
    ///
    /// Draft is a LIBRARY state, not a per-profile one: a half-written skill should not be linkable
    /// at all, rather than linkable-but-off in each profile separately.
    var isDraft: Bool = false

    /// Whether an agent may add versions via `update_skill`. Default deny.
    ///
    /// ⚠️ Lives here, on the database row, and NOT in the SKILL.md body — that is the entire
    /// security property, and it survives the move to DB-owned content unchanged. A skill body is
    /// injected into the model's context, so a permission stored in content would be a permission
    /// the model can grant itself.
    var isAgentWritable: Bool = false

    /// Every version, newest and oldest alike. Cascade-deleted with the skill.
    ///
    /// ⚠️ UNORDERED. SwiftData relationship arrays carry no ordering guarantee, so anything that
    /// presents or exports them must sort by `createdAt` explicitly. Relying on natural order is
    /// the same defect class as the unsorted `contentsOfDirectory` that once made the system prompt
    /// filesystem-order dependent.
    @Relationship(deleteRule: .cascade, inverse: \SkillVersionSD.skill)
    var versions: [SkillVersionSD]

    /// How this skill got here — the typed reader for `originRaw`.
    ///
    /// ⚠️ NOT DELETED WHEN IT HAD NO CALLER, and the reasoning is worth keeping: `originRaw` is a
    /// PERSISTED attribute that `SkillStore.create` writes on every skill. Removing the only typed
    /// reader would have left a column the app writes on every insert and can never read back —
    /// strictly worse than an unused accessor. It is surfaced in the detail sheet instead.
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

    /// The newest version, resolved through `latestVersionID` with a defensive fallback.
    ///
    /// ⚠️ The fallback is not decoration. `latestVersionID` is a soft pointer, so a partially-applied
    /// write, a restored backup, or a future bug can leave it naming a version that is not in
    /// `versions`. Returning the newest by date keeps the skill USABLE and logs the inconsistency,
    /// rather than making the skill silently vanish from every prompt that linked it.
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

/// One complete, immutable snapshot of a skill.
///
/// ⚠️ **NOTHING MAY MUTATE A VERSION AFTER IT IS SAVED.** Editing a skill creates a new version;
/// that is what makes history real and what makes `update_skill` append-only. The properties are
/// `var` only because SwiftData requires it for persistence — treat every one as `let`.
@Model
final class SkillVersionSD {

    /// Opaque identity, `skver_<uuid>` — the value a profile pins when it does not want `latest`.
    @Attribute(.unique)
    var id: String

    var createdAt: Date

    /// One line on what changed. Written by whoever created the version, agent included.
    var note: String

    /// The routing key — rendered into `<available_skills>` and what the model matches a task against.
    ///
    /// ⚠️ Per-VERSION, not per-skill, because it is frontmatter: editing the description IS a new
    /// version. Keeping it on the skill would let a pinned version advertise text from a newer one.
    var skillDescription: String

    /// The author's `allowed-tools` declaration, VERBATIM, as a JSON array in TEXT.
    ///
    /// ⚠️ **NOT `[String]?`, and that is not a style choice.** Below macOS 26.1 SwiftData persists a
    /// native `[String]?` as Binary Data; a store written there and opened on 26.1+ fails with
    /// `NSCocoaErrorDomain 134140` and the app cannot launch — an OS-side change no schema
    /// versioning can defend against. `PromptModel.tags` is the one attribute already exposed, and
    /// `SchemaMigrationTests.testTagsRemainsTheOnlyNonRelationshipCollectionAttribute` exists
    /// specifically to stop a second one appearing. It caught this property. Hand-rolled JSON, as
    /// `attachedFileURLsJSON` and `configData` already do, is the codebase's answer.
    ///
    /// ⚠️ JSON rather than a delimiter join, because elements legitimately CONTAIN commas —
    /// `Bash(git add:*, git commit:*)` is a real scoped declaration, and a joined form would not
    /// survive the round trip.
    ///
    /// Private: every reader goes through `allowedTools` below.
    private var allowedToolsJSON: String?

    /// The SKILL.md body — everything below the frontmatter.
    var body: String

    /// Every bundled file in this snapshot. Cascade-deleted with the version.
    ///
    /// ⚠️ UNORDERED, like `SkillSD.versions`. Sort by `relativePath` wherever order is observable.
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

    /// The declaration as elements. Computed, so it is never persisted in its native form.
    ///
    /// ⚠️ `nil` (field absent) and `[]` (`allowed-tools: []`, "this skill needs no tools") are
    /// DIFFERENT statements and both survive this round trip. Collapsing them would turn an explicit
    /// declaration into silence — see `YAMLFrontmatterParser`, where exactly that was a live defect.
    var allowedTools: [String]? {
        get {
            guard let allowedToolsJSON, let data = allowedToolsJSON.data(using: .utf8) else { return nil }
            guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                logger.error("[SKILL_LIBRARY] Version '\(self.id)' has an unreadable allowed-tools value. CONSEQUENCE: the declaration reads as absent — the skill still loads and runs exactly as before, since the declaration gates nothing.")
                return nil
            }
            return decoded
        }
        set { allowedToolsJSON = Self.encode(newValue) }
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

    /// Path relative to the skill root, e.g. `scripts/analyze.py`, `reference/checklist.md`.
    ///
    /// ⚠️ Structure lives ENTIRELY in this string — there are no directory rows. A materialized
    /// export recreates directories from these paths, so a value containing `..` or a leading `/`
    /// would escape the destination. Validation belongs at the ingest boundary, where the untrusted
    /// archive is read, not here: a stored row is already past the point where refusing helps.
    var relativePath: String

    /// The file's bytes.
    ///
    /// ⚠️ `Data`, not `String`, and that is a correctness choice rather than a generalization.
    /// V4/V5's loader called `String(contentsOf:encoding:.utf8)` and `continue`d on failure, so
    /// every binary file in a skill — an image, a PDF, a compiled helper — was silently dropped.
    /// Content lives here now, so a dropped file is a file the user permanently loses on export.
    ///
    /// ⚠️ `.externalStorage` keeps blobs out of the SQLite file, in the hidden
    /// `.DevgenticSD_SUPPORT/` sibling. `ChatPersistenceStore` records the hazard that comes with
    /// it: a delete-then-recreate upsert RE-CLONES the blob. Versions are append-only, so the
    /// pattern that triggers it does not arise here — do not introduce an update path that does.
    @Attribute(.externalStorage)
    var content: Data

    /// Whether the file carried the executable bit.
    ///
    /// ⚠️ Carried because export must restore it. A `scripts/analyze.py` that arrives executable and
    /// leaves non-executable is a skill that worked before the round-trip and does not after — a
    /// silent, delayed failure with no visible cause.
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
