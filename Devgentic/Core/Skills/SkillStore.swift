// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillStore.swift
//  Devgentic
//
//  The V6 skill library's one writer.
//
//  ## What is different from the store it replaces
//
//  `SkillRegistryStore` managed the DISAGREEMENT between a database index and folders on disk:
//  reconcile, tombstone, staleness, a watcher, "unmounted volume" versus "deleted by the user".
//  None of that exists here, because there is no second source of truth to disagree with. What is
//  left is ordinary persistence plus two invariants the shape cannot enforce on its own:
//
//    1. **`name` is immutable.** A new version may not rename its skill. Renaming silently
//       repoints every profile that linked the old name — and since `load_skill` addresses skills
//       by name, the model would start reaching a different skill with no error anywhere.
//    2. **Versions are append-only, and `latestVersionID` moves in the SAME save.** Two saves mean
//       a window where the pointer names a version that is not there yet, and a crash inside that
//       window leaves a skill whose latest is permanently dangling.
//
//  ## `Result`, not optionals, and the reason is a shipped defect
//
//  Every read returns `Result`, so "the store could not be read" stays distinguishable from "there
//  are no skills". Collapsing the two is what makes a user re-import everything they already have:
//  an empty library is something they act on, an error is something they report.
//

import Foundation
import SwiftData
import os

private let logger = DGLogger(category: "SkillStore")

enum SkillStoreError: LocalizedError, Equatable {
    case containerUnavailable
    case fetchFailed(String)
    case saveFailed(String)
    case notFound(String)
    case nameImmutable(was: String, attempted: String)
    case unsafeFilePath(String)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable: return "The skill library is not available this launch."
        case .fetchFailed(let detail): return "Could not read the skill library: \(detail)"
        case .saveFailed(let detail): return "Could not save to the skill library: \(detail)"
        case .notFound(let id): return "No skill with id \(id)"
        case .nameImmutable(let was, let attempted):
            return "This skill is named '\(was)'. A new version cannot rename it to '\(attempted)'."
        case .unsafeFilePath(let path):
            return "A bundled file's path cannot be used: \(Self.displayable(path)). Nothing was saved."
        }
    }

    /// A stored path rendered so it cannot forge structure in whatever reads this message.
    ///
    /// ⚠️ NOT cosmetic. This string is interpolated into `UpdateSkillTool`'s return value, which is
    /// a TOOL RESULT the model reads as markdown. `SkillIngest.isSafeRelativePath` refuses control
    /// characters precisely because a filename reaches the model as a heading — echoing the same
    /// bytes back in the REFUSAL would reopen that hole through the error path, which is exactly how
    /// `LoadSkillTool`'s own failure branch was found to leak a hostile name.
    ///
    /// Truncate BEFORE quoting, for the reason `SkillDiscoveryRendering` records: cutting the source
    /// can only destroy a boundary sequence, while cutting an escaped string can split one in half.
    private static func displayable(_ path: String) -> String {
        String(path.prefix(120)).debugDescription
    }
}

@Observable
@MainActor
final class SkillStore {

    static let shared = SkillStore()

    private var modelContainer: ModelContainer?

    /// Bumped on every mutation, observed by every view that renders library data.
    ///
    /// ⚠️ Views read through this store's `Result` API rather than `@Query` — which is what buys the
    /// error/empty distinction above, and exactly what costs the automatic invalidation `@Query`
    /// would have given. So the store has to publish it. Per-view counters were tried in the
    /// registry and left one pane stale after the other mutated.
    private(set) var revision = 0

    private func bumpRevision() { revision += 1 }

    private init() {}

