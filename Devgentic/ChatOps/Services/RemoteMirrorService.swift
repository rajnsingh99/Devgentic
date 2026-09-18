// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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
/// Which pending interactions belong to the run being mirrored.
///
/// ⚠️⚠️ A NAMED FUNCTION RATHER THAN A `filter` CLOSURE INLINE, for one concrete reason: a test that
/// retypes the predicate passes over a mirror that never applies it. Mutation-checking the first
/// draft of this fix proved it — reverting the mirror to the conversation-wide list left every
/// behavioural test green, because they were exercising a copy. Production and the tests now call
/// the same function, so a change to the rule is a change both sides see.
enum RemoteInteractionScope {

    /// - Parameter runMessageID: the agent message of the run currently being mirrored.
    ///
    /// ⚠️ NIL `origin.runMessageID` PASSES, DELIBERATELY — it means "raised outside any run", which
    /// today is MCP elicitation alone (its source→conversation association is made in
    /// `resolveMCPTool`, where no run identity is in scope). Treating nil as a mismatch would stop
    /// mirroring those prompts even for a run the remote user started themselves, turning a leak fix
    /// into a hang. Recorded as the remaining residual in §6 of `architecture_readme.md`.
    static func belongingToRun(_ runMessageID: UUID, in items: [PendingHITL]) -> [PendingHITL] {
        items.filter { $0.origin.runMessageID == runMessageID || $0.origin.runMessageID == nil }
    }
}

@MainActor
final class RemoteMirrorService: ActiveStreamMirrorDelegate {

    private let logger = DGLogger(category: "RemoteMirrorService")

    // MARK: - State

    /// Active remote sessions keyed by conversationID.
    private var remoteSessions: [UUID: RemoteSessionInfo] = [:]

    /// Tracks which HITL operationIDs have been mirrored to transport (prevents duplicates).
    private var mirroredOperations: Set<UUID> = []

    /// Maps operationID → transport message_id (for editing HITL messages after resolution).
    private var hitlMessageIDs: [UUID: String] = [:]

    /// Messages currently being observed via withObservationTracking.
    private var observedMessageIDs: Set<UUID> = []

    /// Conversations with a mirrored run IN FLIGHT. Written only when the consent gate admits a run.
    ///
    /// ⚠️ SEPARATE FROM `remoteSessions` BECAUSE THEY ANSWER DIFFERENT QUESTIONS. The session map is
    /// an ADDRESS BOOK — it holds the chat id and provider, and the four HITL resolution observers
    /// and `editResolvedPrompt` still need it after the run ends, which is why releasing it at
    /// `didEndStream` would strand live buttons on already-resolved prompts. This set is the
    /// "is something being mirrored right now" predicate, and it is the one that has to be per-run.
    private var mirroringConversations: Set<UUID> = []

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

