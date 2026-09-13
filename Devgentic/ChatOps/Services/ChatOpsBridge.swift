// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  ChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 23/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Telegram ChatOps.
///
/// Routes incoming Telegram updates through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler (conversation management, agent pipeline, HITL).
///
/// Uses the single-path architecture: remote messages reach the agent through the same send path
/// the Mac UI uses. The `RemoteMirrorService` handles mirroring events back to the transport.
///
/// ⚠️ [BR-4] FREE TEXT GOES THROUGH `ChatOpsCommandService.submitTurn`, NOT through the view model
/// directly. This header used to name `MainApplicationViewModel.submitRemoteMessage()`, and calling
/// it here is exactly what let a second remote message start a second root run in a conversation
/// that was already streaming. `submitTurn` bundles the admission check, the mirror registration
/// and the submit so the three bridges cannot order them three different ways.
@Observable @MainActor
final class ChatOpsBridge {

    private let logger = DGLogger(category: "ChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: TelegramAPIClient?
    private var listener: TelegramListener?
    private let securityGate = ChatOpsSecurityGate()
    private var telegramTransport: TelegramTransport?

    /// [C5a] Decides what the READ-ONLY verbs show. Holds no transport, so it cannot post — the
    /// bridge renders whatever it returns. `/new`, `switch:` and `/cancel` still live below.
    private var commands: ChatOpsCommandService?
    var remoteMirrorService: RemoteMirrorService?
    private let config = ChatOpsConfigManager.shared

    // MARK: - State

    private var listeningTask: Task<Void, Never>?
    private(set) var isRunning: Bool = false

    /// Which start this is. [LIFE-2] A run compares it on completion to see whether it is still the
    /// one that owns the connection state.
    private var generation: UInt64 = 0

    init(viewModel: MainApplicationViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Lifecycle

    /// Starts the Telegram polling loop and begins processing updates.
    func start() {
        guard let token = config.botToken, !token.isEmpty else {
            logger.warning("Cannot start ChatOpsBridge — no bot token configured.")
            return
        }

        let client = TelegramAPIClient(botToken: token)
        let telegramListener = TelegramListener(apiClient: client)
        let transport = TelegramTransport(apiClient: client)

        self.apiClient = client
        self.listener = telegramListener
        self.telegramTransport = transport

        // Create RemoteMirrorService if ViewModel provides ActiveStreamManager
        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        // ⚠️ `conversations:` is injected explicitly rather than reached through
        // `viewModel.persistenceService` — that property is typed `ChatPersistenceProtocol`, which
        // `ConversationReading` is deliberately not part of, so a cast would silently no-op.
        if let vm = viewModel {
            self.commands = ChatOpsCommandService(
                provider: .telegram,
                runControl: vm,
                commanding: vm,
                conversations: ChatPersistenceStore.shared
            )
        }

        // ⚠️⚠️ [DC-1/LIFE-2] REFUSE A SECOND START — see `ChatOpsBridgeStart.shouldProceed` for why
        // this refuses rather than restarting: `stop()` tears down the mirror session and would kill
        // an in-flight tool approval. Placed after the credential guards, so a start that was never
        // going to work is still reported as a missing token rather than as a duplicate.
        guard ChatOpsBridgeStart.shouldProceed(isRunning: isRunning, provider: .telegram, logger: logger) else { return }

        // ⚠️ [LIFE-2] THE RUN'S OWN IDENTITY. Bumped on every start so the trailing block below can
        // tell whether it is still the live run before it writes anything user-visible.
        generation &+= 1
        let thisGeneration = generation

        isRunning = true

        // ⚠️⚠️ [NEW-1] THE ONE CASE WHERE THIS BRIDGE ANNOUNCES ITSELF UNPROMPTED. A pairing made
        // before per-sender authorization records no account, nothing backfills it, and the gate then
        // refuses EVERY message with a bare return — so the remote user sees a bot that simply stopped
        // answering. Settings now says so too, but they are not looking at Settings; they are looking
        // at this chat. See `ChatOpsUpgradeNotice` for why posting here is safe and why it is once.
        if ChatOpsUpgradeNotice.needsRepairing(addressPresent: config.authorizedChatID != nil,
                                               authorizedUserID: config.authorizedUserID),
           ChatOpsUpgradeNotice.claimAnnouncement(for: .telegram) {
            Task { [weak self] in
                guard let self else { return }
                guard let chatID = self.config.authorizedChatID else { return }
                await self.tell(chatID, ChatOpsUpgradeNotice.message, whenLost: "the remote user is not told WHY the bot stopped answering, so they keep sending commands into a bridge that refuses every one of them and have no way to learn that re-pairing is the fix.")
                self.logger.error("[CHATOPS] Told the paired telegram chat that this Mac needs re-pairing: the pairing predates per-sender authorization and records no account. CONSEQUENCE: every remote command is refused until the user re-pairs from Settings — without this notice the bot simply went silent and the user had no way to learn why.")
            }
        }

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await telegramListener.start()
            self.logger.info("ChatOpsBridge started — listening for Telegram updates.")

            for await update in stream {
                await self.handleUpdate(update)
            }

            // ⚠️⚠️ THE STREAM ENDING MEANS ONE OF TWO OPPOSITE THINGS, AND THIS IS WHERE THEY ARE
            // TOLD APART. `stop()` ends it deliberately; a terminal API error ends it because
            // remote control is DEAD until the user intervenes. Both used to arrive here as the
            // same `.info` line and the same `isRunning = false`, so a revoked token left the
            // Settings UI showing a green "Active" dot over a bridge that would never poll again.
            let terminalFailure = await telegramListener.terminalFailure

            await MainActor.run {
                // ⚠️ [LIFE-2] OWNERSHIP FIRST. A run superseded by a later start must not write the
                //   connection state — see `ChatOpsBridgeShutdown.report`.
                let isOwner = self.generation == thisGeneration
                if isOwner { self.isRunning = false }
                ChatOpsBridgeShutdown.report(terminalFailure: terminalFailure,
                                             provider: .telegram,
                                             isOwner: isOwner,
                                             logger: self.logger) { self.config.connectionState = $0 }
                return
            }
        }
    }

    /// Stops the polling loop and cleans up.
    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await listener?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("ChatOpsBridge stopped.")

        // ⚠️⚠️ [LIFE-2/LIFE-7] RELEASE WHAT THIS RUN OWNED. `stop()` used to leave every client,
        // transport and the command service installed, so a "stopped" bridge still held a live API
        // client and — through `ChatOpsCommandService` — a STRONG reference to the app's main view
        // model, defeating the `weak var viewModel` this file declares two lines up.
        apiClient = nil
        listener = nil
        telegramTransport = nil
        commands = nil
    }

