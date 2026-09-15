// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  LoadSkillTool.swift
//  Devgentic
//
//  A system tool that loads the full instructions for a specialized skill by name.
//  Used when the agent detects a task matching one of the available skills listed
//  in the discovery layer of the system prompt.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "LoadSkillTool")

/// Why a skill that was resolved could not then be read.
///
/// ⚠️ Distinct cases on purpose. "Not in the library" means it was deleted between resolution and
/// this call; "version missing" means a pinned snapshot is gone. The remedies differ and the model
/// should be able to tell the user which happened.
enum SkillLoadError: LocalizedError {
    case notInLibrary(String)
    case versionMissing(String, String)

    var errorDescription: String? {
        switch self {
        case .notInLibrary(let name):
            return "Skill '\(name)' is no longer in the library — it was removed after this run started."
        case .versionMissing(let name, let version):
            return "Skill '\(name)' no longer has the version this profile reads (\(version))."
        }
    }
}

/// Loads a skill's full body (and optionally its bundled files) from the library.
/// Registered conditionally in `resolveExecutableTools()` when the profile has skills configured.
///
/// Integration:
/// - The `<available_skills>` block in the system prompt shows skill names + descriptions.
/// - The agent calls `load_skill(skill_name: "...")` when a task matches a skill description.
/// - This tool reads the RESOLVED version out of the library — including a pinned one — and
///   returns its body. A manifest with no `versionID` is a legacy blob reference and is read from
///   disk instead; see `loadPackage`.
/// - The agent then follows the loaded instructions to complete the task.
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

    /// Loads a skill's content, from the library or — for a legacy profile — from disk.
    ///
    /// ⚠️⚠️ THIS BRANCH EXISTS BECAUSE ITS ABSENCE BROKE EVERY SKILL LOAD. When skills moved into
    /// the library, `SkillResolution` started putting a `skill_…` id in `folderPath` (the boundary
    /// type still calls it that), and this tool went on handing it to a disk reader — so the loader
    /// tried to open a file literally named `skill_<uuid>/SKILL.md` and every `load_skill` call
    /// failed. Nothing caught it: the tool's own tests build manifests with real temp folders, which
    /// is the LEGACY contract, and no test covered the resolution-to-load seam. That seam now has
    /// one (`LoadSkillToolTests.testLoadsFromTheLibraryWhenResolutionSuppliedAVersion`).
    ///
    /// ⚠️ Loads the RESOLVED version, not the latest. A profile that pinned an older version must
    /// read that version's body — reading `latestVersion` here would quietly defeat every pin.
    @MainActor
    private static func loadPackage(for manifest: SkillManifest,
                                    resourceRoot: inout URL?) throws -> SkillPackage {
        guard let versionID = manifest.versionID else {
            // Legacy arm: `folderPath` really is a path, from a profile blob that predates the
            // library and has not been through the import sweep.
            return try SkillFolderScanner.loadFullPackage(for: manifest)
        }

        // ⚠️ `try?` FLATTENS the double optional here: `fetchSkill` returns
        // `Result<SkillSD?, _>`, so `try? ....get()` is `SkillSD?`, not `SkillSD??`. One binding is
        // correct and two does not compile — worth stating, because the two readings look alike and
        // the flattening hides the difference between "the store failed" and "no such skill". Both
        // mean the same thing to this caller, which is why collapsing them is acceptable HERE and
        // not in the store itself.
        guard let skill = try? SkillStore.shared.fetchSkill(id: manifest.folderPath).get() else {
            throw SkillLoadError.notInLibrary(manifest.name)
        }
        guard let version = skill.versions.first(where: { $0.id == versionID }) else {
            throw SkillLoadError.versionMissing(manifest.name, versionID)
        }

        // ⚠️⚠️ THE FILES REACH DISK HERE, and the returned text says where. A skill may bundle
        // `scripts/run.py` and instruct the model to execute it; before this, the blob lived only in
        // the database and that path resolved to nothing — while `scripts/` being present is one of
        // the triggers that offers the user a shell tool. See `SkillRuntimeFiles`.
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

    func call(arguments: Arguments) async throws -> String {
        let includeResources = arguments.includeResources ?? false

        guard let manifest = manifests.first(where: { $0.name == arguments.skillName }) else {
            let available = manifests.map(\.name).joined(separator: ", ")
            logger.warning("Skill '\(arguments.skillName)' not found. Available: \(available)")
            return "Error: Skill '\(arguments.skillName)' not found. Available skills: \(available)"
        }

        logger.info("Loading skill: \(manifest.name) (includeResources: \(includeResources))")

        do {
            var resourceRoot: URL?
            let package = try await Self.loadPackage(for: manifest, resourceRoot: &resourceRoot)

            var result = "# Skill: \(package.manifest.name)\n\n\(package.body)"

            // ⚠️ Stated whether or not resource TEXT was requested. The model needs the path to run
            // a bundled script, and that is independent of wanting the files read into context —
            // asking for `include_resources` just to make `scripts/run.py` executable would burn the
            // whole bundle's tokens for a path.
            if let resourceRoot {
                result += "\n\n---\n\nBundled files for this skill are on disk at:\n\(resourceRoot.path)\n\nPaths named in the instructions above (for example `scripts/run.py`) are relative to that directory. Use the absolute path when running one."
            }

            if includeResources && !package.resources.isEmpty {
                result += "\n\n---\n\n# Skill Resources\n"
                for resource in package.resources {
                    result += "\n## \(resource.relativePath)\n\(resource.content)\n"
                }
            }

            logger.info("Skill '\(manifest.name)' loaded successfully (\(result.count) chars, \(package.resources.count) resources)")
            return result
        } catch {
            logger.error("Failed to load skill '\(manifest.name)': \(error.localizedDescription)")
            return "Error loading skill '\(manifest.name)': \(error.localizedDescription)"
        }
    }
}
