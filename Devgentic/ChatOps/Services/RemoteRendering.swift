// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteRendering.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import os

// MARK: - Errors

/// Errors a renderer throws when a `RemoteView` cannot be turned into a platform payload.
enum RemoteRenderError: Error, Equatable {
    /// The destination's channel id is not a shape this platform can address; lets the Telegram renderer throw instead of
    /// force-unwrapping.
    case unaddressableChannel(provider: RemoteChannel.Provider, channelID: String)
}

// MARK: - Logging

/// Shared so the three `render` implementations cannot describe the same event three ways.
enum RemoteRenderLog {

    /// Logs every `.silent` view with its consequence; the level follows `strandsTheUser`, so a silence that leaves a remote
    /// user without a reply is `.warning` or above and reaches the persisted ring buffer.
    nonisolated static func silence(_ silence: RemoteSilence, channel: RemoteChannel, logger: DGLogger) {
        let line = "\(silence.tag) \(channel.provider.rawValue) channel \(channel.channelID) — nothing posted. CONSEQUENCE: \(silence.consequence)"
        if silence.strandsTheUser {
            logger.warning(line)
        } else {
            logger.info(line)
        }
    }

    /// `Notice.tone`'s one reader: a failure notice is logged at `.error`, everything else at
    /// `.info`. Nothing else about the tone reaches the wire — no platform offers a colour or
    /// style channel for a plain message.
    nonisolated static func posted(_ view: RemoteView, channel: RemoteChannel, logger: DGLogger) {
        guard case .notice(let notice) = view, notice.tone == .failure else { return }
        logger.error("[CHATOPS/RENDER] Posted a FAILURE notice to \(channel.provider.rawValue) channel \(channel.channelID): \(notice.body). CONSEQUENCE: the remote user was told the operation failed; if this is unexpected, the command that produced it is the place to look.")
    }
}

// MARK: - Escaping

