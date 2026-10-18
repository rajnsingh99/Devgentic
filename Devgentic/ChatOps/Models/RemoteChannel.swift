// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteChannel.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    // Why: single mapping so bridges cannot disagree; `messageSource` is the only record that a run started remotely
    /// The `MessageSource` a run started from this provider is stamped with.
    var messageSource: MessageSource {
        switch self {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        }
    }
}

extension MessageSource {
    // Why: optional on purpose: local sources have no remote channel, and a default would address the wrong platform
    /// The provider a remote-originated message came from, or nil for a local surface.
    var remoteProvider: RemoteChannel.Provider? {
        switch self {
        case .telegram: return .telegram
        case .discord:  return .discord
        case .slack:    return .slack
        case .localUI, .quickAccess, .orb, .scheduled, .backgroundTask: return nil
        }
    }
}
