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
    case approveHITL(operationID: UUID)
    case denyHITL(operationID: UUID)

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

        // 3. If awaiting clarification, treat any text as the response
        if awaitingClarification {
            if text.lowercased() == "/skip" {
                return .clarificationResponse("")
            }
            return .clarificationResponse(text)
        }

        // 4. Pairing attempt
        let upper = text.uppercased()
        if upper.hasPrefix("PAIR ") {
            let pin = String(upper.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !pin.isEmpty else { return .unknown }
            return .pairingAttempt(pin)
        }

        // 5. Slash commands
        let lowered = text.lowercased()
        switch lowered {
        case "/conversations", "/convos":
            return .conversations
        case "/new":
            return .newConversation
        case "/status":
            return .status
        case "/cancel", "/stop":
            return .cancel
        case "/help", "/start":
            return .help
        default:
            break
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

        // 2. Slash command (from INTERACTION_CREATE type 2)
        if let name = slashCommandName {
            switch name {
            case "conversations", "convos":
                return .conversations
            case "new":
                return .newConversation
            case "status":
                return .status
            case "cancel", "stop":
                return .cancel
            case "help":
                return .help
            default:
                break
            }
        }

        // 3. Plain text message (from MESSAGE_CREATE)
        // Reuses the same text parsing as Telegram
        return parse(text: text, callbackData: nil, awaitingClarification: awaitingClarification)
    }

    // MARK: - Slack Parsing

    /// Parses a Slack event or interaction into a structured command.
    /// Handles slash commands, button action_ids, and plain text messages.
    static func parseSlack(
        text: String? = nil,
        actionID: String? = nil,
        slashCommand: String? = nil,
        awaitingClarification: Bool = false
    ) -> ChatOpsCommand {
        // 1. Button action_id (from block_actions interactive payload)
        if let id = actionID {
            return parseCallbackData(id)
        }

        // 2. Slash command (from slash_commands Socket Mode payload)
        if let cmd = slashCommand {
            let normalized = cmd.hasPrefix("/") ? String(cmd.dropFirst()) : cmd
            switch normalized {
            case "conversations", "convos":
                return .conversations
            case "new":
                return .newConversation
            case "status":
                return .status
            case "cancel", "stop":
                return .cancel
            case "help":
                return .help
            default:
                break
            }
        }

        // 3. Plain text message (from events_api)
        return parse(text: text, callbackData: nil, awaitingClarification: awaitingClarification)
    }

    // MARK: - Callback Data Parsing

    // Shared across Telegram (callback_data), Discord (custom_id), and Slack (action_id).
    static func parseCallbackData(_ data: String) -> ChatOpsCommand {
        if data.hasPrefix("switch:") {
            let uuidString = String(data.dropFirst(7))
            if let uuid = UUID(uuidString: uuidString) {
                return .switchConversation(uuid)
            }
            return .unknown
        }

        // HITL callbacks: "hitl:approve:<operationID>" or "hitl:deny:<operationID>"
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