/// Escaping user-controlled text for each platform's text dialect. Titles derived from user messages can contain
/// unbalanced Markdown, which makes Telegram reject the whole message with a 400.
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

    /// Slack `mrkdwn` requires HTML-entity escaping for exactly these three characters; `&` must be replaced first or its
    /// entities are re-escaped.
    nonisolated static func slack(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // Why: matches an exact closed set of control sequences, not a loose shape, so prose cannot trigger it; setting
    // `link_names` would make this insufficient.
    /// Strips Slack's channel-wide broadcast sequences (`<!channel>`, `<!here>`, `<!everyone>`) out of text this app did not
    /// write, rendering the plain form (`@channel`), which is inert as long as `link_names` is never set.
    nonisolated static func withoutSlackBroadcasts(_ text: String) -> String {
        var out = text
        for broadcast in ["channel", "here", "everyone"] {
            out = out.replacingOccurrences(of: "<!\(broadcast)>", with: "@\(broadcast)")
            // Slack also accepts the labelled form `<!channel|@channel>`, which notifies identically, so both forms are matched.
            out = out.replacingOccurrences(
                of: "<!\(broadcast)\\|[^>]*>", with: "@\(broadcast)", options: .regularExpression)
        }
        return out
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

/// Making a message fit the platform that has to accept it: an over-long reply is rejected with a 400 and does not
/// arrive at all. Whole lines are dropped, never half a sentence, and the count of what went is part of the message.
enum RemoteTextBudget {

    /// Measures in UTF-16 units, matching `RemoteCapabilities.maxMessageLength`, the conservative metric.
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
            // The marker's own length is reserved at its worst case, since the real count is unknown until the loop ends.
            guard used + cost + maxMarkerLength <= limit else { break }
            kept.append(line)
            used += cost
            dropped -= 1
        }

        guard dropped > 0 else { return joined }
        // Even the first line may not fit; with nothing to keep, the cut-down blob form is the only honest output.
        guard !kept.isEmpty else { return fit(lines.first ?? "", limit: limit) }
        return (kept + [marker(dropped: dropped)]).joined(separator: "\n")
    }

    /// Hard-bounds a blob with no line structure worth preserving.
    nonisolated static func fit(_ text: String, limit: Int) -> String {
        guard measure(text) > limit else { return text }
        let room = max(0, limit - measure(blobMarker))
        // Cut on a UTF-16 boundary that is also a Character boundary: slicing `utf16` directly can split a grapheme.
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

    /// Splits `text` into pieces that each fit `limit` (UTF-16 units), preferring paragraph then line boundaries. Cuts
    /// always fall on a Character boundary; a single grapheme over `limit` is emitted alone, over budget, so progress is
    /// guaranteed.
    nonisolated static func chunk(_ text: String, limit: Int) -> [String] {
        guard limit > 0, measure(text) > limit else { return [text] }

        var chunks: [String] = []
        var remaining = Substring(text)

        while !remaining.isEmpty {
            if measure(String(remaining)) <= limit {
                chunks.append(String(remaining))
                break
            }

            // The furthest Character boundary that still fits the UTF-16 budget.
            var fitEnd = remaining.startIndex
            var used = 0
            var index = remaining.startIndex
            while index < remaining.endIndex {
                let cost = measure(String(remaining[index]))
                guard used + cost <= limit else { break }
                used += cost
                index = remaining.index(after: index)
                fitEnd = index
            }

            let window = remaining[remaining.startIndex..<fitEnd]
            let cut: Substring.Index
            if let paragraph = window.range(of: "\n\n", options: .backwards) {
                cut = paragraph.upperBound
            } else if let line = window.range(of: "\n", options: .backwards) {
                cut = line.upperBound
            } else {
                cut = fitEnd
            }

            // See the progress note above.
            let safeCut = cut > remaining.startIndex ? cut : remaining.index(after: remaining.startIndex)
            chunks.append(String(remaining[remaining.startIndex..<safeCut]))
            remaining = remaining[safeCut...]
        }

        return chunks
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

    /// - Parameter limit: the platform's `maxMessageLength`; required, not defaulted, so one platform's limit is never
    /// applied to another.
    nonisolated static func build(
        _ notice: Notice,
        markup: RemoteCapabilities.Markup,
        limit: Int,
        bold: (String) -> String
    ) -> String {
        func escaped(_ text: String) -> String { RemoteMarkupEscaping.escape(text, for: markup) }

        var lines: [String] = []

        if let title = notice.title, !title.isEmpty {
            // The icon sits outside the bold markers, matching every shipping heading.
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
                // The colon goes inside the bold marker (`*Security Tier:* Full Access`).
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
        // Fitted after escaping, because escaping adds characters and a budget applied to the raw text would measure a shorter
        // string than the one sent.
        return RemoteTextBudget.fit(lines: lines, limit: limit)
    }
}

/// A chooser's heading, built once for all three platforms so an empty chooser renders identically everywhere.
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
        // Escaped like any other text even though this app writes it: the heading is fitted and escaped as one string.
        if let note { full += "\n" + escaped(note) }
        // A heading can be user text (`/search <query>` puts the query in verbatim), and a rejected heading takes the whole
        // button list with it.
        return RemoteTextBudget.fit(full, limit: limit)
    }
}


/// The options a chooser can actually show on one platform, and what to say about the rest; shared so a trim is never
/// reported on one platform and performed silently on another.
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
        // The count is in the message, not just the log: a list silently showing 25 of 40 reads as 'that is all there is'.
        return (all, "showing \(kept) of \(chooser.options.count) — \(dropped) more did not fit one message")
    }
}

// MARK: - Telegram

enum TelegramRemoteRenderer {

