// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteChooserLayout.swift
//  Devgentic
//
//  What each platform can render, and how a list of options is laid out on it — C2 of the ChatOps
//  remote-interface plan.
//
//  WHY A POLICY AND NOT THREE RENDERERS' PRIVATE OPINIONS. The affordance is chosen ONCE, here,
//  from plain values; the renderer only draws what it is told. That is the `RunAdmissionPolicy` /
//  `ForegroundRunResolver` shape — `nonisolated static` over plain values, so it is testable with
//  no actor, no transport and no network — and it is what keeps "platform-best" a property of the
//  system rather than three divergent copies. The current code is the counter-example: the same
//  conversation list is built three times and Discord already renders it two different ways
//  depending on whether it arrived as a message or a slash command.
//
//  ⚠️ SCOPE. Slice 1 preserves today's behaviour, and today every list is capped at ten. So this
//  file decides exactly two things: empty-becomes-a-notice, and how buttons are chunked into rows.
//  Select menus (Discord string select, Slack `static_select`) and pagination are NOT here — they
//  arrive with the feature that needs them, alongside their producer. A capability that nothing
//  reads is how dead vocabulary accumulates.
//

import Foundation

// MARK: - Capabilities

/// What one platform can actually render. Facts about the platform, not preferences.
///
/// ⚠️ Every constant is transcribed from the shipping bridges, not from platform documentation,
/// because slice 1 must preserve current output byte for byte. Where the code and the docs
/// disagree the code wins here and the divergence is recorded.
struct RemoteCapabilities: Equatable, Sendable, Codable {

    /// How many buttons sit on one visual row.
    ///
    /// Telegram 1 (full-width rows, `ChatOpsBridge.swift:196`), Discord 5 (an ActionRow's limit),
    /// Slack 25 — Slack has no per-row concept at all, so the whole set goes in one actions block.
    let buttonsPerRow: Int

    /// The most buttons the platform will accept in one message.
    ///
    /// ⚠️ SLACK'S TWO CONTRADICTORY COMMENTS, RESOLVED. `SlackChatOpsBridge.swift:278` says
    /// "max 25 elements per actions block, max 5 per row is a Discord limit not Slack" and builds
    /// ONE block of up to 21; `SlackTransport.swift:122` says "Slack caps an actions block at 5
    /// elements" and chunks gate buttons by 5. They describe DIFFERENT code paths and the bridge's
    /// comment is the accurate one. This value follows the bridge, because that is the chooser
    /// path. The gate path keeps its chunk-by-5 behaviour where it lives until C8.5 moves it.
    let maxButtons: Int

    /// Where a button label is truncated. Telegram 60, Discord 80, Slack 75 — all transcribed from
    /// the current `prefix(_:)` calls.
    let maxLabelLength: Int

    /// Bytes available to a callback payload. Telegram's 64 is the binding constraint for the
    /// shared grammar; see `CallbackToken`.
    let callbackPayloadBudget: Int

    /// The most text the platform will accept in ONE message, in UTF-16 units.
    ///
    /// ⚠️⚠️ THIS WAS MISSING AND IT COST `/history` ITS REPLY. `render` posts through the UNCHUNKED
    /// `sendMessage` / `postMessage` — chunking lives in `sendChunkedMessage`, which only the
    /// mirror's agent-reply path uses — so an over-long notice is not split, it is REJECTED, and
    /// the remote user receives nothing at all for a command that succeeded locally.
    ///
    /// ⚠️ THE THREE NUMBERS ARE DIFFERENT LIMITS, not one limit with three values.
    ///   - Telegram 4096: the `sendMessage` text cap.
    ///   - Discord 2000: the message `content` cap. The TIGHTEST, and the one that bit first —
    ///     ten 200-character transcript lines already exceed it.
    ///   - Slack 3000: a `section` block's `text` cap, NOT `chat.postMessage`'s 40 000. The
    ///     notice renderer puts the same string in the fallback text AND in a section block, so
    ///     the block's limit is the binding one.
    ///
    /// ⚠️ COUNTED IN UTF-16, deliberately conservative. `String.count` counts grapheme clusters, so
    /// an emoji is 1 — but these APIs count closer to code units, so a transcript full of emoji
    /// would measure short here and be rejected there. Over-counting truncates a little early;
    /// under-counting loses the whole message.
    let maxMessageLength: Int

