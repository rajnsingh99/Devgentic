// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SlackModels.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation

// MARK: - Socket Mode Envelope

/// Generic envelope for all Slack Socket Mode messages.
struct SlackSocketPayload: Codable, Sendable {
    let type: String
    let envelope_id: String?
    let payload: SlackRawPayload?
    let retry_attempt: Int?
    let retry_reason: String?
    let accepts_response_payload: Bool?
}

/// Raw JSON payload — decoded lazily per type.
struct SlackRawPayload: Codable, Sendable {
    let data: Data

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Capture raw JSON
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            self.data = try JSONEncoder().encode(dict)
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

// MARK: - Socket Mode Acknowledgment

/// Sent back on WebSocket to acknowledge receipt of an envelope.
struct SlackSocketAck: Codable, Sendable {
    let envelope_id: String
}

// MARK: - Events API Payload

/// Wrapper for events received via Socket Mode `events_api` type.
struct SlackEventPayload: Codable, Sendable {
    let event: SlackEvent
}

/// A Slack event (message, app_mention, etc.).
struct SlackEvent: Codable, Sendable {
    let type: String
    let channel: String?
    let user: String?
    let text: String?
    let ts: String?
    let bot_id: String?
    let subtype: String?
}

// MARK: - Interactive Payload

/// Payload for button clicks and other interactive components.
struct SlackInteractivePayload: Codable, Sendable {
    let type: String
    let actions: [SlackAction]?
    let channel: SlackChannelRef?
    let message: SlackMessageRef?
    let user: SlackUserRef?
    let response_url: String?
    let trigger_id: String?

    /// The submitted modal, present only on a `view_submission`.
    ///
    /// ⚠️ THIS WAS ABSENT, so a submission decoded cleanly and carried nothing: the typed answer
    /// and the correlation metadata were both invisible. Worse, the bridge dropped the payload one
    /// line in on `guard let action = payload.actions?.first else { return }` — a `view_submission`
    /// has no `actions` array — with no log, so the whole interaction vanished without trace.
    let view: SlackViewSubmission?

    /// Payload types.
    static let blockActions = "block_actions"
    static let viewSubmission = "view_submission"

    /// The text a user typed into one field of a submitted modal.
    ///
    /// ⚠️ `state.values` is keyed BLOCK id then ACTION id — two levels, not one. A flat read finds
    /// nothing and presents as "the user submitted an empty answer".
    func submittedValue(blockID: String, actionID: String) -> String? {
        view?.state?.values[blockID]?[actionID]?.value
    }
}

// MARK: - View Submission

/// The `view` object on a `view_submission` payload.
struct SlackViewSubmission: Codable, Sendable {
    let callback_id: String?

    /// ⚠️ THE CORRELATION CARRIER. A modal is not in a channel, so a submission has no `channel`
    /// to infer anything from — `private_metadata` is what the view was opened with and comes back
    /// untouched. Slack allows 3000 characters here; a 48-byte token is nothing.
    let private_metadata: String?

    let state: SlackViewState?
}

struct SlackViewState: Codable, Sendable {
    /// block_id → action_id → value.
    let values: [String: [String: SlackViewStateValue]]
}

struct SlackViewStateValue: Codable, Sendable {
    let type: String?
    let value: String?
}

/// An individual action (button click, menu selection, etc.).
struct SlackAction: Codable, Sendable {
    let action_id: String
    let block_id: String?
    let value: String?
    let type: String
}

// MARK: - Slash Command Payload

/// Payload for slash commands received via Socket Mode.
struct SlackSlashCommandPayload: Codable, Sendable {
    let command: String
    let text: String?
    let channel_id: String
    let channel_name: String?
    let user_id: String
    let user_name: String?
    let response_url: String?
    let trigger_id: String?
}

// MARK: - Reference Types

/// Channel reference in payloads.
struct SlackChannelRef: Codable, Sendable {
    let id: String
    let name: String?
}

/// User reference in payloads.
struct SlackUserRef: Codable, Sendable {
    let id: String
    let username: String?
    let name: String?
}

/// Message reference in payloads.
struct SlackMessageRef: Codable, Sendable {
    let ts: String
    let text: String?
}

// MARK: - Block Kit

/// A Slack Block Kit block (section, actions, context, divider).
struct SlackBlock: Codable, Sendable {
    let type: String
    let block_id: String?
    let text: SlackTextObject?
    let elements: [SlackBlockElement]?