    /// ⚠️⚠️ THE CONSENT GATE, AND IT IS PER RUN — NOT PER CONVERSATION. It used to read
    /// `guard remoteSessions[conversationID] != nil`, which asks "has this conversation EVER been
    /// driven from chat". Since `unregisterSession` had no callers and only stopping the bridge
    /// cleared the map, the answer stayed yes forever: a conversation touched once from Slack then
    /// mirrored every later run in it — including ones typed at the Mac and ones fired by the
    /// scheduler — in full, to the third-party channel, with no switch anywhere to turn it off. The
    /// sibling path to the same channel (`ChatOpsNotificationChannel`) is default-OFF with a written
    /// rationale about exactly this; this path had no such treatment.
    ///
    /// ⚠️ `startedBy` DECIDES, and it fails CLOSED. `.localUI` means "not attributed" rather than
    /// "typed by hand" — a surface that forgets to stamp lands there — so a non-matching source
    /// refuses to mirror rather than assuming permission. The cost is named in `admissionRefused`.
    ///
    /// ⚠️ This also closes cross-provider leakage for free: with three bridges connected, a
    /// Telegram-started run is no longer mirrored to Discord and Slack as well.
    ///
    /// ⚠️ `observedMessageIDs` is ALREADY the per-run set, so admitting fewer runs here needs no
    /// new state — this one line is the whole gate. `observeMessage` and `evaluateMessageState` are
    /// reachable from nowhere else.
    func activeStreamManager(_ manager: ActiveStreamManager, didStartStream message: ChatMessage,
                             startedBy: MessageSource, for conversationID: UUID) {
        guard let session = remoteSessions[conversationID] else { return }
        guard startedBy == session.source else {
            admissionRefused(startedBy: startedBy, session: session, conversationID: conversationID)
            return
        }
        guard !observedMessageIDs.contains(message.id) else { return }
        // ⚠️ Recorded so `isMirroring` can answer about THIS RUN. See that property.
        mirroringConversations.insert(conversationID)

        // ⚠️⚠️ [MIR-4] MOVED HERE FROM `observeMessage`, WHICH IS RE-ENTRANT. That function re-arms
        // its observation on every flush — roughly 5-20 times a SECOND at the adaptive interval — so
        // an `.info` line there emitted one entry per re-arm and buried the mirror's real drop lines
        // under its own noise, in the ring buffer a diagnostic bundle exports. This site runs ONCE
        // per admitted run, and `session` is in scope here, so the line also gains the provider
        // correlation it never had.
        logger.info("[Mirror] Mirroring the run in conversation \(conversationID.uuidString.prefix(8)) to \(session.source.rawValue). CONSEQUENCE: its answer, HITL prompts and failures all reach that chat; a conversation absent from this line produced no remote output at all.")
        observeMessage(message)
    }

    func activeStreamManager(_ manager: ActiveStreamManager, didEndStream message: ChatMessage) {
        observedMessageIDs.remove(message.id)
        // [HITL/P5] Drop the final-response send-once key so the dedup Set doesn't grow unbounded.
        mirroredOperations.remove(message.id)
        // ⚠️ The RUN is over, so this conversation is no longer being mirrored — but the SESSION
        // stays (see `remoteSessions`). Only the notification double-post predicate is released here.
        mirroringConversations.remove(message.conversationId)
    }

    /// Says out loud that a run in a session-bearing conversation was NOT mirrored.
    ///
    /// ⚠️ A REFUSAL IS A DECISION THE REMOTE USER CANNOT SEE. Without this line the only evidence is
    /// an answer that never arrives, which is indistinguishable from a dead bridge.
    private func admissionRefused(startedBy: MessageSource, session: RemoteSessionInfo, conversationID: UUID) {
        logger.info("[Mirror] A run in conversation \(conversationID.uuidString.prefix(8)) was started by '\(startedBy.rawValue)' but this session belongs to '\(session.source.rawValue)', so it was NOT mirrored. CONSEQUENCE: its answer stays on the Mac and does not reach the remote chat — which is the point; before this gate existed, every later run in a conversation once driven from chat was posted to the third-party channel, whoever started it. A run you DID start remotely appearing here means its source was not stamped before startMessageStream.")
    }

    // MARK: - Session Registration

    /// Register a remote session for a conversation. Called when a remote message is submitted.
    func registerSession(conversationID: UUID, info: RemoteSessionInfo) {
        remoteSessions[conversationID] = info
        logger.info("[Mirror] Registered remote session for conversation \(conversationID) via \(info.source.rawValue).")
    }

    /// Whether a run in this conversation is being mirrored RIGHT NOW.
    ///
    /// ⚠️ [Slice 3] The double-post guard: `ChatOpsNotificationChannel` stays quiet for a
    /// conversation the mirror is already streaming, so a run started from chat is reported once
    /// rather than twice.
    ///
    /// ⚠️⚠️ THIS HAD TO CHANGE IN THE SAME COMMIT AS THE CONSENT GATE, and the reason is a silent
    /// failure rather than a tidy-up. It used to read `remoteSessions[conversationID] != nil` —
    /// sticky and conversation-keyed. Once the gate above stopped mirroring locally-started runs,
    /// that predicate would still have answered YES for them, so the notification channel would
    /// have suppressed itself for a run nothing was mirroring: no mirror AND no notice, and the
    /// remote user told nothing at all. It is the ONLY suppression in
    /// `ChatOpsNotificationChannel.send`, so getting it wrong loses the message outright.
    func isMirroring(_ conversationID: UUID) -> Bool {
        mirroringConversations.contains(conversationID)
    }

