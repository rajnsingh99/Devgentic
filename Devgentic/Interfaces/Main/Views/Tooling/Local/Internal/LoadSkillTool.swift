// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LoadSkillTool.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "LoadSkillTool")

/// Why a skill that was resolved could not then be read.
/// Distinct cases on purpose: "not in the library" means it was deleted after resolution, "version missing" that a pinned
/// snapshot is gone; the remedies differ and the model can tell the user which happened.
enum SkillLoadError: LocalizedError {
    case notInLibrary(String)
    case versionMissing(String, String)
    /// A manifest with no library version — only a folder scan produces one, and it never
    /// reaches a run.
    case notResolvedFromLibrary(String)

    var errorDescription: String? {
        switch self {
        case .notInLibrary(let name):
            return "Skill '\(name)' is no longer in the library — it was removed after this run started."
        case .versionMissing(let name, let version):
            return "Skill '\(name)' no longer has the version this profile reads (\(version))."
        case .notResolvedFromLibrary(let name):
            return "Skill '\(name)' was not resolved from the skill library, so there is nothing to load."
        }
    }
}

/// Loads a skill's full body (and optionally its bundled files) from the library.
/// Registered conditionally when the profile has skills configured; the agent calls `load_skill(skill_name:)` when a task
/// matches a skill description, and reads the resolved (possibly pinned) version.
struct LoadSkillTool: DevgenticTool {

    // MARK: - Properties

    let name = "load_skill"
    /// Never surfaced in the Tool Library — this tool is injected by `AgentConnect` for the
    /// run itself, not chosen by a user. The category is required by `DevgenticTool` and
    /// exists so no tool can silently fall into a default bucket.
    let category = "Internal"
    let description = """
        Load the full instructions for a specialized skill by name. \
        Use this when a user's request matches one of the available skills listed in your context. \
        Returns the detailed process steps, requirements, and output format for the skill.
        """

    /// The skill manifests available for loading (passed at registration time).
    let manifests: [SkillManifest]

    // MARK: - Type Definitions

    struct Arguments: Decodable, Sendable {
        let skillName: String
        let includeResources: Bool?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { return nil }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)

            // ROBUST PARSING: Accept common key naming conventions
            var foundName: String? = nil
            let nameKeys = ["skill_name", "skillName", "name", "skill"]

