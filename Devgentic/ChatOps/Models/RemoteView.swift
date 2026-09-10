// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteView.swift
//  Devgentic
//
//  What a ChatOps command decided to show — C2 of the ChatOps remote-interface plan.
//
//  ⚠️ THE WHOLE POINT: A COMMAND RETURNS ONE OF THESE AND NEVER POSTS. Today all twelve handlers
//  are `private func … -> Void` that run the SwiftData query, build the platform widget AND send the
//  message in one body, so the only way to reuse a decision is to copy it — which is why there are
//  three of everything and why Discord renders `/conversations` two different ways. Making the
//  decision a VALUE is the entire refactor; everything else follows.
//
//  ⚠️ SEMANTICS, NOT WIDGETS. Nothing here names a keyboard, a block or an ActionRow. `isCurrent`
//  is the load-bearing example: all three bridges currently write
//  `let isActive = convID == config.activeConversationID ? "⭐ " : ""` INTO THE LABEL STRING, which
//  forecloses Slack's native `initial_option` forever. Keeping it a Bool is what lets Slack render
//  a pre-selected dropdown while Telegram renders the same star it does now, from one decision.
//
//  ⚠️ EVERYTHING IS `Codable`, AND THAT IS A SAFETY PROPERTY, NOT A CONVENIENCE. A remote view is
//  posted to a third-party service, so it must not be able to carry a secret.
//  `BackendProfileSnapshot` was deliberately made NON-`Codable` (BackendProfileSD.swift:503-515)
//  because its `details` getter injects the decrypted provider API key from the Keychain. Requiring
//  `Codable` here means the compiler refuses any view that reaches for one, instead of a reviewer
//  having to notice. It also hands C3's golden wire-payload fixtures a free encoder.
//

import Foundation

// MARK: - View

/// The complete set of things a remote channel can be shown. Four cases, no more.
enum RemoteView: Equatable, Sendable, Codable {

    /// Nothing to post — but WHY, so the drop is logged rather than silent.
    case silent(RemoteSilence)

    /// A message: a tone, an optional title, a body, and zero or more labelled fields.
    case notice(Notice)

    /// A prompt with tappable options.
    case chooser(Chooser)

    /// A human-in-the-loop request, reusing the shipped `HITLType` vocabulary verbatim.
    ///
    /// ⚠️ Its producer is `RemoteMirrorService`, which renders one of these whenever the
    /// InteractionCenter raises a question — the debt this case carried from C2 to C8.5, when the
    /// dedicated `sendHITLPrompt` method and its three implementations were deleted in favour of it.
    ///
    /// ⚠️ Rendering a prompt is the ONE path that does not escape its text and passes no parse mode:
    /// the payload carries model-supplied tool names and parameters, and running those through a
    /// Markdown parser is the 400 the notice path escapes to avoid.
    case prompt(operationID: UUID, kind: HITLType)
}

// MARK: - Silence

