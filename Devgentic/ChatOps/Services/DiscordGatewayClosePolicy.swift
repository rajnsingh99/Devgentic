// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordGatewayClosePolicy.swift
//  Devgentic
//
//  What a Discord Gateway close code means for reconnection.
//
//  WHY THIS EXISTS. `DiscordGatewayClient.connectAndListen` caught every error and reconnected with
//  backoff, forever. Discord closes the socket with a code that says WHY, and several of those
//  reasons cannot be fixed by reconnecting: a rejected bot token (4004) and a privileged intent that
//  was never enabled in the Developer Portal (4014) are configuration facts, not transient faults.
//  The bridge retried them every 60s indefinitely, and the user was never told what was wrong —
//  Discord simply never worked.
//
//  ⚠️ THE THROWN ERROR CANNOT TELL YOU ANY OF THIS. A server-side close surfaces from
//  `URLSessionWebSocketTask.receive()` as a generic `NSPOSIXErrorDomain` code 57 ("Socket is not
//  connected") — identical whether the token was rejected or the Wi-Fi dropped. The close CODE is
//  the only thing that separates them, and it lives on the TASK, not on the error.
//
//  ⚠️ AND THE CODE DOES SURVIVE, WHICH IS NOT OBVIOUS. `NSURLSessionWebSocketCloseCode` is a closed
//  `NS_ENUM` whose largest case is 1015, so a reader would reasonably assume Discord's 4000-range
//  codes are lost in the bridge to Swift. They are not: measured against a server that closes with
//  4004, `task.closeCode.rawValue` reports 4004 and `task.closeReason` carries the server's text.
//  This was verified before the policy was written, because the whole fix depends on it.
//
//  Codes per Discord's Gateway documentation (opcodes and status codes, v10).
//

import Foundation

enum DiscordGatewayClosePolicy {

    enum Disposition: Equatable {
        /// Transient. Reconnect with backoff, resuming the session if one exists.
        case reconnect

        /// The SESSION is unusable but the credentials are fine. Reconnect, but discard the
        /// session id, sequence and resume URL first — resuming with them would be rejected again.
        case reconnectWithNewSession

        /// Reconnecting cannot fix this. Stop, and say why in words the user can act on.
        case fatal(reason: String)
    }

    /// - Parameter code: `URLSessionWebSocketTask.closeCode.rawValue`. Zero means the socket failed
    ///   without a server close frame (a dropped network), which is transient by definition.
    static func disposition(forCloseCode code: Int) -> Disposition {
        switch code {
        // ⚠️ FATAL. Every one of these is a configuration fact. Retrying is not merely useless, it
        // hides the problem behind an infinite loop of identical failures.
        case 4004:
            return .fatal(reason: "Discord rejected the bot token. Check the token in ChatOps settings — it is wrong, was revoked, or was regenerated in the Developer Portal.")
        case 4010:
            return .fatal(reason: "Discord rejected the shard this connection identified with. This build does not shard, so this indicates a malformed IDENTIFY rather than anything the user configured.")
        case 4011:
            return .fatal(reason: "This bot is in too many guilds for a single Gateway connection and now requires sharding, which this build does not implement.")
        case 4012:
            return .fatal(reason: "Discord no longer supports the Gateway API version this build requests. The app needs updating; reconnecting will not help.")
        case 4013:
            return .fatal(reason: "One of the Gateway intents this build requests is invalid. Reconnecting cannot fix a malformed intent set.")
        case 4014:
            return .fatal(reason: "A privileged Gateway intent is not enabled for this bot. Open the Discord Developer Portal → your application → Bot → Privileged Gateway Intents and enable Message Content Intent, then restart ChatOps.")

        // The session is dead but the credentials are good — drop it and identify afresh.
        // ⚠️ Reconnecting WITHOUT clearing the session state sends a RESUME carrying the same
        // rejected sequence, which is closed again immediately: a tight loop that looks transient.
        case 4007, 4009:
            return .reconnectWithNewSession

        // 4000 unknown error, 4001 unknown opcode, 4002 decode error, 4003 not authenticated,
        // 4005 already authenticated, 4008 rate limited, every 1000-range close, and 0 (no close
        // frame at all — a dropped connection) are all genuinely retryable.
        default:
            return .reconnect
        }
    }
}
