// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  UpdateSkillTool.swift
//  Devgentic
//
//  Lets an agent rewrite the INSTRUCTIONS of a skill the user has explicitly marked agent-writable.
//
//  ## The threat this is built around
//
//  A skill body is injected into the model's context. A tool that lets the model edit skill bodies
//  is the model editing its own future prompt — and because the library is global, one new version
//  reaches every profile linked to that skill, in every conversation, on every future run, with no
//  re-approval. The approval was scoped to one conversation; the effect is not. Untrusted text can
//  enter a turn through any tool result (a fetched page, a read file, a ChatOps message), so the
//  path from "hostile content in a tool result" to "persistent instruction" is short.
//
//  ⚠️ V6 SOFTENED THE WORST PART, and it is worth knowing which part. This used to OVERWRITE
//  SKILL.md and keep one backup in a `.history` file keyed by NAME — so two skills sharing a name
//  shared a single revert slot, and a second agent edit destroyed the only copy of the first. It now
//  APPENDS an immutable version. Nothing that existed before is mutated, a profile that pinned an
//  older version keeps reading exactly that one, and every earlier version stays restorable.
//
//  ## Layered controls, and what each does NOT stop
//
//  1. **`isAgentWritable`**, default false, per skill, stored on the LIBRARY ROW — not in any
//     content the agent can write. This is the gate that holds: the agent cannot grant itself the
//     permission it is gated by. Does not stop a user who turns it on.
//  2. **A Tool Library row.** Being a catalogue tool rather than an injected one means the user can
//     see it, disable it, and remove it — unlike `load_skill`, which is invisible and unremovable.
//     It is absent from every existing profile, so it is opt-in. Does not stop a user who adds it.
//  3. **`.destructive` risk tier.** `SessionToolApprovals.allow` refuses a durable "allow for this
//     chat" grant for a destructive tool, inside the actor. Does not stop the per-call approval, nor
//     a user who turns Ask-first off for this tool in the Tool Library.
//  4. **Only the body is writable.** `name` is the identity and `description` is the routing key
//     rendered into every prompt; the new version carries both forward from the current one, and
//     `SkillStore.addVersion` refuses a rename outright. Bundled files are carried forward too — a
//     version is a COMPLETE snapshot, so omitting them would silently delete every one.
//
//  ⚠️ **This is not a boundary.** A guard attached to one tool is a guard on a NAME, not on a
//  capability — this codebase's own rule. The tool is narrow so that the *convenient* path is also
//  the *governed* one.
//
//  ## Why there is no `create_skill`
//
//  A created skill is a new ROUTING entry: the moment one exists and is linked, its description is
//  rendered into `<available_skills>` and the model starts matching tasks against it. An
//  agent-authored skill would be a routing entry no person ever reviewed. Creation stays a human
//  act — which is what the Draft state in the create sheet exists to protect even for humans.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "UpdateSkillTool")

struct UpdateSkillTool: DevgenticTool {

    let name = "update_skill"

    /// ⚠️ Must be a raw category some `BuiltInToolCategory` group gathers, or the tool gets no
    /// sidebar row and `testEveryEntryDeclaresANonEmptyCategory` has nothing to catch it with.
    let category = "macOS Utilities"

    let description = """
        Rewrite the instructions (the body) of a skill the user has marked as agent-writable. \
        Use this to record a correction or a better procedure discovered while using a skill. \
        Cannot create skills, cannot rename them, and cannot change a skill's description — \
        only the instruction body below the frontmatter. Most skills are NOT writable; if this \
        returns a not-writable error, tell the user what you would have changed instead.
        """

    struct Arguments: Decodable, Sendable {
        let skillName: String
        let instructions: String
        let changeNote: String

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { nil }
        }

