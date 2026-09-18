// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SkillCommand.swift
//  Devgentic
//
//  Reading `/skill-name the rest of the message` out of what the user typed.
//
//  ## What `/` does, stated plainly
//
//  It is a DIRECTIVE, not an invocation. Selecting `/code-review` rewrites the message so the model
//  is told, in the user turn, to use that skill — and the model then calls `load_skill` the way it
//  would have anyway. It does not pre-load the body, and it does not bypass the model's choice.
//
//  ⚠️ That distinction matters and must not be blurred in the UI. A capable model follows the
//  directive essentially always; a small local one may ignore it, and the user should see a normal
//  message that plainly says what was asked rather than believing a command was executed.
//
//  A deterministic pre-load — injecting the resolved body before the turn starts — is a separate
//  change: it needs a field threaded from `AgentConnect` through `AgentInput` into `SemanticContext`
//  and the prompt layer. This is the honest 80% that works with the machinery already shipped.
//
//  ## Why the parse lives here rather than in the composer
//
//  Three places need to agree about what "the message starts with a skill command" means: the
//  trigger that offers the picker, the rewrite on send, and anything later that wants to show the
//  user what was invoked. A regex in a SwiftUI view is a fourth definition waiting to disagree.
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

/// Which skills a `/` command can actually reach, for one profile.
///
/// ⚠️⚠️ ONE DEFINITION, USED BY BOTH SIDES, BECAUSE THEY DISAGREED. The picker listed the whole
/// library while the send-path rewrite accepted only names the profile had LINKED, so choosing an
/// offered skill that happened not to be linked left the text exactly as typed and shipped a literal
/// `/data-cleaner do the thing` to the model. The picker was advertising skills the send path would
/// refuse. Whatever this returns is what the user is offered AND what will expand — a divergence is
/// no longer representable.
///
/// ⚠️ Non-agent profiles reach nothing. Bot, workflow and imageGen runs register no `load_skill`, so
/// a directive naming a skill would be an instruction the model cannot carry out.
enum SkillCommandReachability {

    /// The addressable names this profile can be given a directive about.
    static func reachableNames(in details: ProfileDetails?) -> Set<String> {
        guard let details else { return [] }
        let selections: [SkillSelection]
        switch details {
        case .agent(let config): selections = config.skillSelections ?? []
        // ⚠️ `.code` persists selections but the runtime gives Code profiles no skills, so a
        // directive there would name something the run cannot load. Offering it would be the same
        // lie this type exists to prevent.
        case .code, .bot, .workflow, .imageGen: return []
        }
        // Disabled and not-yet-re-linked selections are excluded: neither reaches a run.
        return Set(selections.filter { $0.isEnabled && !$0.isAwaitingRelink }.map(\.name))
    }

    /// Whether the `/` picker should appear at all for this profile.
    ///
    /// ⚠️ Distinct from "has no matches". A profile that cannot use skills should not show a picker
    /// suggesting it might; a profile that can, but has linked none, SHOULD — with an empty state
    /// that says how to link one.
    static func pickerApplies(to details: ProfileDetails?) -> Bool {
        guard let details else { return false }
        if case .agent = details { return true }
        return false
    }
}

enum SkillCommandParser {

    /// Extracts a command from message text, or nil when there is none.
    ///
    /// ⚠️ ONLY at offset 0, matching `TextTriggerAnalyzer`'s rule for `/`. A slash anywhere else is
    /// ordinary text — a path, a date, an "and/or" — and treating it as a command would rewrite
    /// someone's sentence. The two rules are deliberately identical; if one moves, the other must.
    static func parse(_ text: String) -> SkillCommand? {
        guard text.hasPrefix("/") else { return nil }

        let afterSlash = text.dropFirst()
        // The name runs to the first whitespace. A newline ends it too: `/code-review\nlong brief`
        // is a command with a multi-line argument, which is how anyone writing a real request types.
        let name = afterSlash.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }

        // ⚠️ Shape-validated, not merely non-empty. The charset is the same one every skill name
        // passes at import, so `/../../etc` cannot parse as a command at all — and a user who typed
        // a path fragment gets their text left alone rather than silently rewritten.
        guard (try? SkillFolderScanner.validateSkillNameShape(String(name))) != nil else { return nil }

        let arguments = afterSlash.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillCommand(skillName: String(name), arguments: arguments)
    }

    /// Rewrites a command into the message actually sent.
    ///
    /// ⚠️ The user's own words come LAST and verbatim. An earlier shape put them inside the
    /// directive sentence, which meant a multi-paragraph request was read as one clause of an
    /// instruction — the model summarised it instead of doing it. Directive first, request after,
    /// separated by a blank line, so the request is still the request.
    ///
    /// ⚠️ Says "if it applies". A skill the model judges irrelevant should be skipped, not forced:
    /// `/` is the user pointing at a skill, not asserting it fits, and a model made to use a
    /// mismatched skill produces confidently wrong work.
    static func render(_ command: SkillCommand, availableNames: Set<String>) -> String {
        guard availableNames.contains(command.skillName) else {
            // ⚠️ Logged because the user SEES their text left alone and cannot tell whether the
            // picker misfired or the skill genuinely is not reachable from this profile.
            logger.notice("[SKILL_COMMAND] '/\(command.skillName)' names a skill this profile cannot reach (reachable: \(availableNames.sorted().joined(separator: ", ").isEmpty ? "none" : availableNames.sorted().joined(separator: ", "))). CONSEQUENCE: the message is sent EXACTLY as typed, with no directive added — the model gets a literal slash-word, which is what makes a typo visible to the person best placed to notice it.")
            // ⚠️ UNKNOWN SKILL: left EXACTLY as typed. Rewriting text that names a skill this
            // profile cannot reach would send an instruction the model cannot follow, and hide the
            // typo from the person best placed to notice it.
            return command.arguments.isEmpty
                ? "/\(command.skillName)"
                : "/\(command.skillName) \(command.arguments)"
        }

        logger.notice("[SKILL_COMMAND] '/\(command.skillName)' rewritten into a directive (arguments: \(command.arguments.count) chars). CONSEQUENCE: the model is ASKED to use the skill, not forced — it may still judge it irrelevant and skip it, so a run that ignores the skill is not necessarily a routing bug.")
        let directive = "Use the \(command.skillName) skill for this request, if it applies. Load it with load_skill first."
        return command.arguments.isEmpty ? directive : "\(directive)\n\n\(command.arguments)"
    }
}
