// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteChannel.swift
//  Devgentic
//
//  Where a remote view is going — C2 of the ChatOps remote-interface plan.
//
//  WHY THIS EXISTS. The three bridges disagree about what a channel even IS: the Telegram handlers
//  take `chatID: Int64`, Discord and Slack take `channelID: String`. That difference is the reason
//  no handler signature can be shared, and it is not a real difference — `ChatOpsTransport` already
//  settled the question by making every id a `String`, precisely so Slack channel ids like
//  `"C0123456789"` and ts values like `"1716307200.123456"` fit.
//
//  ⚠️ `TelegramTransport` force-unwraps its way back (`Int64(chatID)!` at :33, :37, :45 and
//  `Int(messageID)!` at :146). That is safe today only because the sole producer builds the string
//  from an `Int64` in the first place. Anything that starts minting Telegram channel ids from
//  another source must fix those unwraps first — a non-numeric id crashes the app rather than
//  throwing.
//

import Foundation

/// One remote conversation surface: a Telegram chat, a Discord channel, or a Slack channel.
struct RemoteChannel: Hashable, Sendable, Codable {

    enum Provider: String, Hashable, Sendable, Codable, CaseIterable {
        case telegram
        case discord
        case slack
    }

    let provider: Provider

    /// String for every provider, matching `ChatOpsTransport`'s id contract. For Telegram this is
    /// the decimal form of the chat's `Int64`.
    let channelID: String

    init(provider: Provider, channelID: String) {
        self.provider = provider
        self.channelID = channelID
    }

    /// Telegram convenience, so a call site never hand-rolls the conversion the transport will
    /// have to undo.
    init(telegramChatID: Int64) {
        self.init(provider: .telegram, channelID: String(telegramChatID))
    }
}

extension RemoteChannel.Provider {

    /// The `MessageSource` a run started from this provider is stamped with.
    ///
    /// ⚠️ ONE mapping, here. Today each bridge passes its own literal (`.telegram` / `.discord` /
    /// `.slack`) at its own `submitRemoteMessage` call site, which is three places that must agree
    /// and no way to notice when they stop. `messageSource` is the only record that a run was
    /// started remotely rather than typed.
    var messageSource: MessageSource {
        switch self {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        }
    }
}

extension MessageSource {
    /// The provider a remote-originated message came from, or nil for a local surface.
    ///
    /// ⚠️ `RemoteSessionInfo` stores a `MessageSource` rather than a provider, so the mirror needs
    /// this to address a channel. Deliberately optional: `.localUI`, `.quickAccess`, `.jarvis` and
    /// `.scheduled` are real sources with no remote channel, and forcing them to a default would
    /// silently address the wrong platform.
    var remoteProvider: RemoteChannel.Provider? {
        switch self {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        case .localUI, .quickAccess, .jarvis, .scheduled: return nil
        }
    }
}