    /// The text dialect the platform understands.
    ///
    /// ⚠️⚠️ THE `parseMode` TRAP LIVES HERE. `TelegramAPIClient.sendMessage` defaults
    /// `parseMode: "Markdown"` (TelegramAPIClient.swift:65), and every BRIDGE call site takes that
    /// default — so `*Your Conversations:*` and `📊 *Devgentic Status*` render bold today.
    /// `TelegramTransport` passes `parseMode: nil` at all seven of its own sites, deliberately, to
    /// avoid parse failures on code-heavy agent output. Hosting a renderer on the transport without
    /// noticing turns every bridge reply's formatting into literal asterisks, on all five verbs, on
    /// the largest platform. The dialect is declared here so the C3 renderer chooses per view kind
    /// rather than inheriting a default it never sees.
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

        /// No options at all. ⚠️ A chooser with nothing in it must become a NOTICE, never an empty
        /// keyboard — which is what all three bridges already do ("No conversations yet. Use /new
        /// to create one."). Making it a distinct plan means a renderer cannot forget.
        case notice

        /// Rows of option INDICES. Indices rather than options so that "no option was dropped" is
        /// checkable by set comparison rather than by trusting the renderer.
        case buttons(rows: [[Int]])
    }

    /// Lay `optionCount` options out for `capabilities`.
    ///
    /// ⚠️ TOTAL BY CONSTRUCTION: the returned rows always cover every index `0..<optionCount`,
    /// even when that exceeds `maxButtons`. Truncating here would silently hide actions from the
    /// user while the list still looked complete — losing DECORATION is acceptable degradation,
    /// losing an ACTION is not. Whether the platform will actually accept the result is a separate
    /// question, asked through `exceedsCapacity(optionCount:capabilities:)` so the renderer can log
    /// the consequence instead of quietly dropping rows.
    ///
    /// ⚠️ SEE `fit(optionCount:extraCount:capabilities:)` — the "losing an ACTION is not acceptable"
    /// reasoning above holds only against showing everything, which the platform does not offer.
    /// `plan` stays total; the renderers now trim VISIBLY before calling it.
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
    ///
    /// Every shipped list caps at ten, so this is false everywhere today. It exists because the
    /// moment a list can grow, the renderer needs something to check other than its own judgement —
    /// and because the alternative found in the wild is a silent `prefix(_:)`.
    ///
    /// ⚠️ IT HAD TESTS AND NO PRODUCTION CALLER, which is the shape that ships a dead feature behind
    /// a green suite. `fit(optionCount:extraCount:capabilities:)` below is the caller it was missing.
    nonisolated static func exceedsCapacity(optionCount: Int, capabilities: RemoteCapabilities) -> Bool {
        optionCount > capabilities.maxButtons
    }

    /// How many options survive, and how many had to go, when the extras must be kept.
    ///
    /// ⚠️⚠️ THIS REVERSES A JUDGEMENT RECORDED ABOVE, AND THE REASON IS THAT THE OLD ONE COMPARED
    /// AGAINST THE WRONG ALTERNATIVE. `plan` is total by construction because "truncating would
    /// silently hide actions from the user while the list still looked complete — losing DECORATION
    /// is acceptable degradation, losing an ACTION is not." That weighs truncation against showing
    /// everything. But the platform is not offering that trade: Discord accepts at most 5 ActionRows
    /// and rejects the message outright above them, so the real alternative to dropping SOME actions
    /// is the message never arriving and the user losing ALL of them, along with the heading that
    /// would have explained why. Visible truncation strictly dominates that.
    ///
    /// `plan` keeps its totality — it is the right primitive, and the golden fixtures rest on it.
    /// The decision to show fewer belongs here, where it is named, counted and reported.
    ///
    /// ⚠️ THE EXTRAS ARE PRESERVED, THE OPTIONS ARE TRIMMED, and that order is the whole point.
    /// `extraActions` is where "◂ Previous", "Next ▸" and "➕ New Conversation" live — the controls
    /// that let a user reach the very rows being dropped. Trimming the list from the end and keeping
    /// navigation leaves them a route to what is missing; trimming uniformly would take the route
    /// away along with the destination.
    ///
    /// - Returns: how many of `optionCount` to render, and how many were dropped.
    nonisolated static func fit(
        optionCount: Int,
        extraCount: Int,
        capabilities: RemoteCapabilities
    ) -> (kept: Int, dropped: Int) {
        let capacity = capabilities.maxButtons
        guard optionCount + extraCount > capacity else { return (optionCount, 0) }
        // ⚠️ `max(0,)` because extras alone could in principle fill the budget. Nothing builds such
        // a chooser today; returning a negative count would be a crash rather than a bad render.
        let kept = max(0, capacity - extraCount)
        return (min(optionCount, kept), optionCount - min(optionCount, kept))
    }
}
