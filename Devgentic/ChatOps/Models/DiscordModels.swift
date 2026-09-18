// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// ⚠️⚠️ [DC-5] THIS USED TO SNIFF FOR TWO SHAPES AND SUBSTITUTE `null` FOR EVERY OTHER ONE. It
    /// tried dictionary, then array, then `decodeNil()`, and its final `else` wrote the literal bytes
    /// `null` — so any SCALAR payload was silently destroyed. Discord sends exactly one: op 9
    /// INVALID_SESSION carries a bare `true`/`false` saying whether the session may be RESUMED.
    /// `decodeNil()` is false for `true`, so it fell to that `else`, and the consumer's
    /// `(try? payload.d?.decode(Bool.self)) ?? false` then decoded `Bool` from `null`, threw, and
    /// defaulted to false. Every invalid session was therefore treated as non-resumable: the session
    /// id and sequence were always discarded, the reconnect always degraded to a full re-IDENTIFY
    /// (which Discord meters daily), events queued since the last sequence were always lost, and the
    /// log could only ever print "resumable: false" — so the bug could not be seen from the field
    /// either.
    ///
    /// ⚠️ A TOTAL ROUND TRIP, NOT ONE MORE BRANCH. `AnyCodableValue` already models every JSON type,
    /// so decoding through it makes "a shape we forgot" unrepresentable instead of documented. This
    /// is NOT the shape-matching content rewrite this codebase has been bitten by four times: nothing
    /// is inspected or transformed, the value is decoded and re-encoded as itself.
    ///
    /// ⚠️ IT THROWS RATHER THAN SWALLOWING. A fragment that genuinely cannot be re-encoded now
    /// surfaces through the envelope catch in `DiscordGatewayClient`, which names its consequence,
    /// instead of being flattened to `null` where nothing can tell it apart from a real null.
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

/// Sent on opcode 6 (RESUME) — resumes a disconnected session.
/// A gateway frame: an opcode and its payload.
///
/// ⚠️⚠️ [DC-8] EXISTS BECAUSE THE MODELS WERE NOT ON THE SEND PATH. `sendResume` and `sendHeartbeat`
/// hand-built `[String: Any]` dictionaries and serialised those, so `DiscordResumePayload` had exactly
/// two references in the whole repo — both inside `DiscordGatewayClientTests`, which encoded it,
/// decoded it, and asserted the round trip. That test could not fail for any reason the app cares
/// about: the struct it validated was never what went on the wire. A typed frame puts the model back
/// on the real path, so the test starts meaning something.
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

    /// The text a user typed into one field of a submitted modal.
    ///
    /// ⚠️ VALUES ARRIVE ONE ACTIONROW DEEP: `data.components` is a list of ActionRows, each holding
    /// the single Text Input Discord requires it to hold. Reading `data.components` directly and
    /// looking for a `custom_id` finds only rows, which have none — so the obvious flat read
    /// returns nil for every submission and looks like "the user submitted nothing".
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
    /// ⚠️ A user submitting a MODAL. It was unmodelled, and the bridge's interaction switch ended
    /// in a bare `return`, so a submission was dropped with no ack and no log — which Discord shows
    /// the user as a red "Something went wrong" three seconds later, with nothing recorded anywhere.
    static let modalSubmit = 5
}

/// Data payload within an interaction.
struct DiscordInteractionData: Codable, Sendable {
    let custom_id: String?
    let component_type: Int?
    let name: String?

    /// ⚠️ A MODAL SUBMISSION'S VALUES, nested one ActionRow deep. This was absent, so
    /// `interaction.data?.components` did not compile and a submitted answer could not be reached
    /// at all. See `DiscordInteraction.submittedValue(forCustomID:)`.
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

    /// ⚠️ THE FIELD A SUBMITTED ANSWER ARRIVES IN. Without it every modal submission decoded as
    /// nil — the answer was on the wire and unreadable. Absent on outbound buttons, and `Codable`
    /// omits nil optionals, so nothing changes for them.
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

