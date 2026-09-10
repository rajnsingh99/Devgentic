// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteRendering.swift
//  Devgentic
//
//  Turning a `RemoteView` into each platform's payload — C3 of the ChatOps remote-interface plan.
//
//  ⚠️ THE THREE RENDERERS LIVE IN ONE FILE ON PURPOSE. Divergence between them is the defect this
//  whole refactor exists to remove; three files is how the bridges drifted apart in the first place.
//  Side by side, a difference has to be justified in the diff.
//
//  ⚠️ EVERY FUNCTION HERE IS `nonisolated static` OVER PLAIN VALUES — the `RunAdmissionPolicy` /
//  `ForegroundRunResolver` shape. A test drives a full view-to-wire-payload round trip with no
//  transport, no API client, no network and no view model. That is what makes the golden fixtures
//  possible, and the golden fixtures are the primary proof that C5–C7 change no observable output.
//
//  ⚠️⚠️ THE `parseMode` TRAP, WHICH IS WHY THIS FILE EXISTS RATHER THAN A HOSTED RENDERER.
//  `TelegramAPIClient.sendMessage` defaults `parseMode: "Markdown"` (TelegramAPIClient.swift:65) and
//  every BRIDGE call site takes that default, so `*Your Conversations:*` and `📊 *Devgentic Status*`
//  render bold today. `TelegramTransport` passes `parseMode: nil` at all seven of its OWN sites,
//  deliberately, to avoid parse failures on code-heavy agent output. Naively hosting a renderer on
//  the transport inherits the transport's `nil` and silently turns every bridge reply's formatting
//  into literal asterisks — on all five verbs, on the largest platform, with no error anywhere.
//  Here the parse mode is an explicit output of the renderer, and the golden fixture asserts it.
//

import Foundation
import os

// MARK: - Errors

enum RemoteRenderError: Error, Equatable {
    /// The destination's channel id is not a shape this platform can address.
    ///
    /// ⚠️ Exists so the Telegram renderer can THROW rather than force-unwrap. `TelegramTransport`
    /// already writes `Int64(chatID)!` at :33, :37, :45 and `Int(messageID)!` at :146 — safe only
    /// because the sole producer builds those strings from an `Int64` in the first place. New code
    /// does not inherit that assumption.
    case unaddressableChannel(provider: RemoteChannel.Provider, channelID: String)
}

// MARK: - Logging

/// Shared so the three `render` implementations cannot describe the same event three ways.
enum RemoteRenderLog {

    /// ⚠️ Every `.silent` view is logged with its CONSEQUENCE, per the standing logging rule. This
    /// replaces four naked `break`s in the bridges that log nothing at all, which is why a remote
    /// user who types something unrecognised today gets no reply and leaves no trace.
    nonisolated static func silence(_ silence: RemoteSilence, channel: RemoteChannel, logger: Logger) {
        logger.info("\(silence.tag) \(channel.provider.rawValue) channel \(channel.channelID) — nothing posted. CONSEQUENCE: \(silence.consequence)")
    }

    /// `Notice.tone`'s one reader: a failure notice is logged at `.error`, everything else at
    /// `.info`. Nothing else about the tone reaches the wire — no platform offers a colour or
    /// style channel for a plain message.
    nonisolated static func posted(_ view: RemoteView, channel: RemoteChannel, logger: Logger) {
        guard case .notice(let notice) = view, notice.tone == .failure else { return }
        logger.error("[CHATOPS/RENDER] Posted a FAILURE notice to \(channel.provider.rawValue) channel \(channel.channelID): \(notice.body). CONSEQUENCE: the remote user was told the operation failed; if this is unexpected, the command that produced it is the place to look.")
    }
}

// MARK: - Escaping

/// Escaping user-controlled text for each platform's text dialect.
///
/// ⚠️ THIS CLOSES A LIVE BUG, not a hypothetical one. The bridges interpolate conversation titles —
/// which are auto-derived from the user's own first message — into `parse_mode: Markdown` messages
/// at `ChatOpsBridge.swift:351` and elsewhere. A title containing an unbalanced `*`, `_`, `[` or a
/// backtick makes Telegram reject the WHOLE message with a 400, and every one of those call sites is
/// `_ = try? await`, so the remote user simply receives nothing and no log records why.
enum RemoteMarkupEscaping {

