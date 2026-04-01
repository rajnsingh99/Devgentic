//
//  DiscordModels.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Capture the raw JSON for lazy decoding
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            self.data = try JSONEncoder().encode(dict)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self.data = try JSONEncoder().encode(arr)
        } else if container.decodeNil() {
            self.data = "null".data(using: .utf8)!
        } else {
            self.data = "null".data(using: .utf8)!
        }
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

/// Sent on opcode 6 (RESUME) — resumes a disconnected session.
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

    /// Interaction types.
    static let applicationCommand = 2
    static let messageComponent = 3
}

/// Data payload within an interaction.
struct DiscordInteractionData: Codable, Sendable {
    let custom_id: String?
    let component_type: Int?
    let name: String?
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

    /// Component types.
    static let actionRow = 1
    static let button = 2

    /// Button styles.
    static let primaryStyle = 1    // Blurple
    static let secondaryStyle = 2  // Grey
    static let successStyle = 3    // Green
    static let dangerStyle = 4     // Red

    /// Factory: creates an ActionRow containing the given button components.
    static func actionRow(_ buttons: [DiscordComponent]) -> DiscordComponent {
        DiscordComponent(type: Self.actionRow, style: nil, label: nil, custom_id: nil, components: buttons)
    }

    /// Factory: creates a Button component.
    static func button(label: String, customID: String, style: Int) -> DiscordComponent {
        DiscordComponent(type: Self.button, style: style, label: label, custom_id: customID, components: nil)
    }
}

// MARK: - REST API Payloads

/// Payload for POST /channels/{id}/messages.
struct DiscordCreateMessagePayload: Codable, Sendable {
    let content: String
    let components: [DiscordComponent]?
}

/// Payload for PATCH /channels/{id}/messages/{id}.
struct DiscordEditMessagePayload: Codable, Sendable {
    let content: String
    let components: [DiscordComponent]?
}

/// Payload for POST /interactions/{id}/{token}/callback.
struct DiscordInteractionResponsePayload: Codable, Sendable {
    let type: Int
    let data: DiscordInteractionCallbackData?

    /// Response types.
    static let deferredChannelMessage = 5   // For slash commands — shows "thinking..."
    static let deferredUpdateMessage = 6    // For button clicks — acknowledges without visible response
    static let channelMessageWithSource = 4 // Respond with a new message
    static let updateMessage = 7            // Edit the original interaction message
}

/// Callback data within an interaction response.
struct DiscordInteractionCallbackData: Codable, Sendable {
    let content: String?
    let components: [DiscordComponent]?
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
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let status, let msg):
            return "Discord API error (\(status)): \(msg)"
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
