// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteChooserLayout.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// MARK: - Capabilities

/// What one platform can actually render: facts about the platform, not preferences.
/// Constants come from the shipping bridges rather than platform documentation, so current output is preserved
/// byte for byte; where the code and the documentation disagree, the code wins.
struct RemoteCapabilities: Equatable, Sendable, Codable {

    /// How many buttons sit on one visual row.
    /// Telegram 1 (full-width rows), Discord 5 (an ActionRow's limit), Slack 25 (no per-row concept: one actions block).
    let buttonsPerRow: Int

    // Why: follows the Slack bridge's single actions block (up to 21 elements); gate buttons take a separate path that
    // chunks by 5, so the two Slack limits describe different code paths.
    /// The most buttons the platform will accept in one message.
    let maxButtons: Int

    /// Where a button label is truncated. Telegram 60, Discord 80, Slack 75 — all transcribed from
    /// the current `prefix(_:)` calls.
    let maxLabelLength: Int

    /// Bytes available to a callback payload. Telegram's 64 is the binding constraint for the
    /// shared grammar; see `CallbackToken`.
    let callbackPayloadBudget: Int

    // Why: count UTF-16 units, not graphemes: an emoji is one grapheme but these APIs count closer to code units, so
    // under-counting loses the whole message while over-counting only truncates a little early.
    /// The most text the platform will accept in one message, in UTF-16 units.
    /// Telegram 4096 (`sendMessage` text), Discord 2000 (message `content`), Slack 3000 (a `section` block's text, not
    /// `chat.postMessage`'s 40 000). `render` posts unchunked, so an over-long notice is rejected rather than split.
    let maxMessageLength: Int

    // Why: a renderer hosted on the transport that ignores the dialect would turn bridge replies'
    // Markdown into literal asterisks.
    /// The text dialect the platform understands.
    /// `TelegramAPIClient.sendMessage` defaults `parseMode` to "Markdown" and the bridges take that default,
    /// whereas `TelegramTransport` passes `nil`; the renderer chooses per view kind from this declared dialect.
    let markup: Markup

    enum Markup: String, Equatable, Sendable, Codable {
        /// Telegram's legacy `Markdown` parse mode.
        case telegramMarkdown
        /// Discord message markdown — always on, no flag to pass.
        case discordMarkdown
        /// Slack `mrkdwn` inside section blocks.
        case slackMrkdwn
    }

    static let telegram = RemoteCapabilities(
        buttonsPerRow: 1,
        maxButtons: 100,
        maxLabelLength: 60,
        callbackPayloadBudget: 64,
        maxMessageLength: 4096,
        markup: .telegramMarkdown
    )

    static let discord = RemoteCapabilities(
        buttonsPerRow: 5,
        maxButtons: 25,     // 5 ActionRows × 5 buttons
        maxLabelLength: 80,
        callbackPayloadBudget: 100,
        maxMessageLength: 2000,
        markup: .discordMarkdown
    )

    static let slack = RemoteCapabilities(
        buttonsPerRow: 25,  // no per-row concept; one actions block holds them all
        maxButtons: 25,
        maxLabelLength: 75,
        callbackPayloadBudget: 255,
        maxMessageLength: 3000,
        markup: .slackMrkdwn
    )

    static func of(_ provider: RemoteChannel.Provider) -> RemoteCapabilities {
        switch provider {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        }
    }
}

// MARK: - Layout

/// Deciding how a set of options is presented. Pure, over plain values.
enum RemoteChooserLayout {

    /// What the renderer should draw.
    enum Plan: Equatable, Sendable {

        /// No options at all: a chooser with nothing in it becomes a notice, never an empty keyboard.
        /// Making it a distinct plan means a renderer cannot forget.
        case notice

        /// Rows of option INDICES. Indices rather than options so that "no option was dropped" is
        /// checkable by set comparison rather than by trusting the renderer.
        case buttons(rows: [[Int]])
    }

    // Why: truncating here would silently hide actions while the list still looked complete; renderers trim visibly via
    // `fit(optionCount:extraCount:capabilities:)` before calling this.
    /// Lays `optionCount` options out for `capabilities`.
    /// Total by construction: the returned rows cover every index `0..<optionCount`, even beyond `maxButtons`.
    /// Whether the platform accepts the result is asked through `exceedsCapacity(optionCount:capabilities:)`.
    nonisolated static func plan(optionCount: Int, capabilities: RemoteCapabilities) -> Plan {
        guard optionCount > 0 else { return .notice }
        let perRow = max(1, capabilities.buttonsPerRow)
        var rows: [[Int]] = []
        var index = 0
        while index < optionCount {
            let end = min(index + perRow, optionCount)
            rows.append(Array(index..<end))
            index = end
        }
        return .buttons(rows: rows)
    }

    /// Whether this many options exceeds what the platform will accept in one message.
    /// Lets a renderer check capacity instead of relying on its own judgement or a silent `prefix(_:)`.
    nonisolated static func exceedsCapacity(optionCount: Int, capabilities: RemoteCapabilities) -> Bool {
        optionCount > capabilities.maxButtons
    }

    // Why: showing everything is not on offer: Discord rejects a message above 5 ActionRows outright, so trim visibly here
    // rather than lose the whole message; `plan` itself stays total.
    /// How many options survive, and how many are dropped, when the extra actions must be kept.
    /// Extras ("Previous", "Next", "New Conversation") are preserved and options are trimmed from the end, so navigation
    /// still reaches the dropped rows. Returns how many of `optionCount` to render and how many were dropped.
    nonisolated static func fit(
        optionCount: Int,
        extraCount: Int,
        capabilities: RemoteCapabilities
    ) -> (kept: Int, dropped: Int) {
        let capacity = capabilities.maxButtons
        guard optionCount + extraCount > capacity else { return (optionCount, 0) }
        // `max(0, ...)` because extras alone could fill the budget; a negative count would crash instead of rendering badly.
        let kept = max(0, capacity - extraCount)
        return (min(optionCount, kept), optionCount - min(optionCount, kept))
    }
}