    /// Unregister a remote session. Called when its conversation is deleted, and on explicit cleanup.
    ///
    /// ⚠️ Had ZERO callers until 2026-09-11 — the map only ever grew, and `teardown()` on bridge
    /// stop was the only thing that cleared it.

    func unregisterSession(conversationID: UUID) {
        remoteSessions.removeValue(forKey: conversationID)
        logger.info("[Mirror] Unregistered remote session for conversation \(conversationID).")
    }

    /// [D2] Detaches this service when its owning transport stops: removes it from the stream manager's
    /// multicast and drops all sessions, so a stopped transport no longer mirrors Mac-UI activity back
    /// out (the bridge then nils its strong ref, letting the service deallocate). Without this, a stopped
    /// transport with a lingering session kept pushing responses to the remote chat.
    /// ⚠️⚠️ [MIR-5/OBS-6] SESSION-KEYED RELEASE FOR OPERATION-KEYED STATE WAS THE BUG. This cleared
    /// `remoteSessions` and `mirroringConversations` and left `hitlMessageIDs`, `mirroredOperations`
    /// and `observedMessageIDs` populated — so every posted HITL prompt was abandoned with its
    /// message id still recorded, and the observers that later try to rewrite those prompts found a
    /// session that no longer exists and bailed on a bare `return`. The buttons stay live on a
    /// decision nobody can now make, forever, and the log line said only "sessions cleared".
    ///
    /// ⚠️ THE COUNTS ARE THE POINT. "Torn down" is unfalsifiable; "abandoned 2 posted prompts across
    /// 1 session" is a fact a field debugger can act on, and it is the number that tells them whether
    /// a user is staring at live buttons that will never resolve.
    func teardown() {
        let abandonedPrompts = hitlMessageIDs.count
        let sessions = remoteSessions.count
        let observed = observedMessageIDs.count

        activeStreamManager?.removeMirrorDelegate(self)
        remoteSessions.removeAll()
        mirroringConversations.removeAll()
        hitlMessageIDs.removeAll()
        mirroredOperations.removeAll()
        observedMessageIDs.removeAll()

        if abandonedPrompts > 0 {
            logger.warning("[Mirror] Torn down while \(abandonedPrompts) posted HITL prompt(s) were still live across \(sessions) session(s). CONSEQUENCE: those prompts keep their approve/deny buttons in the remote chat and NOTHING will ever rewrite them — the run they belong to is unreachable from that chat now. A user tapping one gets silence. This fires when ChatOps is switched off mid-run.")
        } else {
            logger.info("[Mirror] Torn down — \(sessions) session(s) and \(observed) observed run(s) released, no live prompts abandoned.")
        }
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

    /// What kind of prompt a parked operation is, for a caller that must route a TYPED REPLY rather
    /// than a button tap.
    ///
    /// ⚠️⚠️ WHY A REPLY NEEDS THIS AND A TAP DOES NOT. A button carries its own verb — `hitl:approve:`
    /// is an approval whatever it is attached to — so `handleApproval` can dispatch on the kind it
    /// finds and be sure of the user's INTENT. A reply carries only text, and the only thing that
    /// says what the user meant is what they replied TO. Before this existed, Telegram's
    /// reply-correlation branch called `handleClarification` for every correlated reply, so replying
    /// to a mirrored tool-confirmation, plan-review or gate prompt resolved the wrong continuation:
    /// the clarification resume found nothing to resume, the tool stayed parked forever, and the
    /// operation's entry in `hitlMessageIDs` was consumed — so the prompt kept live buttons for a
    /// decision no surface could still make.
    ///
    /// ⚠️ Returns nil when the operation has ALREADY been resolved, which is a distinct answer from
    /// "wrong kind" and callers must say so: the user replied to a prompt that a race, the Mac UI,
    /// or another provider answered first, and telling them "use the buttons" would be a lie.
    func pendingInteraction(forOperation operationID: UUID) -> PendingInteraction? {
        activeStreamManager?.interactionCenter?.item(withID: operationID)?.kind
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


    }

    /// Evaluates current message state and mirrors events to the remote transport.
    private func evaluateMessageState(_ message: ChatMessage, conversationID: UUID) async {
        guard let session = remoteSessions[conversationID] else { return }

        // [HITL/P5] Mirror HITL request(s) from the unified InteractionCenter (single source of
        // truth). A workflow run can have several nodes awaiting at once, so mirror every
        // un-mirrored item — this also makes WORKFLOW HITL remotely actionable for the first time
        // (the legacy per-message container never carried workflow requests).
        //
        // ⚠️⚠️ FILTERED TO *THIS RUN*, NOT JUST THIS CONVERSATION. `items(for:)` is conversation-keyed,
        // and invariant 46 gates which RUNS are mirrored — so pulling every pending item for the
        // conversation walked straight around that gate: while a remote run was observed, a tool
        // confirmation raised by a LOCALLY-started run in the same conversation had its tool name and
        // parameters posted to the third-party channel. `message` is the run being mirrored and
        // `origin.runMessageID` is the run that raised the item, so comparing them is the gate.
        //
        // ⚠️ A NIL `runMessageID` IS POSTED, DELIBERATELY. Nil means "raised outside any run" — today
        // only MCP elicitation, whose source→conversation association is made in `resolveMCPTool`
        // where no run identity is in scope. Treating nil as a mismatch would silently stop mirroring
        // those prompts even for a run the remote user started themselves, turning a leak fix into a
        // hang. Recorded as the remaining residual in §6 of `architecture_readme.md`.
        let allPending = activeStreamManager?.interactionCenter?.items(for: conversationID) ?? []
        let pendingHITLs = RemoteInteractionScope.belongingToRun(message.id, in: allPending)

        let withheld = allPending.count - pendingHITLs.count
        if withheld > 0 {
            logger.warning("[Mirror] Withheld \(withheld) pending interaction(s) in conversation \(conversationID.uuidString.prefix(8)) from \(session.source.rawValue): they were raised by a different run than the one being mirrored (\(message.id.uuidString.prefix(8))). CONSEQUENCE: those prompts are answerable on the Mac banner only, which is correct — before this filter another run's tool name and parameters were posted to the remote channel purely because the two runs shared a conversation.")
        }

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
                    // ⚠️⚠️ THE RENDER WINDOW. `render` is a real network round-trip (100–800 ms),
                    // and the InteractionCenter item exists from before it starts — so the Mac
                    // banner is already answerable while this is suspended. A resolution landing
                    // inside the window reached all four observers BEFORE this line ran, every one
                    // of them read `hitlMessageIDs[operationID]` as nil, and every one returned
                    // without a word. This line then stored the id for an operation that was
                    // already dead: a fresh ✅/❌ prompt sat in the chat for a resolved decision,
                    // nothing ever struck it through (`editMessage` is the only thing that clears
                    // buttons), tapping it did nothing at all, and the stale entry kept
                    // `operationID(forRemoteMessageID:)` routing REPLIES to a suspension that no
                    // longer existed.
                    //
                    // ⚠️ Re-checking AFTER the await rather than reserving before it: the
                    // observers key off this map, and a placeholder would make them act on a
                    // message id that does not exist yet.
                    if activeStreamManager?.interactionCenter?.item(withID: pending.id) == nil {
                        logger.error("[Mirror] Operation \(pending.id) resolved while its prompt was being posted to \(session.source.rawValue). CONSEQUENCE: the prompt is rewritten as resolved immediately and its correlation id is NOT stored — without this it would have kept live buttons for a decision already made, and later replies to it would have been routed to a suspension that no longer exists.")
                        await editResolvedPrompt(session,
                                                 messageID: msgID,
                                                 to: "✅ Already answered on another surface.",
                                                 operationID: pending.id,
                                                 kind: "HITL")
                    } else {
                        hitlMessageIDs[pending.id] = msgID
                    }
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
        case .localUI, .quickAccess, .orb: return " from the Mac"
        case .scheduled:                      return ""
        }
    }