    /// Block types.
    static let section = "section"
    static let actions = "actions"
    static let context = "context"
    static let divider = "divider"

    /// Factory: creates a section block with plain text.
    static func sectionBlock(text: String, blockID: String? = nil) -> SlackBlock {
        SlackBlock(
            type: Self.section,
            block_id: blockID,
            text: SlackTextObject(type: "mrkdwn", text: text),
            elements: nil
        )
    }

    /// Factory: creates an actions block with button elements.
    static func actionsBlock(elements: [SlackBlockElement], blockID: String? = nil) -> SlackBlock {
        SlackBlock(
            type: Self.actions,
            block_id: blockID,
            text: nil,
            elements: elements
        )
    }
}

/// A text object used in blocks.
struct SlackTextObject: Codable, Sendable {
    let type: String  // "plain_text" or "mrkdwn"
    let text: String
    let emoji: Bool?

    init(type: String, text: String, emoji: Bool? = nil) {
        self.type = type
        self.text = text
        self.emoji = emoji
    }
}

/// A block element (button, select menu, etc.).
struct SlackBlockElement: Codable, Sendable {
    let type: String
    let text: SlackTextObject?
    let action_id: String?
    let value: String?
    let style: String?

    /// Element types.
    static let buttonType = "button"

    /// Button styles.
    static let primaryStyle = "primary"  // Green
    static let dangerStyle = "danger"    // Red

    /// Factory: creates a button element.
    static func button(
        text: String,
        actionID: String,
        value: String? = nil,
        style: String? = nil
    ) -> SlackBlockElement {
        SlackBlockElement(
            type: Self.buttonType,
            text: SlackTextObject(type: "plain_text", text: text, emoji: true),
            action_id: actionID,
            value: value,
            style: style
        )
    }
}

// MARK: - Web API Payloads

/// Payload for chat.postMessage.
struct SlackPostMessagePayload: Codable, Sendable {
    let channel: String
    let text: String
    let blocks: [SlackBlock]?

    /// ⚠️⚠️ [BR-3/EG-3] NEUTRALISED IN THE INITIALIZER, NOT AT THE CALL SITE, for the same reason
    /// Discord's `allowed_mentions` is a defaulted property: a step each sender has to remember is a
    /// step the next send path forgets. Every `chat.postMessage` this app makes goes through here.
    /// See `RemoteMarkupEscaping.withoutSlackBroadcasts` for why rewriting this text is safe when
    /// four previous content rewrites in this codebase were not.
    init(channel: String, text: String, blocks: [SlackBlock]? = nil) {
        self.channel = channel
        self.text = RemoteMarkupEscaping.withoutSlackBroadcasts(text)
        self.blocks = blocks
    }
}

/// Payload for chat.update.
struct SlackUpdateMessagePayload: Codable, Sendable {
    let channel: String
    let ts: String
    let text: String
    let blocks: [SlackBlock]?

    /// ⚠️ Edits need it as much as posts — a mirrored prompt is edited in place when it resolves.
    init(channel: String, ts: String, text: String, blocks: [SlackBlock]? = nil) {
        self.channel = channel
        self.ts = ts
        self.text = RemoteMarkupEscaping.withoutSlackBroadcasts(text)
        self.blocks = blocks
    }
}

// MARK: - Modal Views

/// A modal view, as `views.open` wants it.
///
/// ⚠️ A SEPARATE TYPE FROM `SlackBlock`, DELIBERATELY. A modal's input block needs a `label` and a
/// SINGULAR `element`; `SlackBlock` has neither — it carries a plural `elements` array and no label,
/// because it exists for message blocks. Widening it would let a message block sprout a label and
/// an input, which Slack rejects at the API with an opaque `invalid_arguments`, so the two shapes
/// stay separate rather than sharing a type that is wrong for both.
struct SlackModalView: Encodable, Sendable {
    let type: String
    let callback_id: String
    let private_metadata: String
    let title: SlackTextObject
    let submit: SlackTextObject
    let close: SlackTextObject
    let blocks: [SlackInputBlock]

