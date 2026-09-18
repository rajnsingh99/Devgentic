// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteDestination.swift
//  Devgentic
//
//  Where a rendered view is posted — C3 of the ChatOps remote-interface plan.
//
//  ⚠️ THIS TYPE IS WHAT KILLS THE `/conversations` DIVERGENCE. Discord renders that command two
//  different ways today: arriving as a channel message it posts a button grid
//  (`DiscordChatOpsBridge.handleConversations`), arriving as a registered slash command it posts a
//  numbered plain-text list with no buttons (`conversationListText`). Two renderings of one command,
//  because "reply into the interaction" was implemented as a SECOND CODE PATH rather than as a
//  different address for the same one.
//
//  Making the reply channel a VALUE means the slash-command arm renders the identical `RemoteView`
//  to a different destination. There is nothing left to diverge.
//

import Foundation

/// The address a `RemoteView` is delivered to.
enum RemoteDestination: Equatable, Sendable {

    /// Post into the channel.
    case channel(RemoteChannel)

    /// Reply into an interaction the platform is already holding open.
    ///
    /// ⚠️ DISCORD ONLY, TODAY. Discord defers every interaction within its 3-second deadline and
    /// then edits that deferred response — the token plumbing already exists
    /// (`DiscordAPIClient.editInteractionResponse`). Slack has the same shape available through
    /// `response_url`, which is decoded on both interactive and slash payloads
    /// (`SlackModels.swift:89`, `:111`) and read nowhere; Telegram has no equivalent at all.
    /// Renderers that cannot honour it fall back to `.channel` rather than failing — the reply
    /// still reaches the user, it just arrives as a new message.
    case interactionReply(channel: RemoteChannel, interactionToken: String)

    /// The channel every destination ultimately belongs to.
    var channel: RemoteChannel {
        switch self {
        case .channel(let channel): return channel
        case .interactionReply(let channel, _): return channel
        }
    }
}
