// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  UpdateSkillTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "UpdateSkillTool")

/// Lets an agent rewrite the instructions of a skill the user marked agent-writable, appending an
/// immutable new version. A skill body is injected into the model's context and the library is global,
/// so edits reach every linked profile.
struct UpdateSkillTool: DevgenticTool {

    let name = "update_skill"

    /// Agent skill instruction updates belong in Developer & Diagnostics.
    let category = "Developer & Diagnostics"

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
            // Resolves the target from the library, never from an argument: the destination is an opaque id, so
            // there is no path to traverse.
            guard let skills = try? SkillStore.shared.fetchRunnableSkills().get() else {
                return "Error: the skill library could not be read, so no skill could be updated. Nothing was changed."
            }
            let matches = skills.filter { $0.name == arguments.skillName }
            guard let skill = matches.first else {
                // The name is labelled: `skill_name` is model-supplied and may contain newlines, and this string is a
                // tool result read as markdown. `SkillToolText.label` is shared with `LoadSkillTool`.
                let available = skills.map { SkillToolText.label($0.name) }.sorted().joined(separator: ", ")
                return "Error: no skill named '\(SkillToolText.label(arguments.skillName))'. Available: \(available.isEmpty ? "none" : available)."
            }
            // Refuses on ambiguity: skills key on an opaque id but this tool addresses them by name, so an
            // approved edit must not land in the wrong skill.
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

            // Carries the current description, declaration and files forward unchanged: a version is a complete
            // snapshot. This tool rewrites the instruction body and nothing else.
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
                // Does not tell the model to reload: `LoadSkillTool` reads the version this run resolved, so a reload
                // returns the pre-edit body and would prompt a duplicate write.
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