    /// Injects the container. **Assigns immediately** — the caller is already on the main actor.
    ///
    /// ⚠️⚠️ THIS WAS `nonisolated` WITH A DEFERRED `Task { @MainActor in … }`, COPIED FROM THE STORE
    /// IT REPLACED, AND IT BROKE THE LIBRARY AT LAUNCH. The launch site is itself inside a
    /// `Task { @MainActor in … }`, so the deferred assignment queued BEHIND the code that needed it:
    /// everything that read the library first got `.containerUnavailable`, and the user saw an
    /// empty Skills library with the cause visible only in the log.
    ///
    /// The old store could defer because it was configured OUTSIDE the task, from a nonisolated
    /// context. This one is not, so it must not.
    @MainActor
    func configureContainer(_ container: ModelContainer) {
        modelContainer = container
    }

    /// Test seam — synchronous, so a test need not await an actor hop it cannot observe.
    func setContainerForTesting(_ container: ModelContainer?) {
        modelContainer = container
    }

    private func requireContext(_ consequence: String) -> ModelContext? {
        guard let context = modelContainer?.mainContext else {
            logger.error("[SKILL_STORE] No model container. CONSEQUENCE: \(consequence)")
            return nil
        }
        return context
    }

    // MARK: - Reads

    /// Every skill, drafts included, ordered by display name.
    ///
    /// ⚠️ Drafts ARE returned. Filtering them here would make the library unable to show them, and
    /// the library is the only place a draft can be finished. Callers that feed a RUN — resolution,
    /// the picker — filter drafts themselves; that is a per-caller policy, not a storage rule.
    func fetchSkills() -> Result<[SkillSD], SkillStoreError> {
        guard let context = requireContext("the Skills library renders empty this launch; nothing was changed on disk.") else {
            return .failure(.containerUnavailable)
        }
        do {
            let skills = try context.fetch(FetchDescriptor<SkillSD>())
            return .success(skills.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            })
        } catch {
            logger.error("[SKILL_STORE] Skill fetch FAILED: \(error.localizedDescription). CONSEQUENCE: the library shows nothing this launch and no agent resolves a skill; no rows were changed and the next launch retries.")
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    /// The skills a RUN may see: not drafts.
    func fetchRunnableSkills() -> Result<[SkillSD], SkillStoreError> {
        fetchSkills().map { $0.filter { !$0.isDraft } }
    }

    func fetchSkill(id: String) -> Result<SkillSD?, SkillStoreError> {
        guard let context = requireContext("this skill cannot be read; nothing was changed.") else {
            return .failure(.containerUnavailable)
        }
        do {
            let descriptor = FetchDescriptor<SkillSD>(predicate: #Predicate { $0.id == id })
            return .success(try context.fetch(descriptor).first)
        } catch {
            logger.error("[SKILL_STORE] Fetch of skill '\(id)' FAILED: \(error.localizedDescription). CONSEQUENCE: callers treat it as unavailable; no rows were changed.")
            return .failure(.fetchFailed(error.localizedDescription))
        }
    }

    /// Skills sharing a NAME. Skills are addressed by name at run time but keyed by id, so a
    /// collision is an ordinary situation that has to be reported rather than prevented.
    func fetchSkills(named name: String) -> Result<[SkillSD], SkillStoreError> {
        fetchSkills().map { $0.filter { $0.name == name } }
    }

    // MARK: - Create

    /// Creates a skill from a read-in package, as its FIRST version.
    func createSkill(
        from ingested: IngestedSkill,
        origin: SkillOrigin = .imported,
        isDraft: Bool = false,
        note: String = "Imported."
    ) -> Result<SkillSD, SkillStoreError> {
        create(name: ingested.name,
               displayName: ingested.name,
               description: ingested.description,
               body: ingested.body,
               allowedTools: ingested.allowedTools,
               files: ingested.files,
               origin: origin,
               isDraft: isDraft,
               note: note)
    }

    /// Creates a skill from values the user typed in the editor.
    func create(
        name: String,
        displayName: String? = nil,
        description: String,
        body: String,
        allowedTools: [String]? = nil,
        files: [IngestedFile] = [],
        origin: SkillOrigin = .created,
        isDraft: Bool = false,
        note: String = "Created."
    ) -> Result<SkillSD, SkillStoreError> {
        guard let context = requireContext("the skill was NOT created and nothing was written.") else {
            return .failure(.containerUnavailable)
        }

        // ⚠️ THE STORE ENFORCES THIS, not only ingest, because ingest is not the only way in.
        // `create` and `addVersion` are a SECOND write path — the create sheet and `update_skill` —
        // that never passes through `SkillIngest`. A guard living only at the create sheet is a
        // guard on a NAME, not on a capability; `SkillStore` is the only constructor of
        // `SkillFileSD` in the tree, so it is the one seam where "every stored path is
        // materialisable" can actually be true.
        //
        // ⚠️ The cost of a bad row is larger than a failed export: `SkillMaterializer.write` throws
        // on the FIRST unusable path, so the version projects NOTHING — `load_skill` then tells the
        // model there are no bundled files, and a `scripts/run.py` named in the instructions does
        // not exist at run time.
        //
        // ⚠️ SHAPE, NEVER POLICY. Only `isSafeRelativePath` is enforced here; the byte and
        // file-count caps stay at ingest. A cap is policy a future build may raise, and enforcing
        // policy at the store would let a changed constant retroactively make an existing skill
        // unsaveable.
        //
        // ⚠️ REFUSES THE WHOLE WRITE rather than dropping the file, for the reason `checkLimits`
        // already records: a skill stored minus a file looks complete and fails later, elsewhere.
        if let offender = files.first(where: { !SkillIngest.isSafeRelativePath($0.relativePath) }) {
            logger.error("[SKILL_STORE] REFUSED to create '\(name)': a bundled file's path is not materialisable. CONSEQUENCE: nothing was written — a stored path that cannot become a file would make this version project NO files at run time, so `load_skill` would report no bundled files and any path the instructions name would not exist.")
            return .failure(.unsafeFilePath(offender.relativePath))
        }

        let version = SkillVersionSD(
            note: note,
            skillDescription: description,
            allowedTools: allowedTools,
            body: body,
            files: files.map { SkillFileSD(relativePath: $0.relativePath, content: $0.content, isExecutable: $0.isExecutable) }
        )
        let skill = SkillSD(
            name: name,
            displayName: displayName ?? name,
            origin: origin,
            // ⚠️ Set BEFORE the save, in the same transaction as the version it names. A second
            // save would leave a window where the pointer dangles.
            latestVersionID: version.id,
            isDraft: isDraft,
            versions: [version]
        )
        context.insert(skill)

        do {
            try SharedContextSave.save(context, "skills: create '\(name)'")
        } catch {
            // Best-effort only: SwiftData cannot undo a FAILED save (RAG-27, `SharedContextCommitTests`).
            context.rollback()
            logger.error("[SKILL_STORE] Creating skill '\(name)' FAILED: \(error.localizedDescription). CONSEQUENCE: nothing was written and the library is unchanged — the user can retry.")
            return .failure(.saveFailed(error.localizedDescription))
        }

        bumpRevision()
        logger.notice("[SKILL_STORE] Created skill '\(name)' (\(skill.id)) with \(version.files.count) file(s)\(isDraft ? " as a DRAFT" : ""). CONSEQUENCE: \(isDraft ? "it is not offered to any agent until it leaves draft" : "it can now be linked to a profile").")
        return .success(skill)
    }

    // MARK: - New version

    /// Appends a version and moves `latestVersionID` to it, in one save.
    ///
    /// ⚠️ REFUSES A RENAME. `name` is the skill's identity and what `load_skill` matches on; a new
    /// version whose frontmatter renames it must be rejected, not applied. This is the check the
    /// reference API makes at upload, and the reason it exists is that a rename is invisible — the
    /// skill keeps working, for a different name, and every profile that linked the old one quietly
    /// stops resolving.
    func addVersion(
        toSkillWithID id: String,
        description: String,
        body: String,
        allowedTools: [String]?,
        files: [IngestedFile],
        note: String,
        declaredName: String? = nil
    ) -> Result<SkillVersionSD, SkillStoreError> {
        guard let context = requireContext("no version was added and the skill is unchanged.") else {
            return .failure(.containerUnavailable)
        }
        let existing: SkillSD?
        switch fetchSkill(id: id) {
        case .failure(let error): return .failure(error)
        case .success(let found): existing = found
        }
        guard let skill = existing else { return .failure(.notFound(id)) }

        if let declaredName, declaredName != skill.name {
            logger.error("[SKILL_STORE] REFUSED a new version of '\(skill.name)' (\(id)) because it declares the name '\(declaredName)'. CONSEQUENCE: nothing was written — a rename would leave every profile that linked '\(skill.name)' silently unresolved while the skill kept working under another name.")
            return .failure(.nameImmutable(was: skill.name, attempted: declaredName))
        }

        // ⚠️⚠️ NEWLY INTRODUCED PATHS ONLY — a blanket refusal here would be a net regression, not a
        // fix. Three of this method's four production callers CARRY FILES FORWARD from a stored
        // version (`update_skill`, plus Save and Restore in the detail sheet all map `SkillFileSD`
        // rows 1:1), so refusing everything would not protect anything — it would BRICK a skill that
        // already holds a bad row: no edit, no restore, and `update_skill` returning a permanent
        // error the model retries, spending a destructive-tier approval each time, for a state no
        // sheet can repair.
        //
        // ⚠️ A stored-but-now-invalid row is NOT hypothetical: `isSafeRelativePath` has already
        // WIDENED once (it began refusing control characters), so a row that was valid when written
        // can be invalid now — and the next widening will do it again. The rule has to be about what
        // this write ADDS, never about what the skill already carries.
        //
        // ⚠️ A carried row is preserved VERBATIM. Repairing a path by rewriting it is the
        // content-corruption class this codebase has shipped four times.
        //
        // Scans EVERY version rather than just the latest, because Restore can bring an older
        // version's files forward. Paid for only when something is already wrong.
        let unsafe = files.map(\.relativePath).filter { !SkillIngest.isSafeRelativePath($0) }
        if !unsafe.isEmpty {
            let alreadyStored = Set(skill.versions.flatMap { $0.files.map(\.relativePath) })
            if let introduced = unsafe.first(where: { !alreadyStored.contains($0) }) {
                logger.error("[SKILL_STORE] REFUSED a new version of '\(skill.name)': it introduces a bundled path that is not materialisable. CONSEQUENCE: nothing was written and the previous version is still current — this write would have added a path that makes the whole version project no files at run time.")
                return .failure(.unsafeFilePath(introduced))
            }
            logger.notice("[SKILL_STORE] '\(skill.name)' carries \(unsafe.count) bundled path(s) that would be refused if introduced today, kept verbatim because this version only carries them FORWARD. CONSEQUENCE: the write proceeds, but `SkillMaterializer` refuses the whole projection while such a row exists — remove the file in the Skills library to make the skill's bundled files reachable again.")
        }

        let version = SkillVersionSD(
            note: note,
            skillDescription: description,
            allowedTools: allowedTools,
            body: body,
            files: files.map { SkillFileSD(relativePath: $0.relativePath, content: $0.content, isExecutable: $0.isExecutable) }
        )
        version.skill = skill
        context.insert(version)
        skill.latestVersionID = version.id

        do {
            try SharedContextSave.save(context, "skills: add version to '\(skill.name)'")
        } catch {
            // Best-effort only: SwiftData cannot undo a FAILED save (RAG-27, `SharedContextCommitTests`).
            context.rollback()
            logger.error("[SKILL_STORE] Adding a version to '\(skill.name)' FAILED: \(error.localizedDescription). CONSEQUENCE: nothing was written; the previous version is still the latest and the skill still loads.")
            return .failure(.saveFailed(error.localizedDescription))
        }

        bumpRevision()
        logger.notice("[SKILL_STORE] Added version \(version.id) to '\(skill.name)' (\(id)): \(note). CONSEQUENCE: this reaches EVERY profile linked to the skill that does not pin an older version — earlier versions are untouched and remain restorable.")
        return .success(version)
    }

    // MARK: - Mutations that do not make a version

    /// Flags and labels are LIBRARY state, not content, so they do not create a version.
    ///
    /// ⚠️ The distinction is deliberate: a version is a snapshot of what the model reads. Bumping
    /// the chain because someone renamed a display label would make history unreadable, and pinning
    /// a version would then pin an unrelated preference too.
    func setDraft(_ isDraft: Bool, skillID: String) -> Result<Void, SkillStoreError> {
        mutate(skillID: skillID, what: "draft state") { $0.isDraft = isDraft }
    }

    func setAgentWritable(_ writable: Bool, skillID: String) -> Result<Void, SkillStoreError> {
        mutate(skillID: skillID, what: "agent-writable permission") { skill in
            skill.isAgentWritable = writable
            logger.notice("[SKILL_STORE] '\(skill.name)' is\(writable ? " now" : " no longer") agent-writable. CONSEQUENCE: \(writable ? "an agent holding update_skill can add versions to it, each one still needing per-call approval, and every version reaches every linked profile" : "update_skill refuses to modify it").")
        }
    }

    func setDisplayName(_ displayName: String, skillID: String) -> Result<Void, SkillStoreError> {
        mutate(skillID: skillID, what: "display name") { $0.displayName = displayName }
    }

    func deleteSkill(id: String) -> Result<Void, SkillStoreError> {
        guard let context = requireContext("the skill was NOT deleted.") else {
            return .failure(.containerUnavailable)
        }
        switch fetchSkill(id: id) {
        case .failure(let error): return .failure(error)
        case .success(let found):
            guard let skill = found else { return .failure(.notFound(id)) }
            let name = skill.name
            let versionCount = skill.versions.count
            context.delete(skill)
            do { try SharedContextSave.save(context, "skills: delete '\(name)'") } catch {
                // Best-effort only: SwiftData cannot undo a FAILED save (RAG-27, `SharedContextCommitTests`).
            context.rollback()
                logger.error("[SKILL_STORE] Deleting '\(name)' FAILED: \(error.localizedDescription). CONSEQUENCE: the skill is still there and still linked; nothing was lost.")
                return .failure(.saveFailed(error.localizedDescription))
            }
            bumpRevision()
            logger.notice("[SKILL_STORE] Deleted skill '\(name)' (\(id)) and its \(versionCount) version(s). CONSEQUENCE: this is PERMANENT — every version and bundled file went with it, and any profile still linking it now reports an unresolved skill. Export first if it was not backed up.")
            return .success(())
        }
    }

    private func mutate(
        skillID: String,
        what: String,
        _ change: (SkillSD) -> Void
    ) -> Result<Void, SkillStoreError> {
        guard let context = requireContext("the \(what) was NOT changed.") else {
            return .failure(.containerUnavailable)
        }
        switch fetchSkill(id: skillID) {
        case .failure(let error): return .failure(error)
        case .success(let found):
            guard let skill = found else { return .failure(.notFound(skillID)) }
            change(skill)
            do { try SharedContextSave.save(context, "skills: change \(what) of '\(skill.name)'") } catch {
                // Best-effort only: SwiftData cannot undo a FAILED save (RAG-27, `SharedContextCommitTests`).
            context.rollback()
                logger.error("[SKILL_STORE] Changing the \(what) of '\(skill.name)' FAILED: \(error.localizedDescription). CONSEQUENCE: the previous value still stands and the UI should re-read rather than assume its own value took.")
                return .failure(.saveFailed(error.localizedDescription))
            }
            bumpRevision()
            return .success(())
        }
    }
}
