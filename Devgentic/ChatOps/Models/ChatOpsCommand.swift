// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsCommand.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation

/// Represents a parsed command from a Telegram message or callback query.
enum ChatOpsCommand {
    // Slash commands (text or bot menu)
    case conversations
    case newConversation
    case status
    case cancel
    case help

    // Inline keyboard callbacks
    case switchConversation(UUID)

    /// [Slice 5] Show the conversation list from this offset. Read-only paging, same tier as
    /// `.conversations`.
    case conversationPage(offset: Int)

    /// [Slice 2] List the profiles a remote user may choose from.
    case profiles
    /// [Slice 2] Bind a profile to the channel's conversation, chosen from the list.
    case selectProfile(UUID)
    /// [Slice 2] Bind a profile by NAME, for users who would rather type than tap.
    case useProfile(String)
    /// [Slice 5] `/search <query>` — conversations whose title matches.
    case searchConversations(String)
    /// [Slice 5] `/history [n]` — the raw argument; the service validates it so a typo gets a
    /// usage hint rather than `.unknown`.
    case conversationHistory(String)
    /// [Slice 4] The user asked to answer a parked clarification with free text. On Discord and
    /// Slack this opens a modal; Telegram never emits it, having force-replied instead.
    case answerClarification(operationID: UUID)
    case approveHITL(operationID: UUID)
    case denyHITL(operationID: UUID)
    /// [D1] A workflow Gate option button — `optionIndex` indexes into the gate's options (an index is
    /// used, not the raw label, to stay within Telegram's 64-byte callback_data limit).
    case gateChoiceHITL(operationID: UUID, optionIndex: Int)

    // Interactive responses
    case clarificationResponse(String)

    // Regular message routed to active agent conversation
    case freeText(String)

    // Pairing
    case pairingAttempt(String)

    // Unrecognized
    case unknown

    // MARK: - Parsing

    /// Parses a Telegram update into a structured command.
    /// Callback data takes priority over message text.
    /// - Parameters:
    ///   - text: The text content of a message (if any).
    ///   - callbackData: The callback_data from an inline keyboard tap (if any).
    ///   - awaitingClarification: Whether the bridge is currently waiting for a clarification response.
    static func parse(
        text: String?,
        callbackData: String?,
        awaitingClarification: Bool = false
    ) -> ChatOpsCommand {

        // 1. Callback data from inline keyboard buttons
        if let data = callbackData {
            return parseCallbackData(data)
        }

        // 2. Text commands
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .unknown
        }

        // 3. Pairing attempt
        //
        // ⚠️⚠️ THE PIN SHAPE IS REQUIRED, AND WITHOUT IT THIS BRANCH ATE ORDINARY PROMPTS. It used to
        // accept `PAIR ` followed by ANYTHING non-empty, case-insensitively — so "Pair these two CSVs
        // on the id column and write the result to out.csv" parsed as
        // `.pairingAttempt("THESE TWO CSVS ON…")`, cleared the tier gate (pairing is allowed at every
        // tier), and was then dropped by all three bridges without a reply: no answer, no error, no
        // typing indicator. `parseSlack` and `parseDiscord` both delegate here for plain text, so it
        // was every platform.
        //
        // ⚠️ SIX ASCII DIGITS, EXACTLY, AND THE WHOLE REMAINDER. `generatePIN()` mints
        // `Int.random(in: 100_000...999_999)`, so a real attempt always has this shape; anything else
        // falls through to the verb table and then to the agent, which is where a sentence belongs.
        // ⚠️ `isASCII` as well as `isNumber`: `Character.isNumber` is true for Arabic-Indic and other
        // non-ASCII numerals, which a PIN never contains.
        //
        // ⚠️ THIS IS NOT `PairingAttemptPolicy.classify`, WHICH IS DELIBERATELY LOOSER. That one runs
        // only inside an open pairing window and treats `PAIR <anything>` as a failed attempt on
        // purpose — someone fumbling the format is still someone trying to pair, and it needs to see
        // them. This is the always-on command parser, where the same looseness is a swallowed prompt.
        let upper = text.uppercased()
        if upper.hasPrefix("PAIR ") {
            let pin = String(upper.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return .pairingAttempt(pin)
            }
            // Not a PIN — fall through so the verb table and free text get their turn.
        }