    /// What a resolution notification means for THIS mirror.
    ///
    /// ⚠️⚠️ [OBS-6] TWO OPPOSITE SITUATIONS SHARED ONE BARE `return`, AND ONE OF THEM IS A DEFECT.
    /// All four observers opened with a single combined guard — `let messageID =
    /// hitlMessageIDs[operationID], let convID, let session = remoteSessions[convID]` — so
    /// "this resolution is not ours" (the overwhelmingly common case: a Mac-only run, nothing posted
    /// remotely) and "it IS ours but we have lost the session" produced identical silence. The second
    /// leaves approve/deny buttons live in the remote chat on a decision already made, forever, with
    /// nothing written anywhere.
    ///
    /// ⚠️ THE ORDER IS PRESERVED EXACTLY: `hitlMessageIDs` FIRST, so `.notOurs` stays narrow. Checking
    /// the session first would classify every Mac-only resolution as stranded and flood the log with
    /// the non-event this distinction exists to keep out.
    ///
    /// ⚠️ `.notOurs` IS DELIBERATELY SILENT — the `PairingAttemptPolicy.unrelated` precedent. A line
    /// per Mac-only resolution buries the one that matters.
    private enum PromptResolution {
        case rewritable(messageID: String, session: RemoteSessionInfo)
        case notOurs
        case stranded(messageID: String, reason: String)
    }

