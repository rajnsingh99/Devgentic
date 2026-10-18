// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordGatewayClosePolicy.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Classifies a Discord Gateway close code as fatal, reconnect, or reconnect-with-new-session.
/// The thrown error is generic (`NSPOSIXErrorDomain` 57); only the task's close code tells a rejected
/// token from a dropped connection.
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
        // Fatal: each of these is a configuration fault, and retrying only hides it behind an endless failure loop.
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

        // The session is dead but the credentials are good: drop it and identify afresh.
        // Resuming with the stale sequence is closed again immediately, a tight loop that looks transient.
        case 4007, 4009:
            return .reconnectWithNewSession

        // Retryable: 4000-4003, 4005, 4008, every 1000-range close, and 0 (no close frame, a dropped connection).
        default:
            return .reconnect
        }
    }
}