    /// Factory: creates a paragraph Text Input for a modal.
    ///
    /// ⚠️ LABEL AND PLACEHOLDER ARE RAW TEXT. Discord renders NO markdown inside a modal, so
    /// running them through the message-path escaper would show the user literal backslashes.
    /// Truncated to Discord's documented caps (label 45, placeholder 100) because exceeding either
    /// rejects the whole interaction response — and the only feedback is a failed modal.
    ///
    /// ⚠️ Each Text Input must be the SOLE child of its own ActionRow; Discord rejects two in one.
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

// ⚠️ REQUEST PAYLOADS ARE `Encodable`, NOT `Codable` — they travel one way and nothing decodes them
// (verified repo-wide). Declaring them `Codable` made the compiler warn that the `allowed_mentions`
// default "will not be decoded", which is true and irrelevant: a field the server never sends back
// cannot be decoded. Typing them as encode-only states the direction and removes a warning that
// would otherwise train the next reader to ignore warnings on this file.

/// Which mentions Discord is permitted to RESOLVE in a message this app sends.
///
/// ⚠️⚠️ [BR-3/EG-3] THE TEXT THIS BOT POSTS IS NOT THE APP'S TEXT. It is the agent's answer, the
/// user's own prompt echoed back, and conversation titles auto-derived from a first message — all of
/// which reach Discord's `content` verbatim. Discord resolves `@everyone`, `@here`, `<@user>` and
/// `<@&role>` from the message BODY by default, so any of those strings appearing anywhere in a
/// model's output made the bot mass-ping the server. Nothing in the repo set this field; a
/// repo-wide search for `allowed_mentions` returned nothing at all.
///
/// ⚠️⚠️ AND THE OBVIOUS FIX — ESCAPING `@` IN THE ESCAPER — WOULD HAVE BEEN A CONTENT-CORRUPTION BUG,
/// the fifth in this codebase's documented history of transforms that rewrote a payload by
/// shape-matching it. This bot posts CODE: `@MainActor`, `@Observable`, `@escaping`, `@media`,
/// decorators, email addresses. Mangling every one of those to stop a ping is a worse defect than
/// the ping. `allowed_mentions` is Discord's own control and is authoritative — the text renders
/// EXACTLY as written and simply does not notify anyone.
///
/// ⚠️ `parse: []` is "resolve nothing", and it is deliberately not "resolve users but not everyone".
/// A single-user remote control has no reason to notify a third party at all, and the narrower
/// setting would still let model output ping an arbitrary member by id.
struct DiscordAllowedMentions: Encodable, Sendable {

    /// Mention types Discord may resolve. Empty = none.
    let parse: [String]

    static let suppressAll = DiscordAllowedMentions(parse: [])
}

/// Payload for POST /channels/{id}/messages.
struct DiscordCreateMessagePayload: Encodable, Sendable {
    let content: String
    let components: [DiscordComponent]?

    /// ⚠️ A `let` WITH A DEFAULT, WHICH IS THE WHOLE POINT: Swift excludes such a property from the
    /// memberwise initializer, so every existing call site keeps compiling AND no future one can
    /// construct this payload without the suppression. A field each caller had to remember would be
    /// forgotten by exactly the new send path nobody reviewed.
    let allowed_mentions: DiscordAllowedMentions = .suppressAll
}

/// Payload for PATCH /channels/{id}/messages/{id}.
struct DiscordEditMessagePayload: Encodable, Sendable {
    let content: String
    let components: [DiscordComponent]?

    /// ⚠️ Edits need it as much as creates: a mirrored HITL prompt is EDITED in place when it
    /// resolves, and that edit carries the same model-supplied tool name and parameters.
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
    /// ⚠️ Opens a MODAL, and it IS the acknowledgement — Discord permits exactly one initial
    /// response per interaction, so a modal cannot follow a deferred ack. Every gate that decides
    /// whether to open one must therefore run BEFORE any ack.
    static let modal = 9
}

/// Callback data within an interaction response.
struct DiscordInteractionCallbackData: Encodable, Sendable {
    let content: String?
    let components: [DiscordComponent]?

    /// ⚠️ REQUIRED BY A TYPE-9 (modal) RESPONSE, and their absence was the single hard blocker on
    /// opening one: the body could not be expressed, however willing the transport was.
    /// `custom_id` comes back on the submission and is what names the operation being answered.
    let custom_id: String?
    /// Shown as the modal's heading. Discord caps it at 45 characters.
    let title: String?

    /// ⚠️ [BR-3/EG-3] See `DiscordAllowedMentions`. An interaction response carries the same
    /// model-supplied text as a channel post, so it needs the same suppression.
    ///
    /// ⚠️ OPTIONAL, AND SET ONLY WHEN THERE IS CONTENT — unlike the two message payloads, which
    /// always have some. A type-9 MODAL response carries `custom_id`/`title`/`components` and no
    /// message body at all; sending a mention policy for a message that does not exist invites a
    /// 400 on the one path that cannot retry (Discord permits exactly one initial response per
    /// interaction). Swift's synthesized encoder uses `encodeIfPresent` for optionals, so nil is
    /// omitted from the JSON rather than sent as null.
    let allowed_mentions: DiscordAllowedMentions?

    /// ⚠️ Explicit, with defaults, so the message-shaped call sites that predate the modal fields
    /// keep compiling unchanged.
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
