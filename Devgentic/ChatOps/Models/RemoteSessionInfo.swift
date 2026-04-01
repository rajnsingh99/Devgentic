//
//  RemoteSessionInfo.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
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