    private func promptResolution(operationID: UUID?, conversationID: UUID?) -> PromptResolution {
        guard let operationID, let messageID = hitlMessageIDs[operationID] else { return .notOurs }
        guard let conversationID else {
            return .stranded(messageID: messageID, reason: "the notification carried no conversation id")
        }
        guard let session = remoteSessions[conversationID] else {
            return .stranded(messageID: messageID, reason: "no remote session remains for conversation \(conversationID.uuidString.prefix(8)) — ChatOps was switched off, or the bridge was stopped, while this prompt was live")
        }
        return .rewritable(messageID: messageID, session: session)
    }

    /// Says out loud that a posted prompt can no longer be rewritten.
    /// The message id and session a resolved prompt can be rewritten through, or nil.
    ///
    /// ⚠️ REPORTS `.stranded` ITSELF, so the four observers keep a one-line guard and cannot each
    /// forget the log. Returning nil for both outcomes is deliberate: the CALLER's behaviour is
    /// identical either way (stop), and only the LOGGING differs — which is exactly what OBS-6 was.
    private func rewritableTarget(operationID: UUID?,
                                  conversationID: UUID?) -> (messageID: String, session: RemoteSessionInfo)? {
        switch promptResolution(operationID: operationID, conversationID: conversationID) {
        case .rewritable(let messageID, let session):
            return (messageID, session)
        case .notOurs:
            return nil
        case .stranded(let messageID, let reason):
            reportStranded(operationID, messageID: messageID, reason: reason)
            return nil
        }
    }

    private func reportStranded(_ operationID: UUID?, messageID: String, reason: String) {
        logger.warning("[Mirror] A resolved HITL prompt (op \(operationID?.uuidString.prefix(8) ?? "?"), remote message \(messageID)) cannot be rewritten: \(reason). CONSEQUENCE: its approve/deny buttons stay LIVE in the remote chat on a decision that has already been made — a tap does nothing and answers nobody. Before this line the case was indistinguishable from the ordinary 'not ours' bail and left no trace at all.")
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
                      let target = self.rewritableTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let (messageID, session) = target

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
                      let target = self.rewritableTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let (messageID, session) = target

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
                      let target = self.rewritableTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let (messageID, session) = target

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
                      let target = self.rewritableTarget(operationID: operationID, conversationID: conversationID)
                else { return }
                let (messageID, session) = target

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
