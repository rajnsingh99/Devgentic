// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  RemoteTurnAdmission.swift
//  Devgentic
//
//  Whether a remote free-text message may start a run, given what the conversation is already doing.
//
//  ⚠️⚠️ THE RULE IS NOT NEW AND IT IS NOT LOCAL. `RunAdmissionPolicy` states it as an owner decision
//  (2026-08-17): "at most one ROOT run per conversation. That is what makes 'the conversation is the
//  thing you stop' true by construction rather than by convention." The Mac composer enforces it —
//  `MessagingCoordinator.sendMessage` opens with `guard !chatHistoryViewModel.isSending`. The remote
//  path had no equivalent: `submitRemoteMessage` reads neither `isSending` nor `hasActiveRun`, and
//  none of the three `handleFreeText` implementations checked either. A second message sent while
//  the agent was still streaming started a SECOND root run in the same conversation.
//
//  ⚠️ WHAT THAT ACTUALLY COSTS, because "two runs" understates it. Both runs are observed by the
//  same sticky `RemoteMirrorService` session, so both stream their answers into the one chat with
//  nothing saying which prompt each belongs to. `/cancel` calls `cancelRun(inConversation:)`, which
//  is conversation-wide and returns a single Bool — so it silently kills both and reports one. And
//  `pendingClarificationOperationID` takes the OLDEST pending item in the conversation, so a typed
//  clarification answer can resolve the wrong run's question.
//
//  ⚠️ REFUSE, NOT QUEUE — and the choice is deliberate. A queue needs an ordering, an expiry, a
//  cancellation rule and somewhere durable to live, and it would let a message sent five minutes ago
//  execute against a conversation the user has since redirected. Refusing is honest, immediate, and
//  leaves the user holding the decision with `/cancel` one word away. Queueing stays available
//  later; the increment-4 note on `RunAdmissionPolicy` is where it would land.
//
//  ⚠️ THIS CANNOT BLOCK A CLARIFICATION ANSWER, which is the one case that would make it a
//  regression rather than a fix. All three bridges parse with `awaitingClarification:
//  commands?.isAwaitingClarification`, which is derived from the InteractionCenter, so a reply to a
//  parked question returns `.clarificationResponse` and never reaches `handleFreeText` at all.
//

import Foundation

/// The decision, plus the words to say when it is a refusal.
///
/// ⚠️ THE COPY LIVES HERE RATHER THAN IN THE BRIDGES so three platforms cannot describe one refusal
/// three ways — the same reason `RemoteSilence`, `RemoteRenderLog` and `PairingWindowExpiry` are
/// shared. It is a plain string pair rather than a `RemoteView` because every other guard in
/// `handleFreeText` posts through `tell(_:_:whenLost:)`, and matching them keeps the call site one
/// line.
enum RemoteTurnAdmission {

    enum Decision: Equatable, Sendable {

        /// Nothing else is running here. Submit.
        case admitted

        /// A run is already streaming. `message` goes to the user; `whenLost` is the consequence
        /// logged if that message itself fails to send.
        case refused(message: String, whenLost: String)
    }

    /// Refused because the mirror could not be attached, so nothing would come back.
    ///
    /// ⚠️⚠️ [NEW-4] A SUBMITTED TURN WITH NO MIRROR IS WORSE THAN A REFUSED ONE. The run executes on
    /// the Mac — spending tokens, and at `.full` running TOOLS — while the remote user watches a chat
    /// that never answers. `submitTurn`'s doc comment called the mirror registration unconditional,
    /// but every bridge supplied it as a fully optional-chained closure
    /// (`self?.remoteMirrorService?.registerSession(...)`), so either link being nil made it a no-op
    /// that returned Void and told nobody. Refusing is the honest outcome: the user learns, and no
    /// tokens are spent on an answer that cannot be delivered.
    ///
    /// ⚠️ [NEW-3] It also subsumes the transport guard. Discord and Slack opened `handleFreeText`
    /// with a bare `guard let transport = ... else { return }` placed BEFORE the admission call, so a
    /// nil transport dropped the prompt with no log, no reply, and no admission decision at all —
    /// while every other drop in those same two methods names its consequence to the user.
    static let mirrorUnavailable = Decision.refused(
        message: "⚠️ Could not attach this chat to the run, so its answer could not reach you. Nothing was started. Try again in a moment.",
        whenLost: "the remote user is not told their prompt was refused for want of a usable transport, so they wait for an answer to a run that was deliberately never started."
    )

    /// Refused because the host that would run the turn is gone.
    ///
    /// ⚠️ [LIFE-7] A bridge outlives the window it acts for — it is retained by the coordinator, the
    /// view model is not. Distinct copy from `mirrorUnavailable` because the remedy differs: that one
    /// is "try again in a moment", this one is "reopen the app".
    static let hostUnavailable = Decision.refused(
        message: "⚠️ Devgentic's main window is no longer available, so nothing was started. Reopen the app and try again.",
        whenLost: "the remote user is not told their prompt was refused because the app window is gone, so they wait for an answer to a run that could never have started."
    )

    /// ⚠️ PURE AND TOTAL, so the rule can be asserted without a view model, an actor hop or a live
    /// socket — and so the production path and the test cannot drift, because the bridge calls this
    /// exact function.
    ///
    /// - Parameter hasActiveRun: `RemoteRunControlling.hasActiveRun(inConversation:)`, which is
    ///   conversation-scoped. ⚠️ NOT the app-global `streamingMessageID`: that reports "busy"
    ///   whenever ANY conversation is streaming, so using it here would refuse a remote user's very
    ///   first message because the local user happened to be running something else.
    /// - Parameter waitingOn: what the run is parked on ("your approval", …), when it is waiting for a
    ///   human rather than working. ⚠️ D-23: "still working" was false then — nothing moves until
    ///   the operator answers, and they were not told there was anything to answer.
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