    /// Telegram legacy `Markdown` (not MarkdownV2) treats exactly four characters as special.
    /// MarkdownV2's much longer list does not apply — the app sends `"Markdown"`.
    nonisolated static func telegram(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if character == "_" || character == "*" || character == "`" || character == "[" {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Discord message markdown. Unbalanced markers render oddly rather than erroring, so this is
    /// cosmetic rather than a delivery fix — but the same title reaches all three platforms.
    nonisolated static func discord(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if "*_~`|>".contains(character) {
                out.append("\\")
            }
            out.append(character)
        }
        return out
    }

    /// Slack `mrkdwn` requires HTML-entity escaping for these three, and only these three.
    /// ⚠️ `&` must be replaced FIRST or the entities it introduces are re-escaped.
    nonisolated static func slack(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    nonisolated static func escape(_ text: String, for markup: RemoteCapabilities.Markup) -> String {
        switch markup {
        case .telegramMarkdown: return telegram(text)
        case .discordMarkdown:  return discord(text)
        case .slackMrkdwn:      return slack(text)
        }
    }
}

// MARK: - Length budget

/// Making a message fit the platform that has to accept it.
///
/// ⚠️⚠️ WITHOUT THIS, AN OVER-LONG REPLY DOES NOT ARRIVE TRUNCATED — IT DOES NOT ARRIVE. `render`
/// posts through the unchunked `sendMessage` / `postMessage`, so the platform rejects the request
/// with a 400 and the remote user sees nothing at all for a command that worked. `/history 20`
/// builds roughly 4 100 characters (20 lines x a 200-character preview plus icons and separators),
/// which clears Discord's 2 000 from ten turns, Slack's 3 000 block limit from about fifteen, and
/// Telegram's 4 096 at twenty — before Markdown escaping adds a backslash per metacharacter.
///
/// ⚠️ WHOLE LINES GO, NEVER HALF A SENTENCE. A transcript is a list, and cutting it mid-word reads
/// as corruption; dropping trailing entries and SAYING SO reads as a limit. The count of what went
/// is part of the message because "the last thing I see is the newest" would otherwise be false.
enum RemoteTextBudget {

    /// ⚠️ UTF-16, matching `RemoteCapabilities.maxMessageLength`. See that property for why the
    /// conservative metric is the safe one.
    nonisolated static func measure(_ text: String) -> Int { text.utf16.count }

    /// Joins `lines` with newlines, dropping whole trailing lines until the result fits.
    ///
    /// - Returns: the fitted text. Never longer than `limit`.
    nonisolated static func fit(lines: [String], limit: Int) -> String {
        let joined = lines.joined(separator: "\n")
        guard measure(joined) > limit else { return joined }

        var kept: [String] = []
        var used = 0
        var dropped = lines.count

        for line in lines {
            // +1 for the newline this line will need, once there is something before it.
            let cost = measure(line) + (kept.isEmpty ? 0 : 1)
            // ⚠️ THE MARKER'S OWN LENGTH IS RESERVED, using the worst case rather than the actual
            // count — the actual count depends on how many lines are dropped, which is not known
            // until the loop ends. Reserving less would let the marker push the result back over.
            guard used + cost + maxMarkerLength <= limit else { break }
            kept.append(line)
            used += cost
            dropped -= 1
        }

        guard dropped > 0 else { return joined }
        // ⚠️ Even the first line may not fit — a single 5 000-character agent reply. Then there is
        // nothing to keep and the blob form is the only honest output.
        guard !kept.isEmpty else { return fit(lines.first ?? "", limit: limit) }
        return (kept + [marker(dropped: dropped)]).joined(separator: "\n")
    }

    /// Hard-bounds a blob with no line structure worth preserving.
    nonisolated static func fit(_ text: String, limit: Int) -> String {
        guard measure(text) > limit else { return text }
        let room = max(0, limit - measure(blobMarker))
        // ⚠️ Cut on a UTF-16 boundary that is also a Character boundary: `String(prefix:)` over
        // Characters cannot split a grapheme, which slicing utf16 directly can.
        var out = ""
        var used = 0
        for character in text {
            let cost = measure(String(character))
            guard used + cost <= room else { break }
            out.append(character)
            used += cost
        }
        return out + blobMarker
    }

    private nonisolated static let blobMarker = "…"

    private nonisolated static func marker(dropped: Int) -> String {
        "… \(dropped) more line\(dropped == 1 ? "" : "s") did not fit this chat platform's message limit."
    }

    /// The longest `marker(dropped:)` this can emit, so `fit` can reserve room before it knows the
    /// number. Six digits is far past any list this app builds.
    private nonisolated static let maxMarkerLength = measure("… 999999 more lines did not fit this chat platform's message limit.")
}

// MARK: - Shared text assembly

/// Building a notice's text is the same shape on all three platforms — only the emphasis markers
/// differ — so it is written once and parameterised, rather than three times and compared.
private enum NoticeText {

    /// - Parameter limit: the platform's `maxMessageLength`. ⚠️ REQUIRED, NOT DEFAULTED — a
    ///   default would be one platform's limit silently applied to the other two, and the whole
    ///   defect this closes is that the tightest cap was never considered.
    nonisolated static func build(
        _ notice: Notice,
        markup: RemoteCapabilities.Markup,
        limit: Int,
        bold: (String) -> String
    ) -> String {
        func escaped(_ text: String) -> String { RemoteMarkupEscaping.escape(text, for: markup) }

        var lines: [String] = []

        if let title = notice.title, !title.isEmpty {
            // ⚠️ The icon sits OUTSIDE the bold markers, matching every shipping heading
            // (`📊 *Devgentic Status*`). Folding it into `title` emits `*📊 Devgentic Status*`.
            let heading = bold(escaped(title))
            lines.append(notice.icon.map { "\(escaped($0)) \(heading)" } ?? heading)
        }
        if !notice.body.isEmpty {
            lines.append(escaped(notice.body))
        }

        for field in notice.fields {
            let value = field.emphasis ? bold(escaped(field.value)) : escaped(field.value)
            let piece: String
            if let label = field.label, !label.isEmpty {
                // ⚠️ The colon goes INSIDE the bold, or `/help` ships `*Security Tier*: Full Access`
                // where it currently reads `*Security Tier:* Full Access`.
                piece = field.labelEmphasis
                    ? "\(bold(escaped(label) + ":")) \(value)"
                    : "\(escaped(label)): \(value)"
            } else {
                piece = value
            }

            if field.inline, !lines.isEmpty {
                // Emphasis mid-sentence: `✅ Switched to:` and `*<title>*` on ONE line.
                lines[lines.count - 1] += " \(piece)"
            } else {
                lines.append(piece)
            }
        }
        // ⚠️ FITTED HERE, AFTER ESCAPING. Escaping ADDS characters (a backslash per Markdown
        // metacharacter on Telegram, per `*_~`|>` on Discord, an entity per `&<>` on Slack), so a
        // budget applied to the raw text would be measured against a shorter string than the one
        // actually sent — and a code-heavy transcript would clear the limit anyway.
        return RemoteTextBudget.fit(lines: lines, limit: limit)
    }
}

/// A chooser's heading, built once for all three platforms.
///
/// ⚠️ SHARED BECAUSE THE THREE HAD ALREADY DIVERGED HERE. Slack computed `bold(title)` before its
/// empty-chooser guard while Telegram and Discord computed it after, so the same empty chooser
/// rendered bold on one platform and plain on the other two — in the file whose header says a
/// difference must be justified in the diff. One builder, used by both branches, makes that
/// unrepresentable.
private enum ChooserHeading {

    nonisolated static func build(
        _ chooser: Chooser,
        markup: RemoteCapabilities.Markup,
        limit: Int,
        note: String? = nil,
        bold: (String) -> String
    ) -> String {
        func escaped(_ text: String) -> String { RemoteMarkupEscaping.escape(text, for: markup) }
        let heading = bold(escaped(chooser.title))
        var full = chooser.icon.map { "\(escaped($0)) \(heading)" } ?? heading
        // ⚠️ ESCAPED LIKE ANY OTHER TEXT even though this app writes it: the heading is fitted and
        // escaped as one string, and an unescaped tail would be the one place markup could leak.
        if let note { full += "\n" + escaped(note) }
        // ⚠️ A HEADING CAN BE USER TEXT. `/search <query>` puts the query in it verbatim, so this is
        // not a constant that obviously fits — and a rejected heading takes the whole button list
        // with it.
        return RemoteTextBudget.fit(full, limit: limit)
    }
}


/// The options a chooser can actually show on one platform, and what to say about the rest.
///
/// ⚠️ SHARED, because a per-renderer `prefix(_:)` is exactly how the three bridges drifted apart in
/// the first place — and because a trim that one platform reports and another performs silently is
/// worse than no trim at all.
private enum ChooserContent {

    /// - Returns: the buttons to render, in order, and a note for the heading when some were cut.
    nonisolated static func resolve(
        _ chooser: Chooser,
        capabilities: RemoteCapabilities
    ) -> (all: [Chooser.Option], note: String?) {
        let (kept, dropped) = RemoteChooserLayout.fit(
            optionCount: chooser.options.count,
            extraCount: chooser.extraActions.count,
            capabilities: capabilities
        )
        let all = Array(chooser.options.prefix(kept)) + chooser.extraActions
        guard dropped > 0 else { return (all, nil) }
        // ⚠️ THE COUNT IS IN THE MESSAGE, not just the log. A list silently showing 25 of 40 reads
        // as "that is all there is" — the same lie the `/search` scan bound and the transcript
        // budget both disclose rather than hide.
        return (all, "showing \(kept) of \(chooser.options.count) — \(dropped) more did not fit one message")
    }
}

// MARK: - Telegram

enum TelegramRemoteRenderer {

    /// What `render` will hand to `TelegramAPIClient.sendMessage`.
    struct Draft: Encodable {
        let text: String
        /// ⚠️ NOT a default. See this file's header — the whole point is that the parse mode is a
        /// decision the renderer makes and a fixture can assert, not a value inherited from
        /// whichever call site happens to be used.
        let parse_mode: String?
        /// ⚠️ TYPE-ERASED, not `InlineKeyboardMarkup?`. It was the concrete type, and that single
        /// choice is what made Telegram's only structured-input affordance unreachable: a
        /// `ForceReply` could not be expressed here even though `sendMessage` had always accepted
        /// one. The barrier was never the API — it was this field and the transport's literal
        /// `.map { .inline($0) }`.
        let reply_markup: SendMessagePayload.ReplyMarkup?
    }

    nonisolated static let capabilities = RemoteCapabilities.telegram

    /// `nil` means "post nothing" — a `.silent` view. (`.prompt` was served by the transport's own
    /// `sendHITLPrompt` when this was written; C8.5 moved it here, so it now returns a draft like
    /// every other case.)
    nonisolated static func draft(for view: RemoteView) -> Draft? {
        func bold(_ text: String) -> String { "*\(text)*" }

        switch view {
        case .silent:
            return nil

        case .prompt(let operationID, let kind):
            // ⚠️ MOVED VERBATIM from `TelegramTransport.sendHITLPrompt`, literals included. The text
            // is NOT escaped and `parse_mode` is nil — HITL prompts carry model-supplied tool names
            // and parameters, and running those through a Markdown parser is exactly the 400 the
            // notice path escapes to avoid. The asymmetry is deliberate; see this file's header.
            return promptDraft(operationID: operationID, kind: kind)

        case .notice(let notice):
            return Draft(
                text: NoticeText.build(notice, markup: capabilities.markup, limit: capabilities.maxMessageLength, bold: bold),
                parse_mode: "Markdown",
                reply_markup: nil
            )

        case .chooser(let chooser):
            let (all, note) = ChooserContent.resolve(chooser, capabilities: capabilities)
            let heading = ChooserHeading.build(chooser, markup: capabilities.markup, limit: capabilities.maxMessageLength, note: note, bold: bold)
            guard case .buttons(let rows) = RemoteChooserLayout.plan(optionCount: all.count, capabilities: capabilities) else {
                // ⚠️ An empty chooser renders as the heading with NO keyboard — never an empty one.
                // It is NOT the empty-state SENTENCE: producing "No conversations yet…" is the
                // command service's job, and it must not hand an empty chooser to a renderer at all.
                return Draft(text: heading, parse_mode: "Markdown", reply_markup: nil)
            }
            let keyboard = rows.map { row in
                row.map { index -> InlineKeyboardButton in
                    let option = all[index]
                    // ⚠️ `isCurrent` becomes the star HERE. Telegram has no styling and no subtitle,
                    // so `intent` and `detail` are dropped — decoration, deliberately not logged.
                    let label = (option.isCurrent ? "⭐ " : "") + option.label
                    return InlineKeyboardButton(
                        text: String(label.prefix(capabilities.maxLabelLength)),
                        callbackData: option.token.wire
                    )
                }
            }
            return Draft(
                text: heading,
                parse_mode: "Markdown",
                reply_markup: .inline(InlineKeyboardMarkup(inline_keyboard: keyboard))
            )
        }
    }

    /// The four HITL prompts, as Telegram payloads.
    ///
    /// ⚠️ `parse_mode` is nil on every arm — see the call site. Button labels are never markup.
    nonisolated static func promptDraft(operationID: UUID, kind: HITLType) -> Draft {
        // ⚠️ THE PROMPT ARMS NEED THIS MOST, not least. `toolConfirmation` caps its params at 500,
        // but `planReview`'s subtask list, `gate`'s prompt and `clarification`'s question are all
        // model-generated and UNBOUNDED — and a HITL prompt that the platform rejects leaves the run
        // parked with no prompt visible anywhere remote, which is strictly worse than a truncated
        // one: the buttons are what resolve it, and they arrive with the message or not at all.
        func fit(_ text: String) -> String {
            RemoteTextBudget.fit(lines: text.components(separatedBy: "\n"), limit: capabilities.maxMessageLength)
        }

        func approve(_ label: String) -> InlineKeyboardButton {
            InlineKeyboardButton(text: label, callbackData: CallbackToken.approveHITL(operationID: operationID).wire)
        }
        func deny(_ label: String) -> InlineKeyboardButton {
            InlineKeyboardButton(text: label, callbackData: CallbackToken.denyHITL(operationID: operationID).wire)
        }

        switch kind {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = """
            ⚠️ Tool Approval Required

            Tool: \(toolName)
            Params: \(truncatedParams)

            Tap to approve or deny:
            """
            return Draft(
                text: fit(messageText),
                parse_mode: nil,
                reply_markup: .inline(InlineKeyboardMarkup(inline_keyboard: [[approve("✅ Approve"), deny("❌ Deny")]]))
            )

        case .clarification(let question):
            // ⚠️ "REPLY TO THIS MESSAGE" IS LOAD-BEARING COPY, not politeness. A reply carries
            // `reply_to_message`, which is the only thing on the wire that says WHICH clarification
            // is being answered. Plain text still works as a fallback, but it is answered by
            // whichever clarification the provider cursor happens to point at.
            let messageText = """
            💬 Agent needs clarification:

            \(question)

            Reply to this message with your answer, or type /skip to skip.
            """
            return Draft(
                text: fit(messageText),
                parse_mode: nil,
                // Telegram has no modal; this is the platform ceiling for structured input.
                reply_markup: .forceReply(ForceReply(placeholder: "Your answer…"))
            )

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = """
            📋 Plan Review Required

            The agent has generated a plan with \(subtaskDescriptions.count) step(s):

            \(planList)

            Tap to approve or reject (edit on the Mac app):
            """
            return Draft(
                text: fit(messageText),
                parse_mode: nil,
                reply_markup: .inline(InlineKeyboardMarkup(inline_keyboard: [[approve("✅ Approve"), deny("❌ Reject")]]))
            )

        case .gate(let prompt, let options):
            let messageText = """
            🚦 Decision Required

            \(prompt)

            Choose an option:
            """
            // ⚠️ ONE BUTTON PER ROW on Telegram, unlike Discord's chunk-by-5.
            let rows = options.enumerated().map { idx, opt in
                [InlineKeyboardButton(
                    text: String(opt.prefix(70)),
                    callbackData: CallbackToken.gateChoice(operationID: operationID, optionIndex: idx).wire
                )]
            }
            return Draft(text: fit(messageText), parse_mode: nil, reply_markup: .inline(InlineKeyboardMarkup(inline_keyboard: rows)))
        }
    }
}

// MARK: - Discord

enum DiscordRemoteRenderer {

    struct Draft: Encodable {
        let content: String
        let components: [DiscordComponent]?
    }

    nonisolated static let capabilities = RemoteCapabilities.discord

    nonisolated static func draft(for view: RemoteView) -> Draft? {
        func bold(_ text: String) -> String { "**\(text)**" }

        switch view {
        case .silent:
            return nil

        case .prompt(let operationID, let kind):
            // ⚠️ MOVED VERBATIM from `DiscordTransport.sendHITLPrompt`. Unescaped: the text carries
            // model-supplied tool names and parameters.
            return promptDraft(operationID: operationID, kind: kind)

        case .notice(let notice):
            return Draft(
                content: NoticeText.build(notice, markup: capabilities.markup, limit: capabilities.maxMessageLength, bold: bold),
                components: nil
            )

        case .chooser(let chooser):
            let (all, note) = ChooserContent.resolve(chooser, capabilities: capabilities)
            let heading = ChooserHeading.build(chooser, markup: capabilities.markup, limit: capabilities.maxMessageLength, note: note, bold: bold)
            guard case .buttons(let rows) = RemoteChooserLayout.plan(optionCount: all.count, capabilities: capabilities) else {
                return Draft(content: heading, components: nil)
            }
            let components = rows.map { row in
                DiscordComponent.actionRow(row.map { index -> DiscordComponent in
                    let option = all[index]
                    let label = (option.isCurrent ? "⭐ " : "") + option.label
                    return DiscordComponent.button(
                        label: String(label.prefix(capabilities.maxLabelLength)),
                        customID: option.token.wire,
                        style: style(for: option.intent)
                    )
                })
            }
            return Draft(content: heading, components: components)
        }
    }

    nonisolated static func style(for intent: Chooser.Intent) -> Int {
        switch intent {
        case .neutral:     return DiscordComponent.secondaryStyle
        case .primary:     return DiscordComponent.primaryStyle
        case .destructive: return DiscordComponent.dangerStyle
        }
    }

    /// The four HITL prompts, as Discord payloads.
    nonisolated static func promptDraft(operationID: UUID, kind: HITLType) -> Draft {
        // ⚠️ THE PROMPT ARMS NEED THIS MOST, not least. `toolConfirmation` caps its params at 500,
        // but `planReview`'s subtask list, `gate`'s prompt and `clarification`'s question are all
        // model-generated and UNBOUNDED — and a HITL prompt that the platform rejects leaves the run
        // parked with no prompt visible anywhere remote, which is strictly worse than a truncated
        // one: the buttons are what resolve it, and they arrive with the message or not at all.
        func fit(_ text: String) -> String {
            RemoteTextBudget.fit(lines: text.components(separatedBy: "\n"), limit: capabilities.maxMessageLength)
        }

        func button(_ label: String, _ token: CallbackToken, _ style: Int) -> DiscordComponent {
            DiscordComponent.button(label: label, customID: token.wire, style: style)
        }
        let approveToken = CallbackToken.approveHITL(operationID: operationID)
        let denyToken = CallbackToken.denyHITL(operationID: operationID)

        switch kind {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = """
            ⚠️ **Tool Approval Required**

            **Tool:** \(toolName)
            **Params:** \(truncatedParams)

            Tap to approve or deny:
            """
            let row = DiscordComponent.actionRow([
                button("✅ Approve", approveToken, DiscordComponent.successStyle),
                button("❌ Deny", denyToken, DiscordComponent.dangerStyle),
            ])
            return Draft(content: fit(messageText), components: [row])

        case .clarification(let question):
            // ⚠️ THE BUTTON IS WHAT MAKES A MODAL POSSIBLE AT ALL. A modal can only be opened as
            // the response to a LIVE interaction (id + token, valid ~3s), and a clarification is
            // raised asynchronously by the agent with no interaction in flight — so there is
            // nothing to open one against until the user taps something. Clarification was the one
            // HITL kind rendered with no affordance anywhere, which is exactly why its answer could
            // only ever be correlated by a provider-wide cursor.
            let messageText = """
            💬 **Agent needs clarification:**

            \(question)

            Tap **Answer** to reply, or type /skip to skip.
            """
            return Draft(
                content: fit(messageText),
                components: [.actionRow([
                    .button(
                        label: "✍️ Answer",
                        customID: CallbackToken.answerClarification(operationID: operationID).wire,
                        style: DiscordComponent.primaryStyle
                    )
                ])]
            )

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = """
            📋 **Plan Review Required**

            The agent has generated a plan with \(subtaskDescriptions.count) step(s):

            \(planList)

            Tap to approve or reject (edit on the Mac app):
            """
            let row = DiscordComponent.actionRow([
                button("✅ Approve", approveToken, DiscordComponent.successStyle),
                button("❌ Reject", denyToken, DiscordComponent.dangerStyle),
            ])
            return Draft(content: fit(messageText), components: [row])

        case .gate(let prompt, let options):
            let messageText = """
            🚦 **Decision Required**

            \(prompt)

            Choose an option:
            """
            let buttons = options.enumerated().map { idx, opt in
                button(
                    String(opt.prefix(70)),
                    CallbackToken.gateChoice(operationID: operationID, optionIndex: idx),
                    DiscordComponent.secondaryStyle
                )
            }
            // ⚠️ CHUNK BY 5 — an ActionRow's hard limit, and NOT the same as the chooser path.
            let rows = stride(from: 0, to: buttons.count, by: 5).map { start in
                DiscordComponent.actionRow(Array(buttons[start..<min(start + 5, buttons.count)]))
            }
            return Draft(content: fit(messageText), components: rows)
        }
    }
}

// MARK: - Slack

enum SlackRemoteRenderer {

    struct Draft: Encodable {
        let text: String
        let blocks: [SlackBlock]?
    }

    nonisolated static let capabilities = RemoteCapabilities.slack

    nonisolated static func draft(for view: RemoteView) -> Draft? {
        func bold(_ text: String) -> String { "*\(text)*" }

        switch view {
        case .silent:
            return nil

        case .prompt(let operationID, let kind):
            // ⚠️ MOVED VERBATIM from `SlackTransport.sendHITLPrompt`. Unescaped, for the same reason
            // as the other two.
            return promptDraft(operationID: operationID, kind: kind)

        case .notice(let notice):
            // ⚠️ `text` carries the flat form as well as the blocks. That is not redundancy: Slack
            // uses it for the notification preview and for clients that cannot render blocks, and
            // `SlackTransport` already follows this pattern.
            let text = NoticeText.build(notice, markup: capabilities.markup, limit: capabilities.maxMessageLength, bold: bold)
            return Draft(text: text, blocks: [.sectionBlock(text: text)])

        case .chooser(let chooser):
            let (all, note) = ChooserContent.resolve(chooser, capabilities: capabilities)
            let title = ChooserHeading.build(chooser, markup: capabilities.markup, limit: capabilities.maxMessageLength, note: note, bold: bold)
            guard case .buttons(let rows) = RemoteChooserLayout.plan(optionCount: all.count, capabilities: capabilities) else {
                return Draft(text: title, blocks: [.sectionBlock(text: title)])
            }
            // Slack has no per-row concept, so `RemoteCapabilities.slack.buttonsPerRow` is 25 and
            // the layout returns a single row — one actions block, matching the shipping bridge.
            var blocks: [SlackBlock] = [.sectionBlock(text: title)]
            for row in rows {
                blocks.append(.actionsBlock(elements: row.map { index -> SlackBlockElement in
                    let option = all[index]
                    let label = (option.isCurrent ? "⭐ " : "") + option.label
                    return SlackBlockElement.button(
                        text: String(label.prefix(capabilities.maxLabelLength)),
                        actionID: option.token.wire,
                        value: option.token.wire,
                        style: style(for: option.intent)
                    )
                }))
            }
            return Draft(text: title, blocks: blocks)
        }
    }

    /// ⚠️ Slack has no "secondary" style — the absence of a style IS the default button. Returning
    /// a literal would change every existing button's appearance.
    nonisolated static func style(for intent: Chooser.Intent) -> String? {
        switch intent {
        case .neutral:     return nil
        case .primary:     return SlackBlockElement.primaryStyle
        case .destructive: return SlackBlockElement.dangerStyle
        }
    }

    /// The four HITL prompts, as Slack payloads.
    nonisolated static func promptDraft(operationID: UUID, kind: HITLType) -> Draft {
        // ⚠️ THE PROMPT ARMS NEED THIS MOST, not least. `toolConfirmation` caps its params at 500,
        // but `planReview`'s subtask list, `gate`'s prompt and `clarification`'s question are all
        // model-generated and UNBOUNDED — and a HITL prompt that the platform rejects leaves the run
        // parked with no prompt visible anywhere remote, which is strictly worse than a truncated
        // one: the buttons are what resolve it, and they arrive with the message or not at all.
        func fit(_ text: String) -> String {
            RemoteTextBudget.fit(lines: text.components(separatedBy: "\n"), limit: capabilities.maxMessageLength)
        }

        func button(_ label: String, _ token: CallbackToken, _ value: String, _ style: String?) -> SlackBlockElement {
            SlackBlockElement.button(text: label, actionID: token.wire, value: value, style: style)
        }
        let approveToken = CallbackToken.approveHITL(operationID: operationID)
        let denyToken = CallbackToken.denyHITL(operationID: operationID)
        let hitlBlockID = "hitl_\(operationID.uuidString)"

        switch kind {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = "⚠️ *Tool Approval Required*\n\n*Tool:* \(toolName)\n*Params:* \(truncatedParams)"
            return Draft(text: fit(messageText), blocks: [
                .sectionBlock(text: fit(messageText)),
                .actionsBlock(elements: [
                    button("✅ Approve", approveToken, "approve", SlackBlockElement.primaryStyle),
                    button("❌ Deny", denyToken, "deny", SlackBlockElement.dangerStyle),
                ], blockID: hitlBlockID),
            ])

        case .clarification(let question):
            // ⚠️ THE BUTTON IS WHAT MAKES A MODAL REACHABLE. `views.open` needs a live
            // `trigger_id`, which arrives only on a button tap or a slash command — never on
            // the `events_api` path that carries typed text. A clarification is raised
            // asynchronously by the agent with no interaction in flight, so without an
            // affordance here there is nothing to open a modal against, ever.
            //
            // ⚠️ This arm previously posted TEXT ONLY, with a note that adding blocks would
            // change every clarification prompt on Slack. It does, and that is the change:
            // the text block carries the same words, and an actions block carries the button.
            let messageText = "💬 *Agent needs clarification:*\n\n\(question)\n\nTap *Answer* to reply, or type /skip to skip."
            return Draft(
                text: fit(messageText),
                blocks: [
                    .sectionBlock(text: fit(messageText)),
                    .actionsBlock(elements: [
                        .button(
                            text: "✍️ Answer",
                            actionID: CallbackToken.answerClarification(operationID: operationID).wire,
                            value: nil,
                            style: SlackBlockElement.primaryStyle
                        )
                    ])
                ]
            )

        case .planReview(let subtaskDescriptions):
            let planList = subtaskDescriptions.enumerated()
                .map { "  \($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            let messageText = "📋 *Plan Review Required*\n\nThe agent has generated a plan with \(subtaskDescriptions.count) step(s):\n\n\(planList)\n\nTap to approve or reject (edit on the Mac app):"
            return Draft(text: fit(messageText), blocks: [
                .sectionBlock(text: fit(messageText)),
                .actionsBlock(elements: [
                    button("✅ Approve", approveToken, "approve", SlackBlockElement.primaryStyle),
                    button("❌ Reject", denyToken, "deny", SlackBlockElement.dangerStyle),
                ], blockID: hitlBlockID),
            ])

        case .gate(let prompt, let options):
            let messageText = "🚦 *Decision Required*\n\n\(prompt)\n\nChoose an option:"
            let buttons = options.enumerated().map { idx, opt in
                button(
                    String(opt.prefix(70)),
                    CallbackToken.gateChoice(operationID: operationID, optionIndex: idx),
                    "gate_\(idx)",
                    nil
                )
            }
            // ⚠️⚠️ CHUNKED BY 5 HERE, but the CHOOSER path puts up to 25 in ONE actions block. The
            // two shipping comments about Slack's limit contradict each other (SlackTransport says
            // 5, SlackChatOpsBridge says 25 and is correct); both BEHAVIOURS are preserved because
            // changing either is a visible rendering change, not a refactor.
            var blocks: [SlackBlock] = [.sectionBlock(text: fit(messageText))]
            for start in stride(from: 0, to: buttons.count, by: 5) {
                blocks.append(.actionsBlock(
                    elements: Array(buttons[start..<min(start + 5, buttons.count)]),
                    blockID: "\(hitlBlockID)_\(start)"
                ))
            }
            return Draft(text: fit(messageText), blocks: blocks)
        }
    }
}