/// Why nothing is being posted.
///
/// ⚠️ This exists because the bridges currently have four naked `break`s — `.pairingAttempt`,
/// `.unknown`, and both HITL resolution arms — that log nothing at all. The standing logging rule
/// is that every silent drop names its CONSEQUENCE; a `break` cannot. Making the silence a value
/// with a reason is how the rule becomes enforceable.
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

    /// ⚠️ THE SHAPE OF THIS TYPE WAS DECIDED BY THE REAL LITERALS, not the other way round. An
    /// earlier draft offered only `title` / `body` / `fields`, and an adversarial pass against the
    /// shipping strings found six it could not reproduce. Each affordance below exists for a
    /// specific one; none is speculative.
    struct Field: Equatable, Sendable, Codable {

        /// Optional: not every field is a `label: value` pair.
        let label: String?

        let value: String

        /// Bolds the VALUE. `⚡ Agent Streaming: *Yes*` shape.
        let emphasis: Bool

        /// Bolds the LABEL **including its colon**.
        ///
        /// ⚠️ The colon must be inside the bold or `/help` ships `*Security Tier*: Full Access`
        /// where it currently reads `*Security Tier:* Full Access`.
        let labelEmphasis: Bool

        /// Appends to the PREVIOUS line, separated by a single space, instead of starting a new one.
        ///
        /// ⚠️ Exists for `✅ Switched to: *<title>*` — emphasis mid-sentence. Without it the closest
        /// reachable form breaks the line after the colon, which is a visible change to the most
        /// common reply in the whole subsystem.
        let inline: Bool

        init(label: String? = nil, value: String, emphasis: Bool = false, labelEmphasis: Bool = false, inline: Bool = false) {
            self.label = label
            self.value = value
            self.emphasis = emphasis
            self.labelEmphasis = labelEmphasis
            self.inline = inline
        }

        /// A blank line. ⚠️ `/status` and `/help` both separate their heading from their body with
        /// one, and this is the only way to express it — an empty `body` is skipped entirely.
        /// Named rather than left as the idiom `Field(value: "")`, because the idiom is exactly what
        /// a later tidy-up deletes.
        static let spacer = Field(value: "")
    }

    /// ⚠️ `tone` has exactly one reader today and it is not text: `render` logs a `.failure` notice
    /// at `.error` and the rest at `.info`. None of the three platforms offers a colour or style
    /// channel for a plain message, so it deliberately does NOT prepend an emoji — the emoji in
    /// "✅ Switched to:" / "🛑 Cancelled…" is part of the body the command supplies, which is what
    /// keeps slice 1 byte-identical.
    let tone: Tone

    /// An emoji rendered BEFORE the bold title, outside the markers.
    ///
    /// ⚠️ Every shipping heading puts it there — `📊 *Devgentic Status*`, `🤖 *Devgentic ChatOps*`,
    /// `📋 *Your Conversations:*` — so folding it into `title` would emit `*📊 Devgentic Status*`.
    /// Visually identical on Telegram (emoji have no bold glyph) but not byte-identical, and this
    /// commit's whole value is that nothing changes.
    let icon: String?

    let title: String?

    /// ⚠️ PLAIN TEXT. The renderer owns markup, so this is escaped on the way out — which is what
    /// closes the live Telegram bug where a conversation title containing an unbalanced `*` or `_`
    /// is interpolated into a `parse_mode: Markdown` message and 400s the whole reply, swallowed by
    /// `try?`. Emphasis is available through `fields`, never by embedding `*` here.
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

        /// A subtitle, where the platform has somewhere to put one. ⚠️ Telegram has nowhere, so it
        /// drops this. Decoration; its loss is not logged, because a line per render for missing
        /// decoration is noise.
        let detail: String?

        let token: CallbackToken

        /// ⚠️ A FLAG, NOT A `"⭐ "` PREFIX. See this file's header.
        let isCurrent: Bool

        /// ⚠️ Telegram has no button styles and drops this. Decoration.
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

    /// The same view with every user- or model-supplied string run through the credential floor.
    ///
    /// ⚠️ SANITISED AS A VIEW, NOT AS RENDERED TEXT, and that is the whole point. Cleaning
    /// `Draft.text` alone would have left two holes: Slack renders its body into BLOCKS as well as
    /// the fallback text, and every platform puts conversation titles and profile names on BUTTON
    /// LABELS. A conversation's title is auto-set to the user's first prompt — so a prompt that
    /// contained a key becomes a button label, on a surface no text-level pass would have touched.
    ///
    /// ⚠️ CALLBACK TOKENS ARE NOT TOUCHED. They are ids and fixed verbs minted by this app, never
    /// user text, and rewriting one would break the round trip that makes the button work.
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
            // ⚠️ THE MOST EXPOSED STRINGS IN THE APP. A tool confirmation carries the tool's raw
            // ARGUMENTS — which is exactly where a key read out of a `.env` would appear, on its
            // way to a chat service, for a user who only wanted to approve a file write.
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
