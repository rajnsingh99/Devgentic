// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackEventAdmission.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Whether a Slack event should be handled, and why not when it should not.
struct SlackEventAdmission {

    enum Decision: Equatable {
        /// Handle it. Carries the identity now recorded as seen.
        case admit(key: String)
        /// The same message already ran. Carries the identity and the event type that repeated it.
        case duplicate(key: String, type: String)
        /// No `ts`, so this event cannot be identified. Handled anyway — see `admit(type:channel:ts:)`.
        case admitUnidentified(type: String)
    }

    /// How many message identities are remembered. Bounded because the bridge outlives the conversation; 200 is far
    /// past the window in which a duplicate or redelivery arrives.
    static let memory = 200

    private var seenOrder: [String] = []
    private var seen: Set<String> = []

    init() {}

    /// Records this event's identity and says whether it has been seen before. `ts` is Slack's message timestamp id; a
    /// nil `ts` is admitted rather than refused, since refusing an unmodelled event shape would make the bot silently
    /// deaf to it.
    mutating func admit(type: String, channel: String, ts: String?) -> Decision {
        guard let ts, !ts.isEmpty else { return .admitUnidentified(type: type) }

        // Channel-scoped: Slack's `ts` is unique within a channel, not across a workspace.
        let key = "\(channel):\(ts)"
        guard !seen.contains(key) else { return .duplicate(key: key, type: type) }

        seen.insert(key)
        seenOrder.append(key)
        if seenOrder.count > Self.memory {
            let evicted = seenOrder.removeFirst()
            seen.remove(evicted)
        }
        return .admit(key: key)
    }
}