        // 4. Slash commands — one alias table, shared with the Discord and Slack entry points.
        //    ⚠️ The leading slash stays REQUIRED here: bare "status" is a message to the agent.
        //
        //    ⚠️⚠️ THIS MOVED ABOVE THE CLARIFICATION BRANCH IN SLICE 4, AND IT IS A BUG FIX, NOT A
        //    TIDY-UP. The clarification branch swallowed EVERY message while a run was parked —
        //    including `/cancel`. A remote user therefore could not stop a parked run from chat at
        //    all: the command intended to end the wait was consumed as the answer to it, which
        //    resumed the run rather than cancelling it, and `/status`, `/new` and `/conversations`
        //    were equally unreachable for as long as the agent waited.
        //
        //    ⚠️ An answer that merely LOOKS like a command is unaffected: the table matches known
        //    verbs only, so answering "/usr/local/bin" to "which path?" still falls through to the
        //    clarification branch below.
        if let (verb, argument) = ChatOpsVerbTable.parse(slashPrefixedText: text) {
            // ⚠️ Only argument-taking verbs reach here with a non-empty `argument`; for the rest the
            // table refuses a trailing remainder, so `/status extra` still falls through to
            // `.freeText` and reaches the agent, exactly as it does today.
            // ⚠️ WAS `verb.takesArgument ? .useProfile(argument) : verb.command`, which made
            // `.use` the only argument-taking verb that could exist — any second one would have
            // been dispatched as a profile name. The verb now names its own command.
            return verb.command(argument: argument)
        }

        // 5. Awaiting a clarification → plain text is the answer.
        //    ⚠️ THIS IS THE IMPRECISE FALLBACK, and it is why slice 4 exists. It cannot say WHICH
        //    clarification is being answered: the caller derives that from the provider's single
        //    conversation cursor and then takes the oldest pending item. A reply carrying
        //    `reply_to_message` names the operation exactly and is handled before parsing ever
        //    reaches here; this remains for a user who types instead of replying.
        if awaitingClarification {
            if text.lowercased() == "/skip" {
                return .clarificationResponse("")
            }
            return .clarificationResponse(text)
        }

