// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteView.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - View

/// The complete set of things a remote channel can be shown. Four cases, no more.
enum RemoteView: Equatable, Sendable, Codable {

    /// Nothing to post; the reason is carried so the drop is logged rather than silent.
    case silent(RemoteSilence)

    /// A message: a tone, an optional title, a body, and zero or more labelled fields.
    case notice(Notice)

    /// A prompt with tappable options.
    case chooser(Chooser)

    // Why: the payload carries model-supplied tool names and parameters: Slack always interprets mrkdwn, so
    // `SlackRemoteRenderer.promptDraft` escapes them, and Telegram's prompt passes no parse mode.
    /// A human-in-the-loop request, reusing the `HITLType` vocabulary verbatim.
    /// `RemoteMirrorService` renders one whenever the InteractionCenter raises a question.
    case prompt(operationID: UUID, kind: HITLType)
}

// MARK: - Silence

/// Why nothing is being posted: making a silent drop a value with a reason lets every drop log its consequence.
enum RemoteSilence: Equatable, Sendable, Codable {

    /// Another component owns this input. Carries which, for the log.
    case handledElsewhere(String)

    /// A HITL interaction was resolved; the mirror edits the original prompt in place, so posting
    /// anything here would double-report the decision.
    case resolvedInteraction(operationID: UUID)

    /// Input that parsed to nothing recognisable.
    case unrecognized(String)

    /// Bracket tag for the log line.
    var tag: String { "[CHATOPS/SILENT]" }

    // Why: this decides the log level: `DGLogger.shouldPersist` keeps `.warning` and above,
    // so an `.info` line never reaches a bug report.
    /// Whether this drop left the remote user with nothing: no reply and no way to tell the bot is alive.
    /// Only `.unrecognized` does; the other cases are correct silences because another component already replied.
    var strandsTheUser: Bool {
        switch self {
        case .handledElsewhere, .resolvedInteraction: return false
        case .unrecognized: return true
        }
    }

    /// What a reader of the log needs to know followed from the drop.
    var consequence: String {
        switch self {
        case .handledElsewhere(let owner):
            return "handled by \(owner) instead; the bridge posted nothing, which is correct — a reply here would duplicate that component's own."
        case .resolvedInteraction(let id):
            return "interaction \(id.uuidString.prefix(8)) was resolved and the mirror edits the original prompt in place; posting here would report the same decision twice."
        case .unrecognized(let input):
            return "input \"\(input.prefix(40))\" matched no command, so the remote user received NO reply at all and cannot tell whether the bot is alive."
        }
    }
}

// MARK: - Notice

/// A message with structure, so `/status` is a field list rather than a hand-formatted blob that
/// each platform re-derives.
struct Notice: Equatable, Sendable, Codable {

    enum Tone: String, Equatable, Sendable, Codable {
        case info
        case success
        case warning
        case failure
    }

    /// A line of a notice body with an optional label, emphasis and inline placement.
    /// Each option exists for a specific shipping reply format.
    struct Field: Equatable, Sendable, Codable {

        /// Optional: not every field is a `label: value` pair.
        let label: String?

        let value: String

        /// Bolds the VALUE. `⚡ Agent Streaming: *Yes*` shape.
        let emphasis: Bool

        // Why: the colon must be inside the bold, or `/help` would render `*Security Tier*: Full Access`.
        /// Bolds the label including its colon, e.g. `*Security Tier:* Full Access`.
        let labelEmphasis: Bool

        /// Appends to the previous line, separated by a single space, instead of starting a new one.
        /// Used for mid-sentence emphasis such as `✅ Switched to: *<title>*`.
        let inline: Bool

        init(label: String? = nil, value: String, emphasis: Bool = false, labelEmphasis: Bool = false, inline: Bool = false) {
            self.label = label
            self.value = value
            self.emphasis = emphasis
            self.labelEmphasis = labelEmphasis
            self.inline = inline
        }

        /// A blank line; an empty `body` is skipped entirely, so this is the only way to express one.
        /// Named rather than the idiom `Field(value: "")` so a later tidy-up does not delete it.
        static let spacer = Field(value: "")
    }

    /// `render` logs a `.failure` notice at `.error` and the rest at `.info`.
    /// No emoji is prepended: platforms have no style channel for plain messages, so the emoji belongs to the supplied body.
    let tone: Tone

    /// An emoji rendered before the bold title, outside the markers.
    /// Folding it into `title` would emit `*📊 Devgentic Status*` instead of `📊 *Devgentic Status*`.
    let icon: String?

    let title: String?

