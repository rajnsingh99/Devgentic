// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteTurnAdmission.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: copy lives here, not in the bridges, so the platforms cannot describe one refusal differently
/// The admission decision, plus the user-facing words when it is a refusal.
/// Plain string pair so every guard in `handleFreeText` posts through `tell(_:_:whenLost:)`.
enum RemoteTurnAdmission {

    enum Decision: Equatable, Sendable {

        /// Nothing else is running here. Submit.
        case admitted

        /// A run is already streaming. `message` goes to the user; `whenLost` is the consequence
        /// logged if that message itself fails to send.
        case refused(message: String, whenLost: String)
    }

    // Why: a submitted turn with no mirror spends tokens and runs tools while the remote user sees nothing
    /// Refused because the mirror could not be attached, so no answer could be delivered.
    /// Also covers a missing transport, which would otherwise drop the prompt with no reply.
    static let mirrorUnavailable = Decision.refused(
        message: "⚠️ Could not attach this chat to the run, so its answer could not reach you. Nothing was started. Try again in a moment.",
        whenLost: "the remote user is not told their prompt was refused for want of a usable transport, so they wait for an answer to a run that was deliberately never started."
    )

    // Why: a bridge outlives the window it acts for; the coordinator retains it but not the view model
    /// Refused because the host that would run the turn is gone.
    /// Separate copy from `mirrorUnavailable`: the remedy is to reopen the app, not to retry.
    static let hostUnavailable = Decision.refused(
        message: "⚠️ Devgentic's main window is no longer available, so nothing was started. Reopen the app and try again.",
        whenLost: "the remote user is not told their prompt was refused because the app window is gone, so they wait for an answer to a run that could never have started."
    )

    /// Decides whether a remote turn is admitted. Pure, so the bridge and its tests call the same function.
    /// hasActiveRun: conversation-scoped `RemoteRunControlling.hasActiveRun(inConversation:)`, not the app-global flag.
    /// waitingOn: what the run is parked on ("your approval"), when it waits for a human rather than working.
    static func decide(hasActiveRun: Bool, waitingOn: String? = nil) -> Decision {
        guard hasActiveRun else { return .admitted }
        let message = waitingOn.map {
            "⏳ Your last message is waiting for \($0). Answer that first, or send /cancel to stop it."
        } ?? "⏳ Still working on your last message. Send /cancel to stop it, or wait for the answer."
        return .refused(
            message: message,
            whenLost: "the user is not told their prompt was refused, so they wait for an answer to a message that was never submitted — and, believing it lost, are likely to send it again."
        )
    }
}