        // 6. Free-text message → route to active agent conversation
        return .freeText(text)
    }

    // MARK: - Discord Parsing

    /// Parses a Discord interaction or message into a structured command.
    /// Handles slash commands (via `slashCommandName`), button callbacks (via `customID`),
    /// and plain text messages (via `text`).
    static func parseDiscord(
        text: String? = nil,
        customID: String? = nil,
        slashCommandName: String? = nil,
        awaitingClarification: Bool = false
    ) -> ChatOpsCommand {
        // 1. Button callback (custom_id from INTERACTION_CREATE)
        if let id = customID {
            return parseCallbackData(id)
        }

        // 2. Slash command (from INTERACTION_CREATE type 2) — same alias table as Telegram's text
        //    path, with the leading slash optional because Discord delivers a bare name.
        //
        // ⚠️ NO ARGUMENT IS AVAILABLE ON THIS PATH, and that is a platform-model gap rather than a
        // choice: `DiscordSlashCommand` has no `options` field to DECLARE a parameter and
        // `DiscordInteractionData` has none to READ one, so a registered `/search` would arrive
        // with nothing after it. Argument-taking verbs are therefore not registered as Discord
        // slash commands at all — they are reachable by typing `/search foo` as an ordinary
        // message, which routes through `parse` above and does carry the argument.
        if let name = slashCommandName, let verb = ChatOpsVerbTable.verb(forSlashCommandName: name) {
            return verb.command(argument: "")
        }

        // 3. Plain text message (from MESSAGE_CREATE)
        // Reuses the same text parsing as Telegram
        return parse(text: text, callbackData: nil, awaitingClarification: awaitingClarification)
    }

    // MARK: - Slack Parsing

    /// Parses a Slack event or interaction into a structured command.
    /// Handles slash commands, button action_ids, and plain text messages.
    /// - Parameter slashArgument: the text Slack sends after the command name
    ///   (`SlackSlashCommandPayload.text`).
    ///
    /// ⚠️ SLACK HAS ALWAYS SENT THIS AND THE BRIDGE ALWAYS DISCARDED IT, passing only
    /// `payload.command`. Until slice 5 nothing needed it, because `.use` was reachable only as a
    /// typed message; a registered `/use Coder` on Slack silently became `/use` with no name.
    static func parseSlack(
        text: String? = nil,
        actionID: String? = nil,
        slashCommand: String? = nil,
        slashArgument: String? = nil,
        awaitingClarification: Bool = false
    ) -> ChatOpsCommand {
        // 1. Button action_id (from block_actions interactive payload)
        if let id = actionID {
            return parseCallbackData(id)
        }

        // 2. Slash command (from slash_commands Socket Mode payload) — same alias table. Slack
        //    delivers "/name"; the table strips the slash, as the hand-written switch here did.
        if let cmd = slashCommand, let verb = ChatOpsVerbTable.verb(forSlashCommandName: cmd) {
            return verb.command(
                argument: slashArgument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }

        // 3. Plain text message (from events_api)
        return parse(text: text, callbackData: nil, awaitingClarification: awaitingClarification)
    }

    // MARK: - Callback Data Parsing

    // Shared across Telegram (callback_data), Discord (custom_id), and Slack (action_id).
    static func parseCallbackData(_ data: String) -> ChatOpsCommand {
        if data.hasPrefix("use:") {
            let uuidString = String(data.dropFirst("use:".count))
            if let id = UUID(uuidString: uuidString) { return .selectProfile(id) }
            return .unknown
        }

        if data.hasPrefix("page:") {
            let raw = String(data.dropFirst("page:".count))
            // ⚠️ A NEGATIVE OR JUNK OFFSET IS REFUSED, not clamped. `page:-1` reaching the store
            // would be clamped there anyway, but a token that decodes to something the user never
            // tapped is how a stale button silently jumps somewhere unexpected.
            if let offset = Int(raw), offset >= 0 { return .conversationPage(offset: offset) }
            return .unknown
        }
        if data.hasPrefix("switch:") {
            let uuidString = String(data.dropFirst(7))
            if let uuid = UUID(uuidString: uuidString) {
                return .switchConversation(uuid)
            }
            return .unknown
        }

        // HITL callbacks: "hitl:approve:<operationID>" or "hitl:deny:<operationID>"
        if data.hasPrefix("hitl:answer:") {
            let uuidString = String(data.dropFirst("hitl:answer:".count))
            if let opID = UUID(uuidString: uuidString) { return .answerClarification(operationID: opID) }
            return .unknown
        }
        if data.hasPrefix("hitl:approve:") {
            let uuidString = String(data.dropFirst("hitl:approve:".count))
            if let opID = UUID(uuidString: uuidString) { return .approveHITL(operationID: opID) }
            return .unknown
        }
        if data.hasPrefix("hitl:deny:") {
            let uuidString = String(data.dropFirst("hitl:deny:".count))
            if let opID = UUID(uuidString: uuidString) { return .denyHITL(operationID: opID) }
            return .unknown
        }
        // [D1] Gate option button: "hitl:gate:<operationID>:<optionIndex>"
        if data.hasPrefix("hitl:gate:") {
            let rest = String(data.dropFirst("hitl:gate:".count))   // "<UUID>:<idx>"
            if let sep = rest.lastIndex(of: ":"),
               let opID = UUID(uuidString: String(rest[rest.startIndex..<sep])),
               let idx = Int(rest[rest.index(after: sep)...]) {
                return .gateChoiceHITL(operationID: opID, optionIndex: idx)
            }
            return .unknown
        }

        switch data {
        case "action:conversations":
            return .conversations
        case "action:new":
            return .newConversation
        case "action:status":
            return .status
        case "action:cancel":
            return .cancel
        default:
            return .unknown
        }
    }
}
