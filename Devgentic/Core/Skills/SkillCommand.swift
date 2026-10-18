// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommand.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "SkillCommand")

/// A `/skill-name …` command recognised at the very start of a message.
struct SkillCommand: Equatable, Sendable {
    /// The skill's addressable name, without the slash.
    let skillName: String
    /// Everything after the name, trimmed. Empty when the user typed only the command.
    let arguments: String
}

/// One skill the `/` picker offers: the copy a run would actually load.
struct OfferedSkillCommand: Equatable, Sendable {
    /// The library skill id — the picker's row identity.
    let skillID: String
    /// The addressable name a command types.
    let name: String
    let displayName: String
    /// The RESOLVED version's description — a pinned profile shows its pin, not `latest`.
    let description: String
}

/// What `/` offers on one profile, and what the send path will expand: one value, read by both.
struct SkillCommandOffer: Equatable, Sendable {
    /// Exactly the skills the run would get, one per name.
    var skills: [OfferedSkillCommand] = []
    /// Names more than one linked, enabled skill shares. Only one copy of each is in `skills`.
    var collisions: [String] = []

    static let none = SkillCommandOffer()

    /// The names a command may be rewritten for.
    var names: Set<String> { Set(skills.map(\.name)) }

    /// One line per collision, naming the copy that is actually reachable. Shown in the picker rather than only logged,
    /// because that is where the user makes the choice the collision takes away.
    var collisionNotes: [(name: String, note: String)] {
        collisions.compactMap { name in
            guard let reachable = skills.first(where: { $0.name == name }) else { return nil }
            return (name, "Several linked skills are named /\(name) — only '\(reachable.displayName)' is reachable. Rename or unlink the others.")
        }
    }
}

/// Which skills a `/` command can actually reach, for one profile. Asks `SkillResolution`, the function the run uses,
/// so the picker offers exactly what the run will load: linked, enabled, resolvable, one copy per name, pin honoured.
/// Non-agent profiles reach nothing, since their runs register no `load_skill`.
enum SkillCommandReachability {

    /// What this profile's `/` can offer and expand.
    @MainActor
    static func offer(in details: ProfileDetails?, store: SkillStore = .shared) -> SkillCommandOffer {
        guard let details else { return .none }
        let config: AgentConfig
        switch details {
        case .agent(let agentConfig): config = agentConfig
        // `.code` persists selections but the runtime gives Code profiles no skills, so a directive there would name
        // something the run cannot load.
        case .code, .bot, .workflow, .imageGen: return .none
        }
        // `reporting: false`: the composer re-resolves on every keystroke, and the run's own resolution already reports
        // unresolved links and collisions once.
        guard let outcome = SkillResolution.resolve(for: config, profileName: "composer",
                                                    store: store, reporting: false) else { return .none }
        // `SkillManifest` carries no display label; the library does. A skill missing here falls
        // back to its name rather than disappearing from a list the run will still load it from.
        let library = (try? store.fetchRunnableSkills().get()) ?? []
        let displayNames = Dictionary(library.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return SkillCommandOffer(
            skills: outcome.manifests.map {
                // `folderPath` carries the skill id; see `SkillResolution.manifest(for:version:)`.
                OfferedSkillCommand(skillID: $0.folderPath, name: $0.name,
                                    displayName: displayNames[$0.folderPath] ?? $0.name,
                                    description: $0.description)
            },
            collisions: outcome.nameCollisions
        )
    }

    /// Whether the `/` picker should appear at all for this profile. Distinct from having no matches: a profile that can
    /// use skills but has none linked still shows the picker, with an empty state explaining how to link one.
    static func pickerApplies(to details: ProfileDetails?) -> Bool {
        guard let details else { return false }
        if case .agent = details { return true }
        return false
    }
}

enum SkillCommandParser {

    /// Extracts a command from message text, or nil when there is none. Only at offset 0, matching
    /// `TextTriggerAnalyzer`'s rule for `/`; a slash elsewhere is ordinary text. The two rules must move together.
    static func parse(_ text: String) -> SkillCommand? {
        guard text.hasPrefix("/") else { return nil }

        let afterSlash = text.dropFirst()
        // The name runs to the first whitespace. A newline ends it too: `/code-review\nlong brief`
        // is a command with a multi-line argument, which is how anyone writing a real request types.
        let name = afterSlash.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }

        // Shape-validated with the same charset skill names pass at import, so a path fragment such as `/../../etc` never
        // parses as a command and the text is left alone.
        guard (try? SkillFolderScanner.validateSkillNameShape(String(name))) != nil else { return nil }

        let arguments = afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillCommand(skillName: String(name), arguments: arguments)
    }

    /// Rewrites a command into the message actually sent: a directive first, then the user's own words verbatim after a
    /// blank line. The directive says "if it applies", since `/` points at a skill without asserting it fits.
    static func render(_ command: SkillCommand, availableNames: Set<String>) -> String {
        guard availableNames.contains(command.skillName) else {
            // Logged because the user sees their text left alone and cannot tell whether the picker misfired or the skill is not
            // reachable from this profile.
            logger.notice("[SKILL_COMMAND] '/\(command.skillName)' names a skill this profile cannot reach (reachable: \(availableNames.sorted().joined(separator: ", ").isEmpty ? "none" : availableNames.sorted().joined(separator: ", "))). CONSEQUENCE: the message is sent EXACTLY as typed, with no directive added — the model gets a literal slash-word, which is what makes a typo visible to the person best placed to notice it.")
            // Unknown skill: left exactly as typed, since rewriting would send an instruction the model cannot follow and hide
            // the typo.
            return command.arguments.isEmpty
                ? "/\(command.skillName)"
                : "/\(command.skillName) \(command.arguments)"
        }

        logger.notice("[SKILL_COMMAND] '/\(command.skillName)' rewritten into a directive (arguments: \(command.arguments.count) chars). CONSEQUENCE: the model is ASKED to use the skill, not forced — it may still judge it irrelevant and skip it, so a run that ignores the skill is not necessarily a routing bug.")
        let directive = "Use the \(command.skillName) skill for this request, if it applies. Load it with load_skill first."
        return command.arguments.isEmpty ? directive : "\(directive)\n\n\(command.arguments)"
    }
}
