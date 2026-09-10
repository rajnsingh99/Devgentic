// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  RemoteMirrorService.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import os

/// Mirrors agent stream events to remote ChatOps transports.
///
/// When a message originates from a remote source (Telegram, Discord, etc.),
/// this service observes the resulting `ChatMessage` stream and mirrors
/// events (responses, HITL prompts, completion) back to the transport.
///
/// **Architecture**: The main app is the source of truth. This service is
/// a lightweight observer — it never drives execution, only mirrors output.
@MainActor
final class RemoteMirrorService: ActiveStreamMirrorDelegate {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "RemoteMirrorService")

    // MARK: - State

    /// Active remote sessions keyed by conversationID.
    private var remoteSessions: [UUID: RemoteSessionInfo] = [:]

    /// Tracks which HITL operationIDs have been mirrored to transport (prevents duplicates).
    private var mirroredOperations: Set<UUID> = []

    /// Maps operationID → transport message_id (for editing HITL messages after resolution).
    private var hitlMessageIDs: [UUID: String] = [:]

    /// Messages currently being observed via withObservationTracking.
    private var observedMessageIDs: Set<UUID> = []

    /// Reference to ActiveStreamManager (set as delegate).
    private weak var activeStreamManager: ActiveStreamManager?

    /// Observers for HITL resolution notifications.
    private var permissionResolvedObserver: NSObjectProtocol?
    private var clarificationResolvedObserver: NSObjectProtocol?
    private var planReviewResolvedObserver: NSObjectProtocol?
    private var gateResolvedObserver: NSObjectProtocol?

    // MARK: - Init

    init(activeStreamManager: ActiveStreamManager) {
        self.activeStreamManager = activeStreamManager
        activeStreamManager.addMirrorDelegate(self)   // [D2] multicast — all active transports mirror
        setupHITLResolvedObservers()
    }

    deinit {
        if let obs = permissionResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clarificationResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = planReviewResolvedObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = gateResolvedObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - ActiveStreamMirrorDelegate

    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage, for conversationID: UUID) {
        guard remoteSessions[conversationID] != nil else { return }
        guard !observedMessageIDs.contains(message.id) else { return }
        observeMessage(message)
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        observedMessageIDs.remove(message.id)
        // [HITL/P5] Drop the final-response send-once key so the dedup Set doesn't grow unbounded.
        mirroredOperations.remove(message.id)
    }

    // MARK: - Session Registration

    /// Register a remote session for a conversation. Called when a remote message is submitted.
    func registerSession(conversationID: UUID, info: RemoteSessionInfo) {
        remoteSessions[conversationID] = info
        logger.info("[Mirror] Registered remote session for conversation \(conversationID) via \(info.source.rawValue).")
    }

    /// Unregister a remote session. Called on disconnect or explicit cleanup.
    /// Whether a conversation is bound to this provider's channel.
    ///
    /// ⚠️ [Slice 3] The double-post guard: `ChatOpsNotificationChannel` stays quiet for a
    /// conversation the mirror is already streaming, so a run started from chat is reported once
    /// rather than twice.
    func isMirroring(_ conversationID: UUID) -> Bool {
        remoteSessions[conversationID] != nil
    }

    func unregisterSession(conversationID: UUID) {
        remoteSessions.removeValue(forKey: conversationID)
        logger.info("[Mirror] Unregistered remote session for conversation \(conversationID).")
    }

    /// [D2] Detaches this service when its owning transport stops: removes it from the stream manager's
    /// multicast and drops all sessions, so a stopped transport no longer mirrors Mac-UI activity back
    /// out (the bridge then nils its strong ref, letting the service deallocate). Without this, a stopped
    /// transport with a lingering session kept pushing responses to the remote chat.
    func teardown() {
        activeStreamManager?.removeMirrorDelegate(self)
        remoteSessions.removeAll()
        logger.info("[Mirror] Torn down — detached from stream manager, sessions cleared.")
    }

    // MARK: - HITL Response Routing (Transport → Agent)

    /// Which parked operation a remote message id belongs to, if any.
    ///
    /// ⚠️ THE INVERSE OF `hitlMessageIDs`, AND THE POINT OF SLICE 4. Correlation was previously
    /// derived from the provider's single conversation cursor and then resolved to the OLDEST
    /// pending clarification in it, so: two clarifications parked at once were unanswerable (the
    /// second always resolved the first), a `/new` or a `switch:` between prompt and answer sent
    /// the reply to the agent as a fresh run instead, and a prompt for a conversation the cursor
    /// had moved off could not be answered at all. A reply names its message, and this names the
    /// operation — no cursor, no ordering, no mode.
    ///
    /// ⚠️ A linear scan, deliberately. `hitlMessageIDs` holds only the prompts currently parked on
    /// this one channel — single digits — and a second dictionary kept in the other direction is a
    /// second thing to keep in lockstep with the four sites that already clear this one.
    func operationID(forRemoteMessageID messageID: String) -> UUID? {
        hitlMessageIDs.first { $0.value == messageID }?.key
    }

    /// The provider to record as having answered a prompt this service is resolving.
    ///
    /// ⚠️ DERIVED, not assumed. One `RemoteMirrorService` is constructed per bridge (Telegram,
    /// Discord and Slack each build their own), so every session it holds shares one provider —
    /// but the resolution notification is global, so the ONLY thing that makes a resolution "ours"
    /// is that the operation belongs to a conversation this service has a session for.
    private func resolutionSource(for operationID: UUID) -> MessageSource? {
        if let convID = activeStreamManager?.interactionCenter?.item(withID: operationID)?.origin.conversationID,
           let session = remoteSessions[convID] {
            return session.source
        }
        // The item can already be gone from the InteractionCenter by the time a resolution lands.
        // Every session here belongs to this service's own bridge, so any of them names the right
        // provider; nil only when this service has no sessions at all and therefore no claim.
        return remoteSessions.values.first?.source
    }

    /// Called when a remote transport receives an approve/deny button tap. [D1] KIND-AWARE: the same
    /// approve/deny affordance can resolve a tool confirmation OR a plan review (each parks in a
    /// different continuation), so dispatch by the pending HITL's kind. Without this, a remote approve
    /// of a plan review hit the (empty) permission continuation and the agent stayed parked forever.
    func handleApproval(operationID: UUID, approved: Bool) async {
        let kind = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind
        let source = resolutionSource(for: operationID)
        switch kind {
        case .planReview(let p):
            await ExecutionSuspensionService.shared.resumePlanReview(for: operationID, editedPlan: approved ? p.subtasks : nil, resolvedBy: source)
        case .gate:
            // Gates resolve only via their per-option buttons (handleGate), never a bare approve/deny.
            // If one somehow arrives here, do NOT guess an option (picking options.first could route to a
            // destructive branch for orderings like ["Reject","Approve"]) — log and leave it.
            logger.warning("[Mirror] Ignoring approve/deny for gate \(operationID) — gates resolve via option buttons.")
        case .toolConfirmation, .clarification, .none:
            await ExecutionSuspensionService.shared.resume(for: operationID, approved: approved, resolvedBy: source)
        }
    }

    /// Called when a remote transport receives a clarification response.
    func handleClarification(operationID: UUID, text: String) async {
        let response: String? = text.isEmpty ? nil : text
        let source = resolutionSource(for: operationID)
        await ExecutionSuspensionService.shared.resumeClarification(for: operationID, userInput: response, resolvedBy: source)
    }

    // (handlePlanReview removed — D1's kind-aware `handleApproval` now routes a remote plan-review
    // approve/reject straight to resumePlanReview; this duplicate had no callers. H1 cleanup.)

    /// [D1] Called when a remote transport receives a workflow Gate option tap. Maps the button's option
    /// INDEX back to its label (via the InteractionCenter) and resolves the gate, matching the Mac UI's
    /// `resumeGate(chosenOption:)`. A stale/unknown index cancels the gate (nil) rather than leaving it parked.
    func handleGate(operationID: UUID, optionIndex: Int) async {
        let source = resolutionSource(for: operationID)
        guard case .gate(let g)? = activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind,
              g.options.indices.contains(optionIndex) else {
            // ⚠️ CANCELLING IS THE RIGHT CALL — leaving the gate parked forever is worse — but it is
            // a DECISION THE USER DID NOT MAKE, taken because the button they tapped no longer
            // matches the options in flight. It happened with no log at all.
            logger.error("[CHATOPS] A remote gate tap for operation \(operationID) named option index \(optionIndex), which no longer matches a live gate. CONSEQUENCE: the gate is resolved as CANCELLED rather than with the option the user tapped — a workflow may take its error branch — because the button outlived the options it was posted for.")
            await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: nil, resolvedBy: source)
            return
        }
        await ExecutionSuspensionService.shared.resumeGate(for: operationID, chosenOption: g.options[optionIndex], resolvedBy: source)
    }

    // MARK: - Message Observation

    /// Observe a ChatMessage using withObservationTracking and mirror relevant events.
    private func observeMessage(_ message: ChatMessage) {
        let messageID = message.id
        let conversationID = message.conversationId
        observedMessageIDs.insert(messageID)

        func observe() {
            withObservationTracking {
                // [HITL/P5] Track the unified InteractionCenter queue (single source of truth)
                // instead of the retired per-message pendingInteraction container.
                _ = self.activeStreamManager?.interactionCenter?.pending
                _ = message.isStreaming
                _ = message.agentState
                _ = message.content
            } onChange: {
                Task { @MainActor [weak self, weak message] in
                    guard let self, let message else { return }
                    guard self.observedMessageIDs.contains(messageID) else { return }
                    // [HITL/P5] Re-arm tracking BEFORE the async mirror send so a HITL enqueued
                    // during the send window (e.g. a second parallel workflow node parking for input)
                    // is still observed — withObservationTracking is one-shot, and the dedup in
                    // evaluateMessageState makes the extra pass harmless.
                    self.observeMessage(message)
                    await self.evaluateMessageState(message, conversationID: conversationID)
                }
            }
        }
        observe()

        logger.info("[Mirror] Started observing message \(messageID) for conversation \(conversationID).")
    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // [HITL/P5] Mirror HITL request(s) from the unified InteractionCenter (single source of
        // truth). A workflow run can have several nodes awaiting at once, so mirror every
        // un-mirrored item — this also makes WORKFLOW HITL remotely actionable for the first time
        // (the legacy per-message container never carried workflow requests).
        let pendingHITLs = activeStreamManager?.interactionCenter?.items(for: conversationID) ?? []
        for pending in pendingHITLs where !mirroredOperations.contains(pending.id) {
            let hitlType: HITLType
            switch pending.kind {
            case .toolConfirmation(let c):
                hitlType = .toolConfirmation(toolName: c.toolName, params: c.params)
            case .clarification(let c):
                // A5: the remote channel is free-text, so append the suggested options to the prompt
                // body (the model's choices are otherwise invisible on Slack/Discord/Telegram).
                let question = (c.options?.isEmpty == false)
                    ? c.question + "\n\nReply with one of: " + (c.options ?? []).joined(separator: " / ")
                    : c.question
                hitlType = .clarification(question: question)
            case .planReview(let p):
                hitlType = .planReview(subtaskDescriptions: p.subtasks.map(\.description))
            case .gate(let g):
                // [D1] Real gate prompt — the transport renders one tappable button per option, and a
                // tap routes back through `hitl:gate:<opID>:<idx>` → resumeGate.
                //
                // ⚠️ A Router's ambiguity arbitration carries the text being routed in `inputText`,
                // not in the prompt, because the highlight spans are measured against that exact
                // string. Slack/Discord/Telegram cannot render coloured spans, so the input is folded
                // into the prompt text here — without this the remote reader sees "2 rules match
                // this input — which branch?" with no way to know what the input was.
                let remotePrompt: String = {
                    guard let input = g.inputText, !input.isEmpty else { return g.prompt }
                    return "\(g.prompt)\n\n\(input)"
                }()
                hitlType = .gate(prompt: remotePrompt, options: g.options)
            }

            do {
                // [C8.5] One render path for everything a channel is shown. The transport returns
                // the posted message id, which is what lets a resolved prompt be edited in place.
                guard let provider = session.source.remoteProvider else {
                    logger.error("[Mirror] A remote session carries source \(session.source.rawValue), which is not a remote provider — the HITL prompt was NOT sent. CONSEQUENCE: the run stays parked with no prompt visible anywhere remote, and only the Mac banner can answer it.")
                    continue
                }
                // [C8.5] One render path for everything a channel is shown. The transport returns
                // the posted message id, which is what lets a resolved prompt be edited in place.
                // ⚠️ CLAIMED IMMEDIATELY BEFORE THE AWAIT, released in the `catch` below — the same
                // shape as the final-response send. This used to insert AFTER a successful send,
                // which self-healed on failure but left the opposite hole: because `observeMessage`
                // re-arms tracking before awaiting this method, a second overlapping pass could
                // clear the `where` clause above while the first was still suspended inside
                // `render`, and post the SAME prompt twice — two sets of live buttons for one
                // operation, where tapping the stale set answers something already resolved.
                mirroredOperations.insert(pending.id)
                let msgID = try await session.transport.render(
                    .prompt(operationID: pending.id, kind: hitlType),
                    to: .channel(RemoteChannel(provider: provider, channelID: session.chatID))
                )
                if let msgID {
                    hitlMessageIDs[pending.id] = msgID
                } else {
                    logger.error("[Mirror] The transport posted the HITL prompt for operation \(pending.id) but returned no message id. CONSEQUENCE: the prompt cannot be edited when it resolves, so its buttons stay live and the remote user can tap a decision that has already been made.")
                }
                logger.info("[Mirror] Sent HITL prompt to \(session.source.rawValue) for operation \(pending.id).")
            } catch {
                // Release the claim: the prompt was NOT posted, so the next pass must try again.
                mirroredOperations.remove(pending.id)
                logger.error("[Mirror] Failed to send HITL prompt for operation \(pending.id) to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the run stays parked with no prompt visible remotely; the claim is released so the next observation pass re-sends it, and only the Mac banner can answer it until then.")
            }
        }

        // Mirror final response (stream complete)
        if !message.isStreaming && message.agentState == .idle && message.sender == .agent {
            let responseKey = message.id

            // ⚠️ NO `default:` ARM, DELIBERATELY. This switch used to end in
            // `default: responseText = "Response complete."`, and that is how a FAILED run came to
            // be reported to the remote user as a success: `MessageContent.error` fell into the
            // default and the remote chat was told "Response complete." — on the one surface where
            // the user cannot see the error card the Mac shows, and with no other signal that the
            // answer was never coming. Naming every case means a `MessageContent` case added later
            // fails to COMPILE here instead of silently inheriting a success message.
            let responseText: String
            switch message.content {
            case .plainText(let text), .markdownText(let text):
                responseText = text

            case .codeBlock(_, let code):
                responseText = code

            case .error(let title, let details, let category, let suggestion):
                // ⚠️ SANITISED, because this is a NEW EGRESS. Before this fix the error text never
                // left the process — the remote user received the fixed string "Response complete."
                // Error details are the content most likely to carry an absolute home path, an HTTP
                // error body or an env dump, and they are now handed to a third-party chat service.
                // `TelemetrySanitizer.sanitize` defaults to `.standard` (home paths, IPs, emails,
                // API keys, bearer tokens, URL credentials, JSON secrets, env assignments) and is
                // documented to over-redact rather than under-redact, which is the right trade for
                // an outbound path.
                //
                // ⚠️ NORMAL RESPONSES ARE STILL SENT UNSANITISED. That is the whole outbound
                // surface and belongs to the planned per-provider egress pass, not to this fix —
                // do not read this call as coverage of it.
                let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                var lines = ["⚠️ " + TelemetrySanitizer.sanitize(
                    (heading?.isEmpty == false ? heading! : "The run failed")
                )]
                let body = TelemetrySanitizer.sanitize(details)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { lines.append(body) }
                if let suggestion,
                   !suggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lines.append("Suggestion: " + TelemetrySanitizer.sanitize(suggestion))
                }
                responseText = lines.joined(separator: "\n\n")
                logger.error("[Mirror] Mirroring a FAILED run to \(session.source.rawValue) for conversation \(conversationID) — category \(category?.rawValue ?? "unspecified"). CONSEQUENCE: the remote user is now told the run failed and why; before this they were told \"Response complete.\" and had no way to learn the answer was never coming.")

            case .mediaArtifact(let artifact):
                // ⚠️ The artifact itself cannot be sent: `ChatOpsTransport` has no attachment API.
                // Describing it is honest; "Response complete." implied there was a reply to read.
                let label = artifact.label?.trimmingCharacters(in: .whitespacesAndNewlines)
                let what = (label?.isEmpty == false) ? label! : artifact.kind.rawValue
                responseText = "🖼 The agent produced \(what). It can only be viewed on the Mac — this channel cannot carry attachments."
                logger.info("[Mirror] A media artifact was produced for conversation \(conversationID); a description was mirrored to \(session.source.rawValue). CONSEQUENCE: the remote user is told what exists but cannot see it, because no transport implements attachments.")

            case .checkpoint:
                // A compaction checkpoint is internal bookkeeping, never an answer to anything.
                // ⚠️ Believed unreachable here — observation begins at `didStartStream`, and
                // checkpoints are written by `HistoryCompactionService` outside any stream — but it
                // is named rather than defaulted so it cannot become a spurious remote message.
                responseText = ""
                logger.info("[Mirror] A compaction checkpoint reached the mirror for conversation \(conversationID) and was NOT sent. CONSEQUENCE: nothing is posted remotely, which is correct — a checkpoint is not a reply. If this line ever appears, the reachability note beside it is wrong.")

            case .unknown(let type, _):
                // Readable JSON this build cannot model — see `MessageContent.unknown`.
                responseText = "The agent replied with content this version of Devgentic cannot display (\(type))."
                logger.error("[Mirror] Unmodellable content of type \(type) reached the mirror for conversation \(conversationID). CONSEQUENCE: the remote user is told the reply cannot be shown rather than being told the run completed normally.")
            }

            // ⚠️ EMPTINESS IS CHECKED BEFORE THE CLAIM, and it used to be checked after. `content`
            // is one of the properties this service observes, so a claim made for a message that
            // had nothing to say would suppress the body that arrived a moment later.
            guard !responseText.isEmpty else { return }

            // ⚠️ CLAIM BEFORE THE SEND, RELEASE IF THE SEND FAILS. Both halves are load-bearing and
            // they pull in opposite directions, which is why this is written out:
            //
            //   - The claim must happen BEFORE the `await`. `observeMessage` deliberately re-arms
            //     tracking BEFORE awaiting this method ("the dedup in evaluateMessageState makes
            //     the extra pass harmless"), so two passes for the same message really do overlap.
            //     On a `@MainActor` class, a check and an insert with no `await` between them are
            //     atomic — that is the only thing stopping both passes from posting the response.
            //   - The claim must be RELEASED when the send throws. It used to be permanent: a
            //     transport failure left the key set with nothing delivered, so the agent's answer
            //     was dropped AND every later pass was suppressed by a claim for a send that never
            //     happened. Marking work as done before it is done is a lie the retry path believes.
            guard !mirroredOperations.contains(responseKey) else { return }
            mirroredOperations.insert(responseKey)

            do {
                try await session.transport.sendChunkedMessage(chatID: session.chatID, text: responseText)
                logger.info("[Mirror] Sent full response to \(session.source.rawValue) for conversation \(conversationID).")
            } catch {
                mirroredOperations.remove(responseKey)
                logger.error("[Mirror] Failed to send response for conversation \(conversationID) to \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the agent's answer has NOT reached the remote chat. The send-once claim is released so the next observation pass retries — but if the stream has already ended no further pass occurs, and the answer is lost to the remote user with only this line to say so.")
            }
        }
    }

    // MARK: - Cross-Surface HITL Resolution

    /// Rewrites a resolved HITL prompt in place, and says so when it cannot.
    ///
    /// ⚠️⚠️ THIS EDIT IS WHAT REMOVES THE BUTTONS, which is why a swallowed failure here is not
    /// cosmetic. Every transport clears the approve/deny/gate controls only via a SUCCESSFUL edit
    /// (`components: []` on Discord, `blocks: []` on Slack). All four observers wrote
    /// `try? await session.transport.editMessage(...)` and then deleted `hitlMessageIDs[operationID]`
    /// on the very next line — so a failed edit left LIVE buttons on a decision already made, with
    /// the correlation id needed to repair the message thrown away in the same breath.
    ///
    /// ⚠️ AND THE SECOND TAP GOES NOWHERE, SILENTLY. The bridge acks the callback (the spinner
    /// clears, no text appears), `handleApproval` finds no InteractionCenter item, and
    /// `ExecutionSuspensionService` logs only "Attempted to resume non-existent suspension" — a line
    /// that names neither the chat nor the reason. The remote user taps a live-looking prompt and
    /// watches nothing happen, for as long as the message exists.
    ///
    /// - Parameter kind: which prompt this was, so the log names what stayed tappable.
    ///   ⚠️ REQUIRED, NOT DEFAULTED: four call sites, and a default would let a new one inherit the
    ///   wrong noun and describe the wrong stuck buttons.
    private func editResolvedPrompt(
        _ session: RemoteSessionInfo,
        messageID: String,
        to statusText: String,
        operationID: UUID,
        kind: String
    ) async {
        do {
            try await session.transport.editMessage(
                chatID: session.chatID,
                messageID: messageID,
                newText: statusText
            )
        } catch {
            logger.error("[Mirror] Failed to rewrite the resolved \(kind) prompt for operation \(operationID) on \(session.source.rawValue): \(error.localizedDescription). CONSEQUENCE: the remote message still shows its \(kind) buttons for a decision that has ALREADY been made. Tapping one now does nothing at all — the bridge acks it, no pending item matches, and the user gets no reply on any surface. The message id is dropped immediately after this call, so no later pass can repair it; the prompt misrepresents the run until the user scrolls past it.")
        }
    }


    /// How the remote copy names whoever answered a prompt.
    ///
    /// ⚠️ THIS REPLACES A HARD-CODED "(from Mac)". The observers below fire on a GLOBAL
    /// notification, so they ran for every resolution regardless of where it happened — and told a
    /// Telegram user that the button they had just tapped on Telegram was answered on the Mac. With
    /// several bridges connected it was wronger still: a Telegram approval was reported on Discord
    /// as "(from Mac)" too.
    ///
    /// ⚠️ AN ABSENT SOURCE PRINTS NOTHING. No human answered — a deadline or a force-cancel — and
    /// naming a surface there is the same lie in a new place.
    ///
    /// Proper nouns, deliberately not localized — the same call `RemoteConversationOrigin` makes.
    private static func attribution(for source: MessageSource?, in session: RemoteSessionInfo) -> String {
        guard let source else { return "" }
        if source == session.source { return " from this chat" }
        switch source {
        case .telegram:                       return " from Telegram"
        case .discord:                        return " from Discord"
        case .slack:                          return " from Slack"
        case .localUI, .quickAccess, .jarvis: return " from the Mac"
        case .scheduled:                      return ""
        }
    }

    /// Reads the two facts every observer needs out of a resolution notification.
    private static func resolution(from notification: Notification) -> (outcome: String?, source: MessageSource?) {
        let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String
        let source = (notification.userInfo?[HITLResolvedKey.source] as? String)
            .flatMap(MessageSource.init(rawValue:))
        return (outcome, source)
    }

    /// When Mac UI resolves an HITL event, update the Telegram message to show it was handled.
    private func setupHITLResolvedObservers() {
        permissionResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPermissionResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let approved = notification.userInfo?[HITLResolvedKey.approved] as? Bool
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let approved,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                // ⚠️ A CANCEL IS NOT A DENIAL. `drainOperation` resolves a torn-down permission with
                // `approved: false`, so a stopped run or a deadline used to render as
                // "❌ Tool denied (from Mac)" — a decision nobody made, attributed to a surface
                // nobody used. The `outcome` key already carried the truth; nothing read it.
                let statusText: String
                if resolution.outcome == "cancelled" {
                    statusText = "⏹ Tool request cancelled — the run was stopped."
                } else {
                    statusText = (approved ? "✅ Tool approved" : "❌ Tool denied")
                        + Self.attribution(for: resolution.source, in: session) + "."
                }

                await self.editResolvedPrompt(session, messageID: messageID, to: statusText,
                                              operationID: operationID, kind: "tool approval")
                self.hitlMessageIDs.removeValue(forKey: operationID)
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }

        clarificationResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlClarificationResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                let statusText: String
                switch resolution.outcome {
                case "cancelled":
                    statusText = "⏹ Clarification cancelled — the run was stopped."
                case "skipped":
                    statusText = "⏭ Clarification skipped"
                        + Self.attribution(for: resolution.source, in: session) + "."
                default:
                    statusText = "✅ Clarification answered"
                        + Self.attribution(for: resolution.source, in: session) + "."
                }
                await self.editResolvedPrompt(session, messageID: messageID, to: statusText,
                                              operationID: operationID, kind: "clarification")
                self.hitlMessageIDs.removeValue(forKey: operationID)
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }

        planReviewResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlPlanReviewResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let resolution = Self.resolution(from: notification)

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                let statusText: String
                switch resolution.outcome {
                case "cancelled":
                    statusText = "⏹ Plan review cancelled — the run was stopped."
                case "rejected":
                    statusText = "❌ Plan rejected"
                        + Self.attribution(for: resolution.source, in: session) + "."
                default:
                    statusText = "✅ Plan approved"
                        + Self.attribution(for: resolution.source, in: session) + "."
                }
                await self.editResolvedPrompt(session, messageID: messageID, to: statusText,
                                              operationID: operationID, kind: "plan review")
                self.hitlMessageIDs.removeValue(forKey: operationID)
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }

        // [D1] Gate resolved (a choice was made on the Mac or remotely) → reflect the outcome and
        // drop the now-stale option buttons on the remote message.
        gateResolvedObserver = NotificationCenter.default.addObserver(
            forName: .hitlGateResolved,
            object: nil,
            queue: .main
        ) { notification in
            let operationID = notification.userInfo?[HITLResolvedKey.operationID] as? UUID
            let outcome = notification.userInfo?[HITLResolvedKey.outcome] as? String
            let conversationID = notification.userInfo?[HITLResolvedKey.conversationID] as? UUID
            let source = Self.resolution(from: notification).source

            Task { @MainActor [weak self] in
                guard let self,
                      let operationID,
                      let messageID = self.hitlMessageIDs[operationID],
                      let convID = conversationID,
                      let session = self.remoteSessions[convID] else { return }

                // ⚠️ A cancelled gate is not a decision, so it does not get a ✅ or an attribution.
                let statusText: String
                if outcome == nil || outcome == "cancelled" {
                    statusText = "⏹ Gate cancelled — the workflow took its default path."
                } else {
                    statusText = "✅ Gate decided: \(outcome ?? "")"
                        + Self.attribution(for: source, in: session) + "."
                }
                await self.editResolvedPrompt(session, messageID: messageID, to: statusText,
                                              operationID: operationID, kind: "gate")
                self.hitlMessageIDs.removeValue(forKey: operationID)
                self.mirroredOperations.remove(operationID)   // [HITL/P5] bound the dedup Set
            }
        }
    }
}
