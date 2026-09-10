// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsVerbTable.swift
//  Devgentic
//
//  One alias table for the five ChatOps verbs — C4.5 of the ChatOps remote-interface plan.
//
//  WHAT C4.5 TURNED OUT TO BE. The plan's graft assumed the refactor would introduce a SECOND
//  parser, leaving un-migrated platforms on the old one so the new parser's tests would be
//  policy-only until C7. That does not apply here: `ChatOpsCommand` was deliberately reused, and
//  `parseDiscord` / `parseSlack` already delegate their TEXT path to `parse` and their button path
//  to `parseCallbackData`. There is one parser and there always was.
//
//  What is NOT shared is the alias set. Three hand-written slash switches had drifted apart:
//
//    | | Telegram | Discord | Slack |
//    | case      | `text.lowercased()` | raw name          | raw name          |
//    | whitespace| trimmed             | not trimmed       | not trimmed       |
//    | leading / | required            | absent (platform) | stripped if present|
//    | help      | `/help`, `/start`   | `help`            | `help`            |
//
//  ⚠️ TWO ENTRY POINTS, AND THE DIFFERENCE IS LOAD-BEARING. Typed text REQUIRES the leading slash;
//  a platform-delivered command name does not. Collapsing them into one lenient lookup would make
//  a user who types the word "conversations" as a message get the conversation list instead of
//  talking to the agent — the alias table's most obvious simplification is a bug.
//
//  ⚠️ DELIBERATE, LATENT-ONLY BEHAVIOUR CHANGES. Discord and Slack slash names are now trimmed and
//  matched case-insensitively, and accept `start` as an alias of `help`. Neither is reachable
//  today: both platforms deliver the lowercase name they registered, and neither registers `start`
//  (which the TEXT path already accepted on all three anyway, since that path is shared). Recorded
//  because "unreachable" is a claim about today's registration, not a guarantee.
//

import Foundation

/// The five verbs a remote user can invoke.
enum ChatOpsVerb: String, CaseIterable, Sendable {
    case conversations
    case newConversation
    case status
    case cancel
    case help
    case profiles
    case use
    /// [Slice 5] `/search <query>` — find a conversation by title.
    case search
    /// [Slice 5] `/history [n]` — read back the last few turns.
    case history

    /// The name to register with a platform's command menu, without a leading slash.
    ///
    /// ⚠️ These five strings are what Telegram's `setMyCommands` and Discord's
    /// `registerSlashCommands` already publish; they are not free to rename.
    var canonicalName: String {
        switch self {
        case .conversations:   return "conversations"
        case .newConversation: return "new"
        case .status:          return "status"
        case .cancel:          return "cancel"
        case .help:            return "help"
        case .profiles:        return "profiles"
        case .use:             return "use"
        case .search:          return "search"
        case .history:         return "history"
        }
    }

    /// Whether the rest of the line is an argument rather than part of the verb.
    ///
    /// ⚠️ FALSE FOR EVERY SHIPPED VERB, deliberately. Today `/status extra` does not match `/status`
    /// — it falls through to `.freeText` and reaches the agent. Making every verb argument-taking
    /// would silently swallow those messages as commands.
    var takesArgument: Bool {
        switch self {
        // ⚠️ `.history` takes an OPTIONAL count. `takesArgument` means "a trailing remainder
        // belongs to this verb", not "one is required" — `/history` alone is answered with a
        // default, exactly as `/use` alone is answered with a usage hint.
        case .use, .search, .history: return true
        case .conversations, .newConversation, .status, .cancel, .help, .profiles: return false
        }
    }

    /// Everything that resolves to this verb, canonical name first. Transcribed from the union of
    /// the three shipping switches.
    var aliases: [String] {
        switch self {
        case .conversations:   return ["conversations", "convos"]
        case .newConversation: return ["new"]
        case .status:          return ["status"]
        case .cancel:          return ["cancel", "stop"]
        // `start` is Telegram's convention — the button Telegram shows on a fresh bot.
        case .help:            return ["help", "start"]
        case .profiles:        return ["profiles"]
        case .use:             return ["use"]
        // ⚠️ `find` is an alias real users reach for before `search`.
        case .search:          return ["search", "find"]
        case .history:         return ["history"]
        }
    }

    /// How the verb is written when offered to a user, argument placeholder included.
    var usage: String {
        guard takesArgument else { return "/\(canonicalName)" }
        // ⚠️ ANGLE BRACKETS MEAN REQUIRED, SQUARE MEAN OPTIONAL — the shell convention users already
        // read. `/history` alone is answered with a default, and advertising it as `/history <n>`
        // would tell them a number is mandatory when it is not.
        return argumentIsOptional
            ? "/\(canonicalName) [\(argumentName)]"
            : "/\(canonicalName) <\(argumentName)>"
    }

