// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordModels.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Gateway Opcodes

/// Discord Gateway opcodes for WebSocket communication.
enum DiscordGatewayOpcode: Int, Codable, Sendable {
    case dispatch = 0
    case heartbeat = 1
    case identify = 2
    case presenceUpdate = 3
    case voiceStateUpdate = 4
    case resume = 6
    case reconnect = 7
    case requestGuildMembers = 8
    case invalidSession = 9
    case hello = 10
    case heartbeatAck = 11
}

// MARK: - Gateway Payload

/// Generic envelope for all Discord Gateway messages: `{ op, d, s, t }`.
struct DiscordGatewayPayload: Codable, Sendable {
    let op: Int
    let d: DiscordRawJSON?
    let s: Int?
    let t: String?
}

/// Wrapper for raw JSON `d` field — decoded lazily per opcode.
struct DiscordRawJSON: Codable, Sendable {
    let data: Data

    /// Decodes through `AnyCodableValue` so every JSON shape round-trips as itself, including a scalar payload such as op 9
    /// INVALID_SESSION's bare `true`/`false`; nothing is inspected or transformed. A fragment that cannot be re-encoded
    /// throws.
    init(from decoder: Decoder) throws {
        let value = try AnyCodableValue(from: decoder)
        self.data = try JSONEncoder().encode(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        let json = try JSONSerialization.jsonObject(with: data)
        if let dict = json as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodableValue($0) })
        } else {
            try container.encodeNil()
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    init(data: Data) {
        self.data = data
    }
}

/// Helper for encoding/decoding arbitrary JSON values.
enum AnyCodableValue: Codable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])

    init(_ value: Any) {
        if let s = value as? String { self = .string(s) }
        else if let b = value as? Bool { self = .bool(b) }
        else if let i = value as? Int { self = .int(i) }
        else if let d = value as? Double { self = .double(d) }
        else if let arr = value as? [Any] { self = .array(arr.map { AnyCodableValue($0) }) }
        else if let dict = value as? [String: Any] { self = .dictionary(dict.mapValues { AnyCodableValue($0) }) }
        else { self = .null }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let arr = try? container.decode([AnyCodableValue].self) { self = .array(arr) }
        else if let dict = try? container.decode([String: AnyCodableValue].self) { self = .dictionary(dict) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .dictionary(let dict): try container.encode(dict)
        }
    }
}

// MARK: - Gateway Event Payloads

/// Received on opcode 10 (HELLO) — contains the heartbeat interval.
struct DiscordHelloPayload: Codable, Sendable {
    let heartbeat_interval: Int
}

/// Sent on opcode 2 (IDENTIFY) — authenticates the bot.
struct DiscordIdentifyPayload: Codable, Sendable {
    let token: String
    let intents: Int
    let properties: DiscordConnectionProperties

    /// Gateway intents: GUILDS (0x1) | GUILD_MESSAGES (0x200) | MESSAGE_CONTENT (0x8000) = 33281
    static let defaultIntents: Int = 33281
}

/// Connection properties sent during IDENTIFY.
struct DiscordConnectionProperties: Codable, Sendable {
    let os: String
    let browser: String
    let device: String

    static let `default` = DiscordConnectionProperties(os: "macos", browser: "devgentic", device: "devgentic")

    enum CodingKeys: String, CodingKey {
        case os = "$os"
        case browser = "$browser"
        case device = "$device"
    }
}

/// A gateway frame: an opcode and its typed payload (e.g. opcode 6 RESUME, which resumes a disconnected session). Typed
/// so the models are on the real send path rather than hand-built dictionaries.
struct DiscordGatewayFrame<Payload: Encodable>: Encodable {
    let op: Int
    let d: Payload
}

struct DiscordResumePayload: Codable, Sendable {
    let token: String
    let session_id: String
    let seq: Int
}

/// Received on READY dispatch — bot identity and session info.
struct DiscordReadyPayload: Codable, Sendable {
    let user: DiscordUser
    let session_id: String
    let resume_gateway_url: String
    let application: DiscordApplication
}

// MARK: - Core Models

/// A Discord user (bot or human).
struct DiscordUser: Codable, Sendable {
    let id: String
    let username: String
    let discriminator: String?
    let bot: Bool?
    let global_name: String?
}

/// A Discord application (for slash command registration).
struct DiscordApplication: Codable, Sendable {
    let id: String
}

