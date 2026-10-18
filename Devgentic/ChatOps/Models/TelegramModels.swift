// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  TelegramModels.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Telegram Bot API Response Wrapper

/// Generic wrapper for all Telegram Bot API responses.
struct TelegramResponse<T: Decodable>: Decodable {
    let ok: Bool
    let result: T?
    let description: String?
    let error_code: Int?
}

// MARK: - Update & Polling

/// Represents a single update received from Telegram's `getUpdates` long-poll.
struct TelegramUpdate: Codable {
    let update_id: Int
    let message: TelegramMessage?
    let callback_query: TelegramCallbackQuery?

    /// Convenience: the chat ID from either a message or a callback query.
    var chatID: Int64? {
        message?.chat.id ?? callback_query?.message?.chat.id
    }
}

// MARK: - Force Reply

// Why: Telegram has no platform-level modal; ForceReply opens no dialog and is the closest equivalent
/// Telegram's `ForceReply`: pre-focuses the reply box aimed at this message so the answer carries `reply_to_message`.
/// That correlation lets an answer name the operation it answers instead of relying on a provider-wide cursor.
struct ForceReply: Codable {

    let force_reply: Bool

    /// Greyed placeholder inside the reply box. Telegram caps it at 64 characters.
    let input_field_placeholder: String?

    // Why: `selective: true` would force the reply box for nobody on a mirrored prompt
    /// Always false: `selective` targets only @mentioned users or the original sender of a replied-to message.
    /// ChatOps is paired to one chat and one human, so a non-selective force reply reaches the right person.
    let selective: Bool

    init(placeholder: String? = nil) {
        self.force_reply = true
        self.input_field_placeholder = placeholder.map { String($0.prefix(64)) }
        self.selective = false
    }
}

// MARK: - Message

struct TelegramMessage: Codable {
    let message_id: Int
    let from: TelegramUser?
    let chat: TelegramChat
    let date: Int
    let text: String?

    // Why: a separate type, not `TelegramMessage?`: Swift rejects a value type that recursively contains itself
    /// The message this one replies to, when the user used Telegram's reply affordance.
    /// Only `message_id` is carried, because it is the key that ties an answer to its operation.
    let reply_to_message: TelegramReplyReference?
}

/// The subset of a replied-to message that correlation needs. See `TelegramMessage.reply_to_message`
/// for why this is not just another `TelegramMessage`.
struct TelegramReplyReference: Codable {
    let message_id: Int
}

// MARK: - Chat

struct TelegramChat: Codable {
    let id: Int64
    let type: String
    let title: String?
    let first_name: String?
}

// MARK: - User

struct TelegramUser: Codable {
    let id: Int64
    let is_bot: Bool
    let first_name: String
    let username: String?
}

// MARK: - Callback Query (Inline Keyboard Taps)

struct TelegramCallbackQuery: Codable {
    let id: String
    let from: TelegramUser
    let message: TelegramMessage?
    let data: String?
}

// MARK: - Keyboard Markup Types

/// Inline keyboard attached below a specific bot message.
struct InlineKeyboardMarkup: Codable {
    let inline_keyboard: [[InlineKeyboardButton]]
}

struct InlineKeyboardButton: Codable {
    let text: String
    let callback_data: String?

    init(text: String, callbackData: String) {
        self.text = text
        self.callback_data = callbackData
    }
}

/// Persistent reply keyboard replacing the user's phone keyboard.
struct ReplyKeyboardMarkup: Codable {
    let keyboard: [[KeyboardButton]]
    let resize_keyboard: Bool?
    let one_time_keyboard: Bool?
    let is_persistent: Bool?

    init(keyboard: [[KeyboardButton]], resize: Bool = true, persistent: Bool = true) {
        self.keyboard = keyboard
        self.resize_keyboard = resize
        self.one_time_keyboard = false
        self.is_persistent = persistent
    }
}

struct KeyboardButton: Codable {
    let text: String
}

// MARK: - Bot Command (for setMyCommands)

struct BotCommand: Codable {
    let command: String
    let description: String
}

// MARK: - Send Message Request

/// Payload for the `sendMessage` API call.
struct SendMessagePayload: Encodable {
    let chat_id: Int64
    let text: String
    let parse_mode: String?
    let reply_markup: ReplyMarkup?

    /// Type-erased reply markup to support both inline and reply keyboards.
    enum ReplyMarkup: Encodable {
        case inline(InlineKeyboardMarkup)
        case reply(ReplyKeyboardMarkup)
        /// Pre-focuses the user's reply box at this message so the answer carries
        /// `reply_to_message` — see `ForceReply`.
        case forceReply(ForceReply)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .inline(let markup):
                try container.encode(markup)
            case .reply(let markup):
                try container.encode(markup)
            case .forceReply(let markup):
                try container.encode(markup)
            }
        }
    }
}

// MARK: - Edit Message Request

/// Payload for the `editMessageText` API call.
struct EditMessageTextPayload: Encodable {
    let chat_id: Int64
    let message_id: Int
    let text: String
    let parse_mode: String?
    let reply_markup: SendMessagePayload.ReplyMarkup?
}

// MARK: - Chat Action

enum TelegramChatAction: String, Encodable {
    case typing
    case uploadDocument = "upload_document"
}
