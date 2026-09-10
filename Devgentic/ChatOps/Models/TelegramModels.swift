// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  TelegramModels.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
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

/// Telegram's answer to "there is no modal".
///
/// ⚠️ TELEGRAM HAS NO MODAL AT PLATFORM LEVEL and `ForceReply` is its ceiling. It opens no dialog:
/// it makes the user's client pre-focus the reply box AIMED AT this specific message, so the answer
/// comes back carrying `reply_to_message`. That correlation is the entire point — it lets an answer
/// name the operation it answers instead of being inferred from a provider-wide cursor, which is
/// how a second parked clarification became unanswerable and how `/cancel` got swallowed.
struct ForceReply: Codable {

    let force_reply: Bool

    /// Greyed placeholder inside the reply box. Telegram caps it at 64 characters.
    let input_field_placeholder: String?

    /// ⚠️ FALSE, AND THAT IS NOT AN OVERSIGHT. Telegram's `selective` targets only users @mentioned
    /// in the message text, or — if the bot's message is itself a reply — the original sender. A
    /// mirrored clarification prompt is neither, so `selective: true` would force the reply box for
    /// NOBODY and the affordance would silently do nothing. ChatOps is paired to one chat and one
    /// human by design, so a non-selective force reply targets exactly the right person anyway.
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

    /// The message this one replies to, when the user used Telegram's reply affordance.
    ///
    /// ⚠️ FLATTENED TO A SEPARATE TYPE, NOT `TelegramMessage?`. Swift rejects the obvious spelling
    /// outright — "value type 'TelegramMessage' cannot have a stored property that recursively
    /// contains it" — so anyone reaching for the one-line fix will hit a compiler error and may
    /// conclude the data is unavailable. It is not: Telegram has been sending this all along and
    /// `Codable` was silently discarding it, because unknown keys are ignored.
    ///
    /// Only `message_id` is carried, because only `message_id` has a reader: it is the key that
    /// turns "some text arrived" into "this answers operation X".
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