/// A Discord message received on MESSAGE_CREATE.
struct DiscordMessage: Codable, Sendable {
    let id: String
    let channel_id: String
    let guild_id: String?
    let author: DiscordUser
    let content: String
    let timestamp: String

    /// Convenience: channel ID as Int64 for ChatOpsTransport compatibility.
    var channelIDInt64: Int64? { Int64(channel_id) }

    /// Convenience: message ID as Int for ChatOpsTransport compatibility.
    var messageIDInt: Int? { Int(id) }
}

// MARK: - Interactions

/// A Discord interaction (button click or slash command).
struct DiscordInteraction: Codable, Sendable {
    let id: String
    let type: Int
    let channel_id: String?
    let guild_id: String?
    let data: DiscordInteractionData?
    let token: String
    let message: DiscordMessage?
    let member: DiscordGuildMember?

    /// The text a user typed into one field of a submitted modal. Values arrive one ActionRow deep: `data.components` is a
    /// list of rows, each holding the single Text Input, so the `custom_id` is on the nested component.
    func submittedValue(forCustomID customID: String) -> String? {
        data?.components?
            .compactMap(\.components)
            .flatMap { $0 }
            .first { $0.custom_id == customID }?
            .value
    }

    /// Interaction types.
    static let applicationCommand = 2
    static let messageComponent = 3
    /// A user submitting a modal; it must be handled and acknowledged, or Discord shows the user a red 'Something went
    /// wrong'.
    static let modalSubmit = 5
}

/// Data payload within an interaction.
struct DiscordInteractionData: Codable, Sendable {
    let custom_id: String?
    let component_type: Int?
    let name: String?

    /// A modal submission's values, nested one ActionRow deep; see `DiscordInteraction.submittedValue(forCustomID:)`.
    let components: [DiscordComponent]?
}

/// Guild member (contains user info within a guild context).
struct DiscordGuildMember: Codable, Sendable {
    let user: DiscordUser?
}

// MARK: - Message Components

/// A Discord message component (ActionRow or Button).
struct DiscordComponent: Codable, Sendable {
    let type: Int
    let style: Int?
    let label: String?
    let custom_id: String?
    let components: [DiscordComponent]?

    /// The field a submitted answer arrives in; absent on outbound buttons, and `Codable` omits nil optionals.
    let value: String?

    /// Greyed hint inside a text input. Discord caps it at 100 characters.
    let placeholder: String?

    /// Component types.
    static let actionRow = 1
    static let button = 2
    /// A single-line or paragraph text field. Only legal inside a modal.
    static let textInput = 4

    /// Text input styles.
    static let shortInput = 1
    static let paragraphInput = 2

    /// Button styles.
    static let primaryStyle = 1    // Blurple
    static let secondaryStyle = 2  // Grey
    static let successStyle = 3    // Green
    static let dangerStyle = 4     // Red

    /// Factory: creates an ActionRow containing the given components.
    static func actionRow(_ children: [DiscordComponent]) -> DiscordComponent {
        DiscordComponent(type: Self.actionRow, style: nil, label: nil, custom_id: nil,
                         components: children, value: nil, placeholder: nil)
    }

    /// Factory: creates a Button component.
    static func button(label: String, customID: String, style: Int) -> DiscordComponent {
        DiscordComponent(type: Self.button, style: style, label: label, custom_id: customID,
                         components: nil, value: nil, placeholder: nil)
    }

    /// Factory: creates a paragraph Text Input for a modal. Each Text Input must be the sole child of its own ActionRow.
    /// Label and placeholder are raw text (no markdown in a modal), truncated to Discord's caps (label 45, placeholder 100),
    /// since exceeding either rejects the response.
    static func textInput(customID: String, label: String, placeholder: String? = nil) -> DiscordComponent {
        DiscordComponent(
            type: Self.textInput,
            style: Self.paragraphInput,
            label: String(label.prefix(45)),
            custom_id: customID,
            components: nil,
            value: nil,
            placeholder: placeholder.map { String($0.prefix(100)) }
        )
    }
}

// MARK: - REST API Payloads

// Request payloads are `Encodable`, not `Codable`: they travel one way and nothing decodes them.

// Why: do not escape `@` in the escaper instead: the bot posts code (`@MainActor`, `@media`, emails) and mangling
// it is worse than the ping.
/// Which mentions Discord is permitted to resolve in a message this app sends. The bot posts agent output and user text
/// verbatim, so by default `@everyone`, `<@user>` and `<@&role>` in it would ping; `parse: []` resolves nothing and the
/// text still renders exactly as written.
struct DiscordAllowedMentions: Encodable, Sendable {

