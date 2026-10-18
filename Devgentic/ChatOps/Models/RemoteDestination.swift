// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteDestination.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// The address a `RemoteView` is delivered to.
enum RemoteDestination: Equatable, Sendable {

    /// Post into the channel.
    case channel(RemoteChannel)

    /// Reply into an interaction the platform is already holding open. Discord only today (it defers every interaction
    /// and edits that response); renderers that cannot honour it fall back to `.channel`, so the reply arrives as a new
    /// message.
    case interactionReply(channel: RemoteChannel, interactionToken: String)

    /// The channel every destination ultimately belongs to.
    var channel: RemoteChannel {
        switch self {
        case .channel(let channel): return channel
        case .interactionReply(let channel, _): return channel
        }
    }
}