    // MARK: - Update Routing

    private func handleUpdate(_ update: TelegramUpdate) async {
        // 1. Security gate
        let authorization = await securityGate.authorize(update, config: config)
        if case .refused(let refusal) = authorization {
            // ⚠️⚠️ [TG-5/SEC-6] THE ONE REFUSAL THE OPERATOR IS OWED. Every other arm stays silent on
            // purpose — answering an unpaired room confirms a Mac is listening there. A THROTTLED
            // sender has already proved they are the paired operator, so telling them leaks nothing,
            // and before this they saw exactly what an intruder saw.
            if refusal.mayReply, let chatID = update.chatID,
               ChatOpsThrottleNotice.claim(for: .telegram),
               case .rateLimited(let retry) = refusal.reason {
                await tell(chatID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }

        // 2. Acknowledge callback queries immediately to remove spinner
        if let callbackQuery = update.callback_query {
            // ⚠️ THE ACK IS WHAT CLEARS THE SPINNER ON THE BUTTON. A swallowed failure leaves the
            // tap looking permanently in-flight, which reads as "the app hung" rather than "the
            // network blipped" — and it was the only ack on this path, so nothing retried it.
            do {
                try await apiClient?.answerCallbackQuery(id: callbackQuery.id)
            } catch {
                logger.error("[CHATOPS] Failed to acknowledge a Telegram callback query \(callbackQuery.id): \(error.localizedDescription). CONSEQUENCE: the tapped button keeps its loading spinner indefinitely, so the user cannot tell whether their tap registered; the command itself still runs below.")
            }
        }

        // 2b. ⚠️ A REPLY ANSWERS THE MESSAGE IT REPLIES TO, and that beats every inference. The
        //     clarification prompt now carries a `ForceReply`, so Telegram sends the answer back
        //     with `reply_to_message` — the only thing on the wire that says WHICH clarification is
        //     being answered. Checked BEFORE parsing, because the parser cannot see it and would
        //     fall back to the provider cursor, which is what made a second parked clarification
        //     unanswerable and let a `/new` in between misroute the answer into a new agent run.
        //
        //     ⚠️⚠️ THIS BRANCH IS NOT A SHORTCUT PAST THE TIER GATE OR THE PARSER, and it was both
        //     until 2026-09-10. It ran before step 3 and step 4 and called `handleClarification`
        //     unconditionally, which cost three separate defects: a `.readOnly` user could steer a
        //     live agent run by replying (the gate below never saw the act); `/cancel` typed into
        //     the ForceReply box was delivered to the agent as the literal answer text rather than
        //     cancelling anything; and a reply to a mirrored tool-confirmation, plan-review or gate
        //     prompt resolved the clarification continuation instead — parking that operation
        //     forever while consuming its `hitlMessageIDs` entry, so its buttons stayed live for a
        //     decision no surface could still make. Correlation is still decided FIRST, because
        //     only the reply knows which operation is meant; what follows it is the same gate and
        //     the same parser every other path uses.
        if let repliedTo = update.message?.reply_to_message?.message_id,
           let text = update.message?.text,
           let operationID = await remoteMirrorService?.operationID(forRemoteMessageID: "\(repliedTo)"),
           // ⚠️ A KNOWN VERB IN THE REPLY BOX IS A COMMAND, NOT AN ANSWER. Same table, same
           //   judgement `parse` step 4 already makes for typed text — a user who replies `/cancel`
           //   to a parked prompt means to stop the run, and answering the model with the string
           //   "/cancel" is the failure `parse` moved its own slash branch above the clarification
           //   branch to prevent. Falling through hands it to the normal switch below.
           //   ⚠️ `/skip` is deliberately NOT a table verb: it means "answer this prompt with
           //   nothing", which is only meaningful for the operation being replied to, so it is
           //   handled inside `handleCorrelatedReply` where that operation is known.
           ChatOpsVerbTable.parse(slashPrefixedText: text) == nil {
            await handleCorrelatedReply(operationID: operationID,
                                        repliedToMessageID: repliedTo,
                                        text: text,
                                        chatID: update.chatID)
            return
        }

        // 3. Parse command
        let command = ChatOpsCommand.parse(
            text: update.message?.text,
            callbackData: update.callback_query?.data,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // 4. Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier(for: .telegram)) else {
            if let chatID = update.chatID {
                let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .telegram))
                let tierName = config.securityTier(for: .telegram).rawValue
                logger.error("[CHATOPS] A Telegram \(String(describing: command)) from chat \(chatID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all.")
                await tell(chatID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            }
            return
        }

        // 5. Route
        guard let chatID = update.chatID else { return }

        switch command {
        case .conversations:
            await render(commands?.conversationList(offset: 0), to: chatID)
        case .conversationPage(let offset):
            await render(commands?.conversationList(offset: offset), to: chatID)
        case .searchConversations(let query):
            await render(commands?.searchConversations(query: query), to: chatID)
        case .conversationHistory(let argument):
            await render(commands?.conversationHistory(argument: argument), to: chatID)
        case .newConversation:
            await render(commands?.newConversation(), to: chatID)
        case .status:
            await render(commands?.status(), to: chatID)
        case .cancel:
            await render(await commands?.cancelRun(), to: chatID)
        case .help:
            await render(commands?.help(), to: chatID)
        case .switchConversation(let uuid):
            await render(commands?.switchConversation(to: uuid), to: chatID)
        case .profiles:
            await render(commands?.profileList(), to: chatID)
        case .selectProfile(let profileID):
            await render(commands?.selectProfile(profileID), to: chatID)
        case .useProfile(let name):
            await render(commands?.useProfile(named: name), to: chatID)
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        case .answerClarification:
            // ⚠️ TELEGRAM NEVER EMITS THIS. It has no modal, so its clarification prompt carries a
            // `ForceReply` instead and the answer arrives correlated by `reply_to_message`. The arm
            // exists because the callback grammar is shared across all three platforms, and it
            // degrades rather than going silent: a token from anywhere else still gets an answer.
            await tell(chatID,
                       "Reply to the clarification message with your answer — Telegram has no form dialog.",
                       whenLost: "the user tapped an Answer button that Telegram cannot honour and is told nothing, so the run stays parked with no visible way to answer it.")
        case .clarificationResponse(let text):
            await resolveClarification(text)
        case .freeText(let text):
            await handleFreeText(text, chatID: chatID)
        case .pairingAttempt:
            // ⚠️ GENUINELY OWNED ELSEWHERE — `ChatOpsPairingService` polls `getUpdates` on its own
            // while unpaired, so this arm is correct to post nothing. Logged at `debug` rather than
            // `info` because it is the expected path, not a drop.
            logger.debug("[CHATOPS/SILENT] A Telegram pairing attempt reached the bridge and was ignored. CONSEQUENCE: none — ChatOpsPairingService owns pairing and answers it on its own polling loop; a reply here would duplicate that.")
        case .unknown:
            // ⚠️ A REAL DROP, and it was a bare `break`. Reached by a plain message matching no verb
            // and by a button whose callback token no longer parses — a stale button from a
            // superseded grammar, which Telegram scrollback keeps forever.
            logger.warning("[CHATOPS/SILENT] A Telegram input parsed to `.unknown` in chat \(chatID) and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive; if this was a button tap, its token no longer parses and every copy of that button in scrollback is inert.")
        }
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, chatID: Int64) async {
        // ⚠️ [LIFE-7] NO LIVENESS GUARD HERE ANY MORE. It used to bare-return, discarding a gated,
        // tier-checked, parsed prompt with no line and no reply. `ChatOpsCommandService` now holds
        // its host WEAKLY and answers a lost one through `hostLost` / `hostUnavailable`, so the
        // command is refused *and the user is told* instead of vanishing.

        // Ensure there's an active conversation
        guard let conversationID = config.activeConversationID else {
            await tell(chatID,
                       "No active conversation. Use /conversations to pick one or /new to create one.",
                       whenLost: "the user is not told their prompt was dropped for want of an active conversation, so they wait for an answer that is never coming.")
            return
        }

        // Resolve the backend profile for this conversation
        guard let commands, let profile = commands.profile(boundTo: conversationID) else {
            await tell(chatID, "⚠️ No agent profile found for this conversation.",
                       whenLost: "the user is not told their prompt was dropped because the conversation resolves to no backend profile, so they wait for an answer that is never coming.")
            return
        }

        // Send typing indicator.
        // ⚠️ DELIBERATELY SWALLOWED, and this comment is why the next reader should leave it alone.
        // A typing indicator is pure decoration with no consequence to name: it expires on its own,
        // the reply arrives regardless, and logging a line per message for a cosmetic call would
        // bury the drops that DO matter. This is the one send on this path that is allowed to fail
        // in silence.
        _ = try? await apiClient?.sendTypingAction(chatID: chatID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // Single-path architecture: route through the SAME flow as Mac UI — the message appears in
        // the Mac window, HITL banners show, and RemoteMirrorService observes the stream and
        // mirrors events back to Telegram.
        //
        // ⚠️ [BR-4] ADMISSION, SESSION REGISTRATION AND SUBMIT ARE ONE CALL, and it is the command
        // service's rather than this bridge's so that a test can watch what it submits — see
        // `ChatOpsCommandService.submitTurn`. Calling `vm.submitRemoteMessage` directly here is what
        // let a second remote message start a second root run in the same conversation.
        let admission = commands.submitTurn(
            prompt: text,
            conversationID: conversationID,
            source: .telegram,
            config: requestConfig,
            attachMirror: { [weak self] in
                guard let self,
                      let transport = self.telegramTransport,
                      let mirror = self.remoteMirrorService else { return false }
                mirror.registerSession(
                    conversationID: conversationID,
                    info: RemoteSessionInfo(transport: transport, chatID: "\(chatID)", source: .telegram)
                )
                return true
            }
        )

        if case .refused(let message, let consequence) = admission {
            await tell(chatID, message, whenLost: consequence)
        }
    }


    /// [C8] Answers the parked clarification. ⚠️ The operation id is derived at the moment of the
    /// reply, not remembered from when the prompt was sent — a run cancelled in between leaves no
    /// pending item, and answering a stale id would resume a continuation that no longer exists.
    /// ⚠️ THE IMPRECISE PATH, kept for a user who TYPES an answer instead of replying to the
    /// prompt. It resolves the oldest clarification parked in whatever conversation the provider
    /// cursor currently names. A reply is correlated exactly and never reaches here — see the
    /// `reply_to_message` branch in `handleUpdate`.
    private func resolveClarification(_ text: String) async {
        guard let operationID = commands?.pendingClarificationOperationID() else {
            logger.error("[CHATOPS] A clarification answer arrived but no clarification is pending for the bound conversation. CONSEQUENCE: the reply was DROPPED rather than submitted as a new agent turn, and the remote user received no acknowledgement.")
            return
        }
        await remoteMirrorService?.handleClarification(operationID: operationID, text: text)
    }


    /// Posts a plain-text message that EXPLAINS something to the remote user, and logs when it does
    /// not arrive.
    ///
    /// ⚠️⚠️ EVERY CALLER OF THIS IS A "HERE IS WHY NOTHING HAPPENED" MESSAGE — a tier denial, an
    /// unbound conversation, a missing profile. They were all `_ = try? await apiClient?.send…`, so
    /// the one message whose entire job is to explain a failure was itself dropped in silence: the
    /// user's command did nothing, the explanation never arrived, and NO line was written anywhere.
    /// A tier-blocked command and a crashed bridge looked identical from both sides.
    ///
    /// ⚠️ `whenLost` IS REQUIRED, NOT DEFAULTED, and that is the anti-drift mechanism — the same one
    /// `resolvedBy:` and `offset:` use elsewhere in this subsystem. A new call site cannot be added
    /// without stating what the user loses when the message does not arrive, and a default would be
    /// one generic sentence quietly inherited by all of them.
    /// Routes a reply that `operationID(forRemoteMessageID:)` matched to a parked prompt.
    ///
    /// Correlation has already decided WHICH operation is meant; this decides whether the user is
    /// allowed to answer it and whether a typed answer can answer it at all. See the call site for
    /// the three defects that existed while this logic was absent.
    ///
    /// ⚠️ Every arm below either resolves the operation or TELLS THE USER why it did not. A reply
    /// that lands on the wrong kind used to disappear: no reply, no log, and a parked run.
    private func handleCorrelatedReply(
        operationID: UUID,
        repliedToMessageID: Int,
        text: String,
        chatID: Int64?
    ) async {
        // 1. The same tier gate step 4 applies to a typed clarification answer. A reply IS a
        //    `.clarificationResponse`; reaching the agent by replying rather than by typing cannot
        //    be the thing that decides whether the tier allows it.
        let asCommand = ChatOpsCommand.clarificationResponse(text)
        guard await securityGate.canExecute(asCommand, tier: config.securityTier(for: .telegram)) else {
            let tierName = config.securityTier(for: .telegram).rawValue
            logger.error("[CHATOPS] A Telegram reply to message \(repliedToMessageID) correlated to parked operation \(operationID.uuidString) was refused by the \(tierName) security tier. CONSEQUENCE: the operation stays parked and the agent is not steered by this reply; before this gate existed a Read Only user could answer any parked prompt simply by replying to it.")
            if let chatID {
                let msg = await securityGate.denialMessage(for: asCommand, tier: config.securityTier(for: .telegram))
                await tell(chatID, msg, whenLost: "the remote user is not told why their reply was refused, so a tier-blocked reply and a dead bridge look identical to them.")
            }
            return
        }

        // 2. Only a clarification can be answered with TEXT. Everything else parks in a different
        //    continuation and needs its own affordance.
        let kind = await remoteMirrorService?.pendingInteraction(forOperation: operationID)
        switch kind {
        case .clarification:
            // ⚠️ `/skip` MEANS "ANSWER WITH NOTHING", and it is resolved here rather than in the
            //   verb table because it is only meaningful against a specific parked prompt — the
            //   table's verbs are channel-wide. `parse` step 5 makes the same translation for a
            //   typed (non-reply) answer; this keeps the two paths saying the same thing.
            let answer = text.trimmingCharacters(in: .whitespaces).lowercased() == "/skip" ? "" : text
            logger.info("[CHATOPS] A Telegram reply to message \(repliedToMessageID) resolved clarification \(operationID.uuidString) by correlation rather than by the conversation cursor.")
            await remoteMirrorService?.handleClarification(operationID: operationID, text: answer)

        case .toolConfirmation, .planReview, .gate:
            let what: String
            let advice: String
            switch kind {
            case .toolConfirmation: what = "tool approval"; advice = "Tap Approve or Deny on that message."
            case .planReview:       what = "plan review";   advice = "Tap Approve or Reject on that message."
            default:                what = "gate";          advice = "Tap one of the options on that message."
            }
            logger.error("[CHATOPS] A Telegram reply to message \(repliedToMessageID) correlated to operation \(operationID.uuidString), which is a \(what) and cannot be answered with text. CONSEQUENCE: the reply is NOT delivered and the operation stays parked with its buttons live — which is correct; routing it to the clarification continuation instead, as this path used to, resumed nothing, parked the run forever and consumed the prompt's message id so its buttons could never be rewritten.")
            if let chatID {
                await tell(chatID,
                           "That message is a \(what), not a question — a typed reply can't answer it. \(advice)",
                           whenLost: "the remote user believes their reply answered the prompt when it did not, and the run stays parked with no explanation on any surface.")
            }

        case .none:
            // ⚠️ DISTINCT FROM "WRONG KIND". The operation is gone — resolved on the Mac, by another
            //   provider, or by a race with this very reply — and telling the user to use the
            //   buttons would send them to a message whose buttons no longer do anything.
            logger.error("[CHATOPS] A Telegram reply to message \(repliedToMessageID) correlated to operation \(operationID.uuidString), which is no longer pending. CONSEQUENCE: the reply is discarded; the prompt was already resolved on the Mac or by another connected provider, so there is nothing left for it to answer.")
            if let chatID {
                await tell(chatID,
                           "That prompt has already been answered — on the Mac, or from another connected chat. Your reply wasn't needed.",
                           whenLost: "the remote user believes their reply resolved a prompt that something else had already resolved, and will not understand why the run continued without it.")
            }
        }
    }

    private func tell(_ chatID: Int64, _ text: String, whenLost consequence: String) async {
        guard let apiClient else {
            logger.error("[CHATOPS] No Telegram API client while telling the user: \"\(text.prefix(60))\". CONSEQUENCE: \(consequence)")
            return
        }
        do {
            _ = try await apiClient.sendMessage(chatID: chatID, text: RemoteEgressSanitizer.credentialsOnly(text), parseMode: nil)
        } catch {
            logger.error("[CHATOPS] Failed to tell the Telegram user \"\(text.prefix(60))\": \(error.localizedDescription). CONSEQUENCE: \(consequence)")
        }
    }

    /// [C5a] Posts a decided view. ⚠️ Unlike the `_ = try? await apiClient?.sendMessage(...)` it
    /// replaces, a failure is LOGGED rather than swallowed — the wire behaviour is unchanged, but a
    /// send that silently vanished now leaves a trace.
    private func render(_ view: RemoteView?, to chatID: Int64) async {
        guard let view else {
            logger.error("[CHATOPS] A command produced no view for chat \(chatID) because the command service was never built — start() ran without a view model. CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        guard let transport = telegramTransport else {
            logger.error("[CHATOPS] No Telegram transport while rendering a view for chat \(chatID). CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        do {
            try await transport.render(view, to: .channel(RemoteChannel(telegramChatID: chatID)))
        } catch {
            logger.error("[CHATOPS] Failed to render a view to Telegram chat \(chatID): \(error.localizedDescription). CONSEQUENCE: the remote user receives NO reply for a command that succeeded locally.")
        }
    }
}

// MARK: - Announcing (slice 3)

/// ⚠️ The BRIDGE conforms, not the transport: a transport renders to a destination it is given,
/// while announcing means knowing this provider's OWN paired channel. Only the bridge knows both.
extension ChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .telegram }

    /// ⚠️ Requires a live listener AND a paired channel. A bridge that was stopped, or was never
    /// paired, must announce nothing — otherwise a notification would be addressed to a channel the
    /// user has disconnected.
    var canAnnounce: Bool {
        isRunning && config.botToken != nil && config.authorizedChatID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // ⚠️ nil is NOT a duplicate: an app-wide notification (a finished download) belongs to no
        // conversation, so nothing is already reporting it.
        guard let conversationID else { return false }
        return remoteMirrorService?.isMirroring(conversationID) ?? false
    }

    func announce(_ view: RemoteView) async -> Bool {
        // ⚠️ Split rather than `.map { String($0) }` inline — Swift cannot parse a trailing closure
        // inside a `guard` condition.
        guard let transport = telegramTransport, let chatID = config.authorizedChatID else {
            logger.error("[CHATOPS] Cannot announce on \(self.provider.rawValue) — no transport or no paired channel. CONSEQUENCE: this notification reaches the Mac only, and the remote user is never told.")
            return false
        }
        do {
            try await transport.render(view, to: .channel(RemoteChannel(telegramChatID: chatID)))
        } catch {
            logger.error("[CHATOPS] Failed to announce on \(self.provider.rawValue): \(error.localizedDescription). CONSEQUENCE: the notification is lost — announcements are fire-and-forget and nothing retries them.")
            return false
        }
        return true
    }
}
