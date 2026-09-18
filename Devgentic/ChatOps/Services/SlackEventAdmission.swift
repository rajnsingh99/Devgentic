// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackEventAdmission.swift
//  Devgentic
//
//  Deciding whether a Slack event is one this bridge has already run.
//
//  ⚠️⚠️ THE FAILURE THIS EXISTS TO STOP: ONE MESSAGE, TWO AGENT RUNS. Slack delivers a separate
//  Socket Mode envelope per matching event subscription. The standard bot recipe subscribes to BOTH
//  `app_mention` (so the bot answers when addressed) and `message.channels` (so the bridge sees plain
//  text in the paired channel) — so `@Devgentic refactor the parser` arrives TWICE, once as
//  `{"type":"app_mention"}` and once as `{"type":"message"}`. Neither copy has a `bot_id` or a
//  `subtype`, both carry the same `channel` and `text`, so `handleMessage` accepted both and
//  submitted the same prompt twice: two runs, double token spend, double tool execution.
//
//  ⚠️⚠️ WHY THIS DEDUPLICATES RATHER THAN FILTERING ON `type`, WHICH IS WHAT THE AUDIT PROPOSED.
//  A `guard event.type == "message"` closes the double-run — and silently breaks every workspace
//  that subscribed to `app_mention` ALONE, which is the other half of the standard recipe and a
//  perfectly reasonable setup: the bot would simply stop answering, with the guard's own log line
//  the only evidence. Deduplicating on the message's identity is correct for every combination:
//  both subscriptions → one run; either alone → one run.
//
//  ⚠️ `ts` IS THE IDENTITY, and it is Slack's own. It is the message's timestamp-id, unique within a
//  channel and IDENTICAL across every event that reports the same message — which is exactly the
//  property needed here. It also covers Slack's redelivery: an envelope we failed to ack inside three
//  seconds is re-sent with the same `ts`, so a slow turn can no longer run twice.
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

    /// How many message identities are remembered.
    ///
    /// ⚠️ BOUNDED BECAUSE THE BRIDGE OUTLIVES THE CONVERSATION. An unbounded set is a leak that grows
    /// for as long as the app runs. 200 is far past the window that matters: the duplicate arrives
    /// within milliseconds of its twin, and a redelivery within seconds — both while the entry is
    /// still near the newest end.
    static let memory = 200

    private var seenOrder: [String] = []
    private var seen: Set<String> = []

    init() {}

    /// Records this event's identity and says whether it has been seen before.
    ///
    /// - Parameter ts: Slack's message timestamp-id.
    ///
    ///   ⚠️ A NIL `ts` IS ADMITTED, NOT REFUSED. Every real `message`/`app_mention` carries one, so
    ///   nil means an event shape this build does not model — and refusing it would make the bot go
    ///   deaf for that shape with no way to tell from the outside. Admitting it risks a duplicate;
    ///   refusing it risks silence. The caller logs the case so it is visible either way.
    mutating func admit(type: String, channel: String, ts: String?) -> Decision {
        guard let ts, !ts.isEmpty else { return .admitUnidentified(type: type) }

        // ⚠️ Channel-scoped: Slack's `ts` is unique within a channel, not across a workspace.
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
