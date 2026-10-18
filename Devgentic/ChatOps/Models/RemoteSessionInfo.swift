// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteSessionInfo.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Metadata for an active remote ChatOps session.
///
/// When a conversation is being driven from a remote transport (e.g., Telegram),
/// this struct is stored in `RemoteMirrorService` so it knows where to send
/// mirrored events (responses, HITL prompts, completion status).
struct RemoteSessionInfo: Sendable {
    let transport: ChatOpsTransport
    let chatID: String
    let source: MessageSource
}