            for key in nameKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(String.self, forKey: codingKey) {
                    foundName = val
                    break
                }
            }

            guard let validName = foundName else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing property 'skill_name'. Checked aliases: \(nameKeys.joined(separator: ", "))"
                    )
                )
            }

            self.skillName = validName

            // Optional: include_resources
            let resourceKeys = ["include_resources", "includeResources", "resources"]
            var foundResources: Bool? = nil
            for key in resourceKeys {
                if let codingKey = DynamicKey(stringValue: key),
                   let val = try? container.decode(Bool.self, forKey: codingKey) {
                    foundResources = val
                    break
                }
            }
            self.includeResources = foundResources
        }
    }

    // MARK: - Schema

    var parameterSchema: ToolParameters {
        return SchemaBuilder.object(
            properties: [
                ("skill_name", "string", "The name of the skill to load (must match an available skill name)"),
                ("include_resources", "boolean", "Whether to also load reference files and templates (default: false)")
            ],
            required: ["skill_name"]
        )
    }

    // MARK: - Execution

    // Why: a pinned profile must read its pinned version's body; reading `latestVersion` would defeat every pin.
    /// Loads a skill's content from the library, using the resolved version rather than the latest.
    @MainActor
    private static func loadPackage(for manifest: SkillManifest,
                                    resourceRoot: inout URL?) throws -> SkillPackage {
        guard let versionID = manifest.versionID else {
            throw SkillLoadError.notResolvedFromLibrary(manifest.name)
        }

        // `try?` flattens the double optional: `fetchSkill` returns `Result<SkillSD?, _>`, so this is `SkillSD?`.
        // A store failure and a missing skill mean the same thing to this caller.
        guard let skill = try? SkillStore.shared.fetchSkill(id: manifest.folderPath).get() else {
            throw SkillLoadError.notInLibrary(manifest.name)
        }
        guard let version = skill.versions.first(where: { $0.id == versionID }) else {
            throw SkillLoadError.versionMissing(manifest.name, versionID)
        }

        // The files are written to disk here and the returned text says where, so a bundled `scripts/run.py` the skill
        // tells the model to run actually exists on disk (see `SkillRuntimeFiles`).
        resourceRoot = SkillRuntimeFiles.materialize(version: version, name: skill.name)

        return SkillPackage(
            manifest: manifest,
            body: version.body,
            resources: version.orderedFiles.map { file in
                SkillResource(
                    relativePath: file.relativePath,
                    // A binary resource has no text to give the model; naming it is more useful
                    // than an empty string that reads as an empty file.
                    content: file.asText ?? "(binary file, \(file.content.count) bytes — not shown)",
                    type: SkillResourceType.forPath(file.relativePath)
                )
            }
        )
    }

    /// This tool's labels go through `SkillToolText.label` — see that type for what a label is and
    /// why a body is never one. It lives there rather than here because `UpdateSkillTool` needs the
    /// identical treatment and did not get it while this was private.
    private static func label(_ raw: String, limit: Int = 200) -> String {
        SkillToolText.label(raw, limit: limit)
    }

    func call(arguments: Arguments) async throws -> String {
        let includeResources = arguments.includeResources ?? false

        guard let manifest = manifests.first(where: { $0.name == arguments.skillName }) else {
            let available = manifests.map { Self.label($0.name) }.joined(separator: ", ")
            logger.error("[SKILL_LOAD] MISS: the model asked for '\(SkillToolText.label(arguments.skillName))' and this run resolved \(manifests.count) skill(s): \(available.isEmpty ? "none" : available). CONSEQUENCE: nothing was loaded and the model is told which names it COULD have used — a miss here means the profile does not link that skill, or the model invented the name from the task rather than from <available_skills>.")
            // The requested name is echoed so the model sees its own typo; it is model-supplied (unbounded, may contain newlines),
            // so it is echoed as a label.
            return "Error: Skill '\(Self.label(arguments.skillName))' not found. Available skills: \(available)"
        }

        // The version id is the correlation key: pinned and unpinned profiles loading the "same" skill get different bodies.
        logger.notice("[SKILL_LOAD] Loading '\(manifest.name)' [skill \(manifest.folderPath)] version=\(manifest.versionID ?? "none") includeResources=\(includeResources) declaredTools=\(manifest.allowedTools?.joined(separator: ",") ?? "none") bundledFiles=\(manifest.resourceCount). CONSEQUENCE: the body of THIS version reaches the model — a profile pinning an older version reads that one, so compare this id against the library before concluding an edit did not take.")

        do {
            var resourceRoot: URL?
            let package = try await Self.loadPackage(for: manifest, resourceRoot: &resourceRoot)

            // The name is a label (a heading); the body is verbatim. See `label`.
            var result = "# Skill: \(Self.label(package.manifest.name))\n\n\(package.body)"

            // Stated whether or not resource text was requested: the model needs the path to run a bundled script,
            // independent of wanting the files read into context.
            if let resourceRoot {
                result += "\n\n---\n\nBundled files for this skill are on disk at:\n\(resourceRoot.path)\n\nPaths named in the instructions above (for example `scripts/run.py`) are relative to that directory. Use the absolute path when running one."
            }

            if includeResources && !package.resources.isEmpty {
                result += "\n\n---\n\n# Skill Resources\n"
                for resource in package.resources {
                    // The path is a label (a heading) as defence in depth: a control character in a stored path could forge a heading,
                    // while the content stays verbatim.
                    result += "\n## \(Self.label(resource.relativePath))\n\(resource.content)\n"
                }
            }

            logger.notice("[SKILL_LOAD] Loaded '\(manifest.name)' [skill \(manifest.folderPath)] version=\(manifest.versionID ?? "none"): \(result.count) chars, \(package.resources.count) resource(s), filesOnDisk=\(resourceRoot?.path ?? "NONE"). CONSEQUENCE: this text is now in the model's context for the rest of the run\(resourceRoot == nil && package.resources.isEmpty == false ? " — but the bundled files could NOT be written to disk, so any path the instructions name does not exist" : "").")
            return result
        } catch {
            logger.error("[SKILL_LOAD] FAILED to load '\(manifest.name)' [skill \(manifest.folderPath)] version=\(manifest.versionID ?? "none"): \(error.localizedDescription). CONSEQUENCE: the model gets an error string instead of instructions and will most likely proceed WITHOUT the skill — the skill was resolved at run start, so this means it was deleted, un-drafted or re-versioned mid-run, or a pinned version is gone.")
            // Labelled too: the name comes from the manifest and `SkillLoadError` messages interpolate it, so a hostile name
            // would otherwise reach the model through the failure path.
            return "Error loading skill '\(Self.label(manifest.name))': \(Self.label(error.localizedDescription, limit: 400))"
        }
    }
}