        /// Multi-alias decoding, matching `LoadSkillTool` — models emit snake_case and camelCase
        /// interchangeably, and a decode failure here is an unhelpful error the model cannot act on.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            func string(_ keys: [String]) -> String? {
                for key in keys {
                    if let codingKey = DynamicKey(stringValue: key),
                       let value = try? container.decode(String.self, forKey: codingKey) {
                        return value
                    }
                }
                return nil
            }
            guard let skillName = string(["skill_name", "skillName", "name", "skill"]) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'skill_name'."))
            }
            guard let instructions = string(["instructions", "body", "content", "text"]) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Missing 'instructions' — the full replacement body."))
            }
            self.skillName = skillName
            self.instructions = instructions
            self.changeNote = string(["change_note", "changeNote", "note", "reason"]) ?? ""
        }
    }

    var parameterSchema: ToolParameters {
        SchemaBuilder.object(
            properties: [
                ("skill_name", "string", "The name of the skill to update. Must be one you can see in your available skills."),
                ("instructions", "string", "The COMPLETE replacement body. This replaces the whole instruction text, so include everything that should remain."),
                ("change_note", "string", "One line: what changed and why. Shown to the user in the approval prompt.")
            ],
            required: ["skill_name", "instructions", "change_note"]
        )
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run {
            // Resolve the target from the LIBRARY, never from an argument. The destination is an
            // opaque id the store owns, so there is no path to traverse and no filename to forge —
            // the class of defect that once let a crafted `name` reach `removeItem` is structurally
            // absent rather than filtered.
            guard let skills = try? SkillStore.shared.fetchRunnableSkills().get() else {
                return "Error: the skill library could not be read, so no skill could be updated. Nothing was changed."
            }
            let matches = skills.filter { $0.name == arguments.skillName }
            guard let skill = matches.first else {
                // ⚠️ LABELLED. `skill_name` is MODEL-supplied, unbounded and free to contain
                // newlines, and this string is a TOOL RESULT the model reads as markdown — so an
                // echoed name could open a `[SYSTEM ALERT]` line of its own, one character from a
                // real one. The identical hole was closed in `LoadSkillTool` and left open here,
                // which is why `label` now lives in a shared type instead of that tool.
                let available = skills.map { SkillToolText.label($0.name) }.sorted().joined(separator: ", ")
                return "Error: no skill named '\(SkillToolText.label(arguments.skillName))'. Available: \(available.isEmpty ? "none" : available)."
            }
            // ⚠️ REFUSE ON AMBIGUITY. The library keys on an opaque id, so two skills can share a
            // NAME — and this tool addresses skills by name. Picking one would mean an approved edit
            // landing in a skill the user did not mean, with no way to tell which. A refusal they
            // can act on is the only honest answer.
            guard matches.count == 1 else {
                let ids = matches.map(\.id).sorted().joined(separator: ", ")
                logger.error("[SKILL_EDIT] REFUSED an agent edit to '\(arguments.skillName)': \(matches.count) skills share that name (\(ids)). CONSEQUENCE: nothing was written — editing by name would have picked one arbitrarily.")
                return "Error: \(matches.count) skills are named '\(SkillToolText.label(arguments.skillName))'. Nothing was changed — this tool addresses skills by name and cannot tell which one you mean. Ask the user to rename or remove one."
            }
            guard skill.isAgentWritable else {
                logger.notice("[SKILL_EDIT] REFUSED an agent edit to '\(skill.name)' — not marked agent-writable. CONSEQUENCE: nothing was written; the user must enable \"Allow agent edits\" for this skill in the Skills library before this can succeed.")
                return """
                    Error: skill '\(SkillToolText.label(skill.name))' is not marked agent-writable, so nothing was changed. \
                    The user can enable "Allow agent edits" for this skill in the Skills library. \
                    Tell them what you would have changed and why.
                    """
            }
            guard let current = skill.latestVersion else {
                return "Error: skill '\(SkillToolText.label(skill.name))' has no version to build on. Nothing was changed."
            }

            // ⚠️ Carries the current version's DESCRIPTION, DECLARATION and FILES forward unchanged.
            // A version is a COMPLETE snapshot, so omitting them would silently delete every bundled
            // file and blank the routing key on the first agent edit. This tool rewrites the
            // instruction body and nothing else, and that is enforced here rather than promised.
            let carried = current.orderedFiles.map {
                IngestedFile(relativePath: $0.relativePath, content: $0.content, isExecutable: $0.isExecutable)
            }
            switch SkillStore.shared.addVersion(
                toSkillWithID: skill.id,
                description: current.skillDescription,
                body: arguments.instructions,
                allowedTools: current.allowedTools,
                files: carried,
                note: arguments.changeNote.isEmpty ? "Updated by an agent." : arguments.changeNote
            ) {
            case .failure(let error):
                return "Error updating '\(SkillToolText.label(skill.name))': \(SkillToolText.label(error.localizedDescription, limit: 400)). The previous version is still current, so the skill is unchanged."
            case .success(let version):
                logger.notice("[SKILL_EDIT] Agent added version \(version.id) to skill '\(skill.name)': \(arguments.changeNote). CONSEQUENCE: it reaches EVERY profile linked to this skill that does not pin an older version, in every conversation, on every future run — this edit outlives the conversation that approved it. Earlier versions are untouched and restorable from the Skills library.")
                // ⚠️⚠️ DO NOT TELL THE MODEL TO RELOAD. This used to end with "Call `load_skill`
                // again if you need the updated text", which was advice that could not work:
                // `LoadSkillTool` reads the version this RUN resolved — deliberately, so a profile
                // pinning an older snapshot keeps reading it — so a reload returns the pre-edit body
                // verbatim. A model following its own tool's instruction sees its write apparently
                // undone, and the plausible next move is to write again, which appends a second
                // identical version and asks the user to approve it. The text it just wrote is text
                // it already has; nothing needs re-reading.
                return """
                    Updated '\(SkillToolText.label(skill.name))'. A new version was added; the previous one is kept and \
                    can be restored from the Skills library.

                    ⚠️ This run continues on the version it started with, and `load_skill` will keep \
                    returning that one — reloading will NOT show this edit and does not mean it \
                    failed. You already have the new text: it is exactly what you just supplied. The \
                    new version applies to future runs of every linked profile that does not pin an \
                    older one.
                    """
            }
        }
    }
}
