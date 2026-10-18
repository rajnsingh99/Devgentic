// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Telegram ChatOps: routes incoming updates through the security gate, parses them into
/// commands and dispatches them to the matching handler. Free text goes through `ChatOpsCommandService.submitTurn`
/// (admission, mirror registration, submit), not the view model directly.
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

        // `conversations:` is injected explicitly: `viewModel.persistenceService` is typed `ChatPersistenceProtocol`, of which
        // `ConversationReading` is not part, so a cast would silently no-op.
        if let vm = viewModel {
            self.commands = ChatOpsCommandService(
                provider: .telegram,
                runControl: vm,
                commanding: vm,
                conversations: ChatPersistenceStore.shared
            )
        }

        // Refuses a second start (see `ChatOpsBridgeStart.shouldProceed`): `stop()` would tear down the mirror session and kill
        // an in-flight approval. After the credential guards, so a start that cannot work reports a missing token.
        guard ChatOpsBridgeStart.shouldProceed(isRunning: isRunning, provider: .telegram, logger: logger) else { return }

        // This run's own identity: bumped on every start so the trailing block can tell whether it is still the live run.
        generation &+= 1
        let thisGeneration = generation

        isRunning = true

        // The one case where this bridge announces itself unprompted: an old pairing records no account and the gate then
        // refuses every message silently. See `ChatOpsUpgradeNotice` for why posting here is safe and happens once.
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

            // The stream ends either deliberately (`stop()`) or because a terminal API error left remote control dead; this is
            // where they are told apart, so a revoked token does not leave Settings showing a green "Active" dot.
            let terminalFailure = await telegramListener.terminalFailure

            await MainActor.run {
                // Ownership first: a run superseded by a later start must not write the connection state
                // (see `ChatOpsBridgeShutdown.report`).
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

        // Releases what this run owned: a stopped bridge must not keep a live API client or, through `ChatOpsCommandService`,
        // a strong reference to the main view model (the `weak var viewModel` declared above).
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
            // The one refusal the operator is owed: other arms stay silent because answering an unpaired room confirms a Mac is
            // listening. A throttled sender has already proved they are the paired operator, so telling them leaks nothing.
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
            // The ack clears the spinner on the button; a swallowed failure leaves the tap looking permanently in-flight, which
            // reads as a hung app. It is the only ack on this path, so nothing retries it.
            do {
                try await apiClient?.answerCallbackQuery(id: callbackQuery.id)
            } catch {
                logger.error("[CHATOPS] Failed to acknowledge a Telegram callback query \(callbackQuery.id): \(error.localizedDescription). CONSEQUENCE: the tapped button keeps its loading spinner indefinitely, so the user cannot tell whether their tap registered; the command itself still runs below.")
            }
        }

        // A reply answers the message it replies to, and beats every inference: `reply_to_message` alone says which
        // clarification is answered. Correlation is decided first, but the same tier gate and parser still apply afterwards.
        if let repliedTo = update.message?.reply_to_message?.message_id,
           let text = update.message?.text,
           let operationID = await remoteMirrorService?.operationID(forRemoteMessageID: "\(repliedTo)"),
           // A known verb in the reply box is a command, not an answer (same table as `parse` step 4). `/skip` is not a table verb:
           // it means "answer with nothing", meaningful only for the replied-to operation, so `handleCorrelatedReply` handles it.
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

        // A work-starting command delivered long after it was sent (Telegram keeps a backlog while the Mac sleeps) is skipped
        // and the operator told, never run late.
        if RemoteCommandAge.isAgeGated(command),
           let age = RemoteCommandAge.staleAge(sentAt: RemoteCommandAge.telegramSentAt(update.message?.date)) {
            logger.warning("[CHATOPS] A Telegram \(String(describing: command)) in chat \(chatID) was sent \(Int(age))s ago. CONSEQUENCE: NOT run (older than \(Int(RemoteCommandAge.maxAge))s); the operator is told to send it again.")
            await tell(chatID, RemoteCommandAge.notice(age: age),
                       whenLost: "the operator is not told their old command was skipped, so it looks as if the bot ignored it.")
            return
        }

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
            // Telegram never emits this: it has no modal, so its clarification prompt carries a `ForceReply`. The arm exists because
            // the callback grammar is shared across platforms, and it degrades to an answer rather than going silent.
            await tell(chatID,
                       "Reply to the clarification message with your answer — Telegram has no form dialog.",
                       whenLost: "the user tapped an Answer button that Telegram cannot honour and is told nothing, so the run stays parked with no visible way to answer it.")
        case .clarificationResponse(let text):
            await resolveClarification(text)
        case .freeText(let text):
            await handleFreeText(text, chatID: chatID)
        case .pairingAttempt:
            // Owned elsewhere: `ChatOpsPairingService` polls `getUpdates` itself while unpaired, so this arm posts nothing.
            // Logged at `debug` because it is the expected path, not a drop.
            logger.debug("[CHATOPS/SILENT] A Telegram pairing attempt reached the bridge and was ignored. CONSEQUENCE: none — ChatOpsPairingService owns pairing and answers it on its own polling loop; a reply here would duplicate that.")
        case .unknown:
            // A real drop: reached by a plain message matching no verb and by a button whose callback token fails to parse
            // (a stale button from an old grammar, which Telegram scrollback keeps forever).
            logger.warning("[CHATOPS/SILENT] A Telegram input parsed to `.unknown` in chat \(chatID) and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive; if this was a button tap, its token no longer parses and every copy of that button in scrollback is inert.")
        }
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, chatID: Int64) async {
        // No liveness guard here: `ChatOpsCommandService` holds its host weakly and answers a lost one through `hostLost` /
        // `hostUnavailable`, so the command is refused and the user told instead of vanishing.

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

        // Sends the typing indicator. Failure is deliberately swallowed: it is cosmetic and expires on its own, and logging a
        // line per message would bury the drops that matter.
        _ = try? await apiClient?.sendTypingAction(chatID: chatID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // Single path: same flow as the Mac UI, so HITL banners show and `RemoteMirrorService` mirrors events back.
        // Admission, session registration and submit are one call, `ChatOpsCommandService.submitTurn`.
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


    /// Answers the parked clarification, for a user who types an answer instead of replying to the prompt.
    /// Resolves the oldest clarification parked in the conversation the provider cursor names; a reply is correlated exactly.
    /// The operation id is derived at reply time: a run cancelled in between leaves no pending item to resume.
    private func resolveClarification(_ text: String) async {
        guard let operationID = commands?.pendingClarificationOperationID() else {
            logger.error("[CHATOPS] A clarification answer arrived but no clarification is pending for the bound conversation. CONSEQUENCE: the reply was DROPPED rather than submitted as a new agent turn, and the remote user received no acknowledgement.")
            return
        }
        await remoteMirrorService?.handleClarification(operationID: operationID, text: text)
    }


    /// Routes a reply that `operationID(forRemoteMessageID:)` matched to a parked prompt.
    /// Correlation has decided which operation is meant; this decides whether the user may answer it and whether a typed
    /// answer can. Every arm either resolves the operation or tells the user why it did not.
    private func handleCorrelatedReply(
        operationID: UUID,
        repliedToMessageID: Int,
        text: String,
        chatID: Int64?
    ) async {
        // The same tier gate a typed clarification answer passes: a reply is a `.clarificationResponse`, so replying rather than
        // typing cannot decide whether the tier allows it.
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
            // `/skip` means "answer with nothing", resolved here rather than in the verb table because it is only meaningful for a
            // specific parked prompt; `parse` step 5 makes the same translation for a typed answer.
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
            // Distinct from "wrong kind": the operation is gone (resolved on the Mac, by another provider, or by a race with this
            // reply), so pointing the user at the buttons would send them to a message whose buttons do nothing.
            logger.error("[CHATOPS] A Telegram reply to message \(repliedToMessageID) correlated to operation \(operationID.uuidString), which is no longer pending. CONSEQUENCE: the reply is discarded; the prompt was already resolved on the Mac or by another connected provider, so there is nothing left for it to answer.")
            if let chatID {
                await tell(chatID,
                           "That prompt has already been answered — on the Mac, or from another connected chat. Your reply wasn't needed.",
                           whenLost: "the remote user believes their reply resolved a prompt that something else had already resolved, and will not understand why the run continued without it.")
            }
        }
    }

    // Why: `whenLost` is required, not defaulted, so every call site must state what the user loses if the message never arrives.
    /// Posts a plain-text message that explains something to the remote user, and logs when it does not arrive.
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

    /// Posts a decided view; a failed send is logged rather than swallowed.
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

/// The bridge conforms, not the transport: a transport renders to a destination it is given, while announcing means
/// knowing this provider's own paired channel, which only the bridge knows.
extension ChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .telegram }

    /// Requires a live listener and a paired channel: a stopped or never-paired bridge must announce nothing.
    var canAnnounce: Bool {
        isRunning && config.botToken != nil && config.authorizedChatID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // nil is not a duplicate: an app-wide notification (a finished download) belongs to no conversation,
        // so nothing else reports it.
        guard let conversationID else { return false }
        return remoteMirrorService?.isMirroring(conversationID) ?? false
    }

    func announce(_ view: RemoteView) async -> Bool {
        // Split rather than `.map { String($0) }` inline: Swift cannot parse a trailing closure inside a `guard` condition.
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
