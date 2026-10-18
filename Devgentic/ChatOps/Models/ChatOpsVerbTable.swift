// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsVerbTable.swift
//  Devgentic
//
//  Created by Raj Singh.
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
    /// These match what Telegram's `setMyCommands` and Discord's `registerSlashCommands` publish.
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
    /// A verb without an argument does not match when text follows it: `/status extra` falls through to `.freeText`.
    var takesArgument: Bool {
        switch self {
        // `.history` takes an optional count; `takesArgument` means a trailing remainder belongs
        // to the verb, not that one is required.
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
        // `find` is an alias users reach for before `search`.
        case .search:          return ["search", "find"]
        case .history:         return ["history"]
        }
    }

    /// How the verb is written when offered to a user, argument placeholder included.
    var usage: String {
        guard takesArgument else { return "/\(canonicalName)" }
        // Angle brackets mean required, square brackets optional, so `/history` is not advertised as needing a number.
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
    /// Lives on the table so the parser, `/help` and the platform registrations read one catalogue.
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
    /// Explicit rather than `allCases`, which follows declaration order.
    static var presentationOrder: [ChatOpsVerb] {
        [.conversations, .search, .history, .profiles, .use, .newConversation, .status, .cancel, .help]
    }

    /// The command this verb produces, carrying whatever followed it on the line.
    /// Argument-free verbs ignore the argument; `ChatOpsVerbTable.parse` refuses a remainder for
    /// verbs that do not declare `takesArgument`.
    func command(argument: String) -> ChatOpsCommand {
        switch self {
        case .conversations:   return .conversations
        case .newConversation: return .newConversation
        case .status:          return .status
        case .cancel:          return .cancel
        case .help:            return .help
        case .profiles:        return .profiles
        // An empty argument is passed through: the service answers `/use` and `/search` alone with a usage hint.
        case .use:             return .useProfile(argument)
        case .search:          return .searchConversations(argument)
        case .history:         return .conversationHistory(argument)
        }
    }
}

enum ChatOpsVerbTable {

    /// A verb typed as text into a chat.
    /// The leading slash is required so "status" or "new" typed as an ordinary message reaches the agent.
    nonisolated static func verb(forSlashPrefixedText text: String) -> ChatOpsVerb? {
        parse(slashPrefixedText: text)?.verb
    }

    /// A verb plus whatever followed it on the line.
    /// The argument is taken only for verbs that declare one, so `/status extra` still falls through to `.freeText`.
    nonisolated static func parse(slashPrefixedText text: String) -> (verb: ChatOpsVerb, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())

        // Splits on the first run of whitespace only; the argument keeps its own spaces (profile names are often several words).
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