    /// ⚠️ Slack caps `title`, `submit` and `close` at 24 characters EACH and rejects the whole
    /// `views.open` call otherwise — the user sees a button that does nothing.
    init(callbackID: String, privateMetadata: String, title: String, blocks: [SlackInputBlock]) {
        self.type = "modal"
        self.callback_id = callbackID
        self.private_metadata = privateMetadata
        self.title = SlackTextObject(type: "plain_text", text: String(title.prefix(24)))
        self.submit = SlackTextObject(type: "plain_text", text: "Send")
        self.close = SlackTextObject(type: "plain_text", text: "Cancel")
        self.blocks = blocks
    }
}

/// An `input` block — the only block kind a modal needs here.
struct SlackInputBlock: Encodable, Sendable {
    let type: String
    let block_id: String
    let label: SlackTextObject
    let element: SlackPlainTextInput

    init(blockID: String, label: String, element: SlackPlainTextInput) {
        self.type = "input"
        self.block_id = blockID
        // Labels are plain_text: Slack renders no mrkdwn here, so escaping would show backslashes.
        self.label = SlackTextObject(type: "plain_text", text: String(label.prefix(2000)))
        self.element = element
    }
}

/// A multi-line free-text field.
struct SlackPlainTextInput: Encodable, Sendable {
    let type: String
    let action_id: String
    let multiline: Bool
    let placeholder: SlackTextObject?

    init(actionID: String, placeholder: String? = nil) {
        self.type = "plain_text_input"
        self.action_id = actionID
        self.multiline = true
        self.placeholder = placeholder.map {
            SlackTextObject(type: "plain_text", text: String($0.prefix(150)))
        }
    }
}

/// Payload for `views.open`.
struct SlackViewsOpenPayload: Encodable, Sendable {
    let trigger_id: String
    let view: SlackModalView
}

// MARK: - Web API Responses

/// Generic Slack API response envelope.
struct SlackAPIResponse<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?

    // For chat.postMessage — the response includes channel and ts
    let channel: String?
    let ts: String?

    /// ⚠️ WHERE SLACK PUTS THE ACTUAL REASON, and it was being discarded. A rejected view comes
    /// back as HTTP 200 with `ok: false` and `error: "invalid_arguments"` — a string that names
    /// nothing — while the field that says WHICH argument sits in here. Without it, a malformed
    /// modal is undebuggable from logs, which is exactly the state this path must not ship in.
    let response_metadata: SlackResponseMetadata?
}

struct SlackResponseMetadata: Decodable, Sendable {
    let messages: [String]?
}

/// Response from auth.test.
struct SlackAuthTestResponse: Codable, Sendable {
    let ok: Bool
    let user_id: String?
    let user: String?
    let team: String?
    let team_id: String?
    let bot_id: String?
    let error: String?
}

/// Response from apps.connections.open.
struct SlackConnectionOpenResponse: Codable, Sendable {
    let ok: Bool
    let url: String?
    let error: String?
}

// MARK: - Errors

enum SlackAPIError: LocalizedError, Sendable {
    case apiError(method: String, error: String)
    case rateLimited(retryAfter: Double)
    case invalidToken
    case socketDisconnected(reason: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let method, let error):
            return "Slack API error (\(method)): \(error)"
        case .rateLimited(let retry):
            return "Slack rate limited — retry after \(retry)s"
        case .invalidToken:
            return "Invalid Slack token"
        case .socketDisconnected(let reason):
            return "Slack Socket Mode disconnected: \(reason)"
        case .decodingError(let detail):
            return "Slack decoding error: \(detail)"
        }
    }
}

// MARK: - Socket Mode Events (Typed)

/// Typed events emitted by `SlackSocketClient` through its `AsyncStream`.
enum SlackSocketEvent: Sendable {
    case connected
    case message(SlackEvent)
    case interaction(SlackInteractivePayload)
    case slashCommand(SlackSlashCommandPayload)
    case disconnected(Error?)
}
