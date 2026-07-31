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

/// Loads a skill's full SKILL.md body (and optionally bundled resources) from disk.
/// Registered conditionally in `resolveExecutableTools()` when the profile has skills configured.
///
/// Integration:
/// - The `<available_skills>` block in the system prompt shows skill names + descriptions.
/// - The agent calls `load_skill(skill_name: "...")` when a task matches a skill description.
/// - This tool reads SKILL.md from disk (always fresh, never cached) and returns the full body.
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

    func call(arguments: Arguments) async throws -> String {
        let includeResources = arguments.includeResources ?? false

        guard let manifest = manifests.first(where: { $0.name == arguments.skillName }) else {
            let available = manifests.map(\.name).joined(separator: ", ")
            logger.warning("Skill '\(arguments.skillName)' not found. Available: \(available)")
            return "Error: Skill '\(arguments.skillName)' not found. Available skills: \(available)"
        }

        logger.info("Loading skill: \(manifest.name) (includeResources: \(includeResources))")

        do {
            let package = try SkillFolderScanner.loadFullPackage(for: manifest)

            var result = "# Skill: \(package.manifest.name)\n\n\(package.body)"

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