    /// Plain text; the renderer owns markup and escapes it, so an unbalanced `*` or `_` cannot break a Markdown message.
    /// Emphasis comes through `fields`, never by embedding `*` here.
    let body: String

    let fields: [Field]

    init(tone: Tone, icon: String? = nil, title: String? = nil, body: String = "", fields: [Field] = []) {
        self.tone = tone
        self.icon = icon
        self.title = title
        self.body = body
        self.fields = fields
    }
}

// MARK: - Chooser

/// A prompt plus the options that answer it.
struct Chooser: Equatable, Sendable, Codable {

    enum Intent: String, Equatable, Sendable, Codable {
        case neutral
        case primary
        case destructive
    }

    struct Option: Equatable, Sendable, Codable {

        /// Plain text, no platform markup. Truncated by the renderer to its own
        /// `RemoteCapabilities.maxLabelLength` — 60 / 80 / 75 — rather than here, because the limit
        /// differs per platform and truncating early would throw away characters Discord could show.
        let label: String

        /// A subtitle, where the platform has somewhere to put one; Telegram drops it, and the loss is not logged (decoration).
        let detail: String?

        let token: CallbackToken

        /// Marks the current entry; a flag rather than a text prefix, so each renderer decides how to show it.
        let isCurrent: Bool

        /// Button style hint; Telegram has no button styles and drops it (decoration).
        let intent: Intent

        init(label: String, detail: String? = nil, token: CallbackToken, isCurrent: Bool = false, intent: Intent = .neutral) {
            self.label = label
            self.detail = detail
            self.token = token
            self.isCurrent = isCurrent
            self.intent = intent
        }
    }

    /// Rendered before the bold title, outside the markers — see `Notice.icon`.
    let icon: String?

    let title: String
    let options: [Option]

    /// Actions that are not one of the options — today just "➕ New Conversation". Kept separate so
    /// a renderer can place them apart from the list, and so `isCurrent` never applies to them.
    let extraActions: [Option]

    init(icon: String? = nil, title: String, options: [Option], extraActions: [Option] = []) {
        self.icon = icon
        self.title = title
        self.options = options
        self.extraActions = extraActions
    }
}

// MARK: - Egress

extension RemoteView {

    /// Returns the same view with every user- or model-supplied string run through the credential floor.
    /// Applied to the view, not the rendered text: Slack builds blocks too, and button labels carry titles and profile names.
    /// Callback tokens are app-minted ids and are left untouched; rewriting one would break the button's round trip.
    func sanitizedForEgress() -> RemoteView {
        func clean(_ text: String) -> String { RemoteEgressSanitizer.credentialsOnly(text) }
        func clean(_ text: String?) -> String? { RemoteEgressSanitizer.credentialsOnly(text) }

        switch self {
        case .silent:
            // Nothing is posted, so there is nothing to clean.
            return self

        case .notice(let notice):
            return .notice(Notice(
                tone: notice.tone,
                icon: clean(notice.icon),
                title: clean(notice.title),
                body: clean(notice.body),
                fields: notice.fields.map { field in
                    Notice.Field(
                        label: clean(field.label),
                        value: clean(field.value),
                        emphasis: field.emphasis,
                        labelEmphasis: field.labelEmphasis,
                        inline: field.inline
                    )
                }
            ))

        case .chooser(let chooser):
            func cleanOption(_ option: Chooser.Option) -> Chooser.Option {
                Chooser.Option(
                    label: clean(option.label),
                    detail: clean(option.detail),
                    token: option.token,
                    isCurrent: option.isCurrent,
                    intent: option.intent
                )
            }
            return .chooser(Chooser(
                icon: clean(chooser.icon),
                title: clean(chooser.title),
                options: chooser.options.map(cleanOption),
                extraActions: chooser.extraActions.map(cleanOption)
            ))

        case .prompt(let operationID, let kind):
            // Most exposed strings: a tool confirmation carries raw arguments, where a key read from a `.env` can appear.
            let cleaned: HITLType
            switch kind {
            case .toolConfirmation(let toolName, let params):
                cleaned = .toolConfirmation(toolName: clean(toolName), params: clean(params))
            case .clarification(let question):
                cleaned = .clarification(question: clean(question))
            case .planReview(let subtasks):
                cleaned = .planReview(subtaskDescriptions: subtasks.map(clean))
            case .gate(let prompt, let options):
                cleaned = .gate(prompt: clean(prompt), options: options.map(clean))
            }
            return .prompt(operationID: operationID, kind: cleaned)
        }
    }
}