    /// Mention types Discord may resolve. Empty = none.
    let parse: [String]

    static let suppressAll = DiscordAllowedMentions(parse: [])
}

/// Payload for POST /channels/{id}/messages.
struct DiscordCreateMessagePayload: Encodable, Sendable {
    let content: String
    let components: [DiscordComponent]?

    /// A `let` with a default is excluded from the memberwise initializer, so no call site can construct this payload
    /// without the suppression.
    let allowed_mentions: DiscordAllowedMentions = .suppressAll
}

/// Payload for PATCH /channels/{id}/messages/{id}.
struct DiscordEditMessagePayload: Encodable, Sendable {
    let content: String
    let components: [DiscordComponent]?

    /// Edits need it as much as creates: a mirrored HITL prompt is edited in place and carries the same model-supplied text.
    let allowed_mentions: DiscordAllowedMentions = .suppressAll
}

/// Payload for POST /interactions/{id}/{token}/callback.
struct DiscordInteractionResponsePayload: Encodable, Sendable {
    let type: Int
    let data: DiscordInteractionCallbackData?

    /// Response types.
    static let deferredChannelMessage = 5   // For slash commands — shows "thinking..."
    static let deferredUpdateMessage = 6    // For button clicks — acknowledges without visible response
    static let channelMessageWithSource = 4 // Respond with a new message
    static let updateMessage = 7            // Edit the original interaction message
    /// Opens a modal and is itself the acknowledgement: Discord permits one initial response per interaction, so every gate
    /// that decides whether to open one must run before any ack.
    static let modal = 9
}

/// Callback data within an interaction response.
struct DiscordInteractionCallbackData: Encodable, Sendable {
    let content: String?
    let components: [DiscordComponent]?

    /// Required by a type-9 (modal) response; `custom_id` comes back on the submission and names the operation being
    /// answered.
    let custom_id: String?
    /// Shown as the modal's heading. Discord caps it at 45 characters.
    let title: String?

    /// See `DiscordAllowedMentions`. Optional and set only when there is content: a type-9 modal response has no message
    /// body, and a mention policy for a nonexistent message risks a 400 on the one path that cannot retry. Nil is omitted
    /// from the JSON.
    let allowed_mentions: DiscordAllowedMentions?

    /// Explicit initializer with defaults, so message-shaped call sites compile without the modal fields.
    init(content: String? = nil,
         components: [DiscordComponent]? = nil,
         custom_id: String? = nil,
         title: String? = nil) {
        self.content = content
        self.components = components
        self.custom_id = custom_id
        self.title = title.map { String($0.prefix(45)) }
        self.allowed_mentions = content == nil ? nil : .suppressAll
    }
}

// MARK: - Slash Commands

/// A Discord application command (for registration).
struct DiscordSlashCommand: Codable, Sendable {
    let name: String
    let description: String
    let type: Int

    /// Command type 1 = CHAT_INPUT (slash command).
    static let chatInput = 1
}

// MARK: - Errors

enum DiscordAPIError: LocalizedError, Sendable {
    case apiError(status: Int, message: String)
    case rateLimited(retryAfter: Double)
    case invalidToken
    case gatewayDisconnected(reason: String)
    /// The Gateway closed with a code that reconnecting cannot fix — see `DiscordGatewayClosePolicy`.
    case gatewayClosedPermanently(code: Int, reason: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let status, let msg):
            return "Discord API error (\(status)): \(msg)"
        case .gatewayClosedPermanently(let code, let reason):
            return "Discord Gateway closed permanently (code \(code)): \(reason)"
        case .rateLimited(let retry):
            return "Discord rate limited — retry after \(retry)s"
        case .invalidToken:
            return "Invalid Discord bot token"
        case .gatewayDisconnected(let reason):
            return "Discord Gateway disconnected: \(reason)"
        case .decodingError(let detail):
            return "Discord decoding error: \(detail)"
        }
    }
}

// MARK: - Gateway Events (Typed)

/// Typed events emitted by `DiscordGatewayClient` through its `AsyncStream`.
enum DiscordGatewayEvent: Sendable {
    case ready(DiscordReadyPayload)
    case messageCreate(DiscordMessage)
    case interactionCreate(DiscordInteraction)
    case disconnected(Error?)
    case resumed
}