    /// Whether the verb still works with nothing after it.
    var argumentIsOptional: Bool {
        switch self {
        case .history: return true
        case .use, .search, .conversations, .newConversation, .status, .cancel, .help, .profiles:
            return false
        }
    }

    /// What the argument is called in help text.
    var argumentName: String {
        switch self {
        case .use:    return "name"
        case .search: return "query"
        case .history: return "n"
        case .conversations, .newConversation, .status, .cancel, .help, .profiles: return ""
        }
    }

    /// One line of `/help`.
    ///
    /// ⚠️ LIVES ON THE TABLE, because `/help` used to hand-write its own list and had already
    /// drifted: it advertised seven verbs against a table of eight, so a shipped command was
    /// undiscoverable. The table's whole purpose is that the parser, `/help` and the platform
    /// registrations read ONE catalogue.
    var helpDescription: String {
        switch self {
        case .conversations:   return "List your conversations"
        case .profiles:        return "Choose which agent answers"
        case .use:             return "Switch profile by name"
        case .search:          return "Find a conversation by title"
        case .history:         return "Read back the last few turns"
        case .newConversation: return "Start a new conversation"
        case .status:          return "Current agent status"
        case .cancel:          return "Stop the active agent"
        case .help:            return "Show this message"
        }
    }

    /// The order `/help` and the platform menus present the verbs in.
    ///
    /// ⚠️ EXPLICIT, not `allCases`. `allCases` follows declaration order, which is an accident of
    /// how the enum grew; this is the order a user reads.
    static var presentationOrder: [ChatOpsVerb] {
        [.conversations, .search, .history, .profiles, .use, .newConversation, .status, .cancel, .help]
    }

    /// The command this verb produces, carrying whatever followed it on the line.
    ///
    /// ⚠️ THIS WAS A ZERO-PARAMETER PROPERTY AND THAT WAS A REAL BLOCKER, not a style wart. Because
    /// it could not express an argument, `ChatOpsCommand.parse` hard-coded
    /// `verb.takesArgument ? .useProfile(argument) : verb.command` — so `.use` was not merely the
    /// only argument-taking verb, it was the only one that COULD exist. A second such verb added to
    /// this table would have parsed its argument correctly and then been dispatched as a profile
    /// name, silently, with the table looking entirely correct.
    ///
    /// ⚠️ Argument-free verbs ignore the argument rather than rejecting it, because they never
    /// receive one: `ChatOpsVerbTable.parse` refuses a trailing remainder for a verb that does not
    /// declare `takesArgument`, so `/status extra` still falls through to `.freeText`.
    func command(argument: String) -> ChatOpsCommand {
        switch self {
        case .conversations:   return .conversations
        case .newConversation: return .newConversation
        case .status:          return .status
        case .cancel:          return .cancel
        case .help:            return .help
        case .profiles:        return .profiles
        // ⚠️ An EMPTY argument is passed through, not rejected here: `/use` and `/search` alone are
        // answered by the service with a usage hint, which is a better reply than "unknown command".
        case .use:             return .useProfile(argument)
        case .search:          return .searchConversations(argument)
        case .history:         return .conversationHistory(argument)
        }
    }
}

enum ChatOpsVerbTable {

    /// A verb typed as text into a chat.
    ///
    /// ⚠️ THE LEADING SLASH IS REQUIRED. Without it, "status" or "new" typed as an ordinary message
    /// would be swallowed as a command instead of reaching the agent.
    nonisolated static func verb(forSlashPrefixedText text: String) -> ChatOpsVerb? {
        parse(slashPrefixedText: text)?.verb
    }

    /// A verb plus whatever followed it on the line.
    ///
    /// ⚠️ THE ARGUMENT IS ONLY TAKEN FOR VERBS THAT DECLARE ONE. `/status extra` must keep falling
    /// through to `.freeText` exactly as it does today — a verb that greedily consumed the rest of
    /// the line would swallow real messages as commands.
    nonisolated static func parse(slashPrefixedText text: String) -> (verb: ChatOpsVerb, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())

        // ⚠️ Split on the FIRST run of whitespace only; the argument keeps its own spaces, because a
        // profile name is routinely several words.
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else {
            return match(body.lowercased()).map { ($0, "") }
        }
        let head = String(body[body.startIndex..<space]).lowercased()
        let argument = String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let verb = match(head), verb.takesArgument else { return nil }
        return (verb, argument)
    }

    /// A command name delivered by the platform's own slash-command mechanism.
    ///
    /// The leading slash is optional: Discord sends a bare name, Slack sends `/name`.
    nonisolated static func verb(forSlashCommandName name: String) -> ChatOpsVerb? {
        var normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("/") { normalized = String(normalized.dropFirst()) }
        return match(normalized)
    }

    private nonisolated static func match(_ normalized: String) -> ChatOpsVerb? {
        guard !normalized.isEmpty else { return nil }
        return ChatOpsVerb.allCases.first { $0.aliases.contains(normalized) }
    }
}