    /// What `render` will hand to `TelegramAPIClient.sendMessage`.
    struct Draft: Encodable {
        let text: String
        /// Not defaulted: the parse mode is a decision the renderer makes and a fixture can assert, not a value inherited from a
        /// call site.
        let parse_mode: String?
        /// Type-erased rather than `InlineKeyboardMarkup?` so a `ForceReply` can be expressed as well as an inline keyboard.
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
            // The prompt text is not escaped and `parse_mode` is nil: HITL prompts carry model-supplied tool names and parameters,
            // and a Markdown parser would reject them with a 400. The asymmetry with the notice path is deliberate.
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
                // An empty chooser renders as the heading with no keyboard; the empty-state sentence is the command service's job.
                return Draft(text: heading, parse_mode: "Markdown", reply_markup: nil)
            }
            let keyboard = rows.map { row in
                row.map { index -> InlineKeyboardButton in
                    let option = all[index]
                    // `isCurrent` becomes the star here; Telegram has no styling or subtitle, so `intent` and `detail` are dropped.
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

    /// The four HITL prompts, as Telegram payloads; `parse_mode` is nil on every arm and button labels are never markup.
    nonisolated static func promptDraft(operationID: UUID, kind: HITLType) -> Draft {
        // The prompt arms need fitting most: `planReview`, `gate` and `clarification` text is model-generated and unbounded,
        // and a rejected prompt leaves the run parked with nothing visible remotely.
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
            // 'Reply to this message' is load-bearing copy: a reply carries `reply_to_message`, the only thing on the wire that
            // says which clarification is being answered; plain text falls back to the provider cursor.
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
            // One button per row on Telegram, unlike Discord's chunk-by-5.
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
            // Unescaped: the text carries model-supplied tool names and parameters.
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
        // The prompt arms need fitting most: `planReview`, `gate` and `clarification` text is model-generated and unbounded,
        // and a rejected prompt leaves the run parked with nothing visible remotely.
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
            // The button is what makes a modal possible: a modal opens only as the response to a live interaction (valid ~3s), and
            // a clarification is raised asynchronously with none in flight.
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
            // Chunk by 5, an ActionRow's hard limit; not the same as the chooser path.
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
            // Unescaped, as on the other platforms.
            return promptDraft(operationID: operationID, kind: kind)

        case .notice(let notice):
            // `text` carries the flat form as well as the blocks: Slack uses it for the notification preview and for clients that
            // cannot render blocks.
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

    /// Slack has no 'secondary' style: the absence of a style is the default button, so nil is returned for it.
    nonisolated static func style(for intent: Chooser.Intent) -> String? {
        switch intent {
        case .neutral:     return nil
        case .primary:     return SlackBlockElement.primaryStyle
        case .destructive: return SlackBlockElement.dangerStyle
        }
    }

    /// The four HITL prompts, as Slack payloads.
    nonisolated static func promptDraft(operationID: UUID, kind: HITLType) -> Draft {
        // The prompt arms need fitting most: `planReview`, `gate` and `clarification` text is model-generated and unbounded,
        // and a rejected prompt leaves the run parked with nothing visible remotely.
        func fit(_ text: String) -> String {
            RemoteTextBudget.fit(lines: text.components(separatedBy: "\n"), limit: capabilities.maxMessageLength)
        }

        /// Escapes model-supplied text only, never the app's own literals: `sectionBlock` hard-codes `mrkdwn`, so raw tool
        /// names, parameters, questions and plan steps could fire broadcasts or forge links. Runs before `fit`, since escaping
        /// lengthens the text; button labels need none.
        func safe(_ modelText: String) -> String { RemoteMarkupEscaping.slack(modelText) }

        func button(_ label: String, _ token: CallbackToken, _ value: String, _ style: String?) -> SlackBlockElement {
            SlackBlockElement.button(text: label, actionID: token.wire, value: value, style: style)
        }
        let approveToken = CallbackToken.approveHITL(operationID: operationID)
        let denyToken = CallbackToken.denyHITL(operationID: operationID)
        let hitlBlockID = "hitl_\(operationID.uuidString)"

        switch kind {
        case .toolConfirmation(let toolName, let params):
            let truncatedParams = String(params.prefix(500))
            let messageText = "⚠️ *Tool Approval Required*\n\n*Tool:* \(safe(toolName))\n*Params:* \(safe(truncatedParams))"
            return Draft(text: fit(messageText), blocks: [
                .sectionBlock(text: fit(messageText)),
                .actionsBlock(elements: [
                    button("✅ Approve", approveToken, "approve", SlackBlockElement.primaryStyle),
                    button("❌ Deny", denyToken, "deny", SlackBlockElement.dangerStyle),
                ], blockID: hitlBlockID),
            ])

        case .clarification(let question):
            // The button is what makes a modal reachable: `views.open` needs a live `trigger_id`, which arrives only on a button
            // tap or slash command, never on the `events_api` path that carries typed text.
            let messageText = "💬 *Agent needs clarification:*\n\n\(safe(question))\n\nTap *Answer* to reply, or type /skip to skip."
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
                .map { "  \($0.offset + 1). \(safe($0.element))" }
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
            let messageText = "🚦 *Decision Required*\n\n\(safe(prompt))\n\nChoose an option:"
            let buttons = options.enumerated().map { idx, opt in
                button(
                    String(opt.prefix(70)),
                    CallbackToken.gateChoice(operationID: operationID, optionIndex: idx),
                    "gate_\(idx)",
                    nil
                )
            }
            // Chunked by 5 here, while the chooser path puts up to 25 in one actions block; both behaviours are preserved as
            // rendered today.
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
