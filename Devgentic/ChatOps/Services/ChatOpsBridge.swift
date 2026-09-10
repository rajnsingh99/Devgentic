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
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class ChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "ChatOpsBridge")

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

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await telegramListener.start()
            self.logger.info("ChatOpsBridge started — listening for Telegram updates.")

            for await update in stream {
                await self.handleUpdate(update)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("ChatOpsBridge stopped.")
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
    }

    // MARK: - Update Routing

    private func handleUpdate(_ update: TelegramUpdate) async {
        // 1. Security gate
        guard await securityGate.authorize(update, config: config) else { return }

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
        if let repliedTo = update.message?.reply_to_message?.message_id,
           let text = update.message?.text,
           let operationID = await remoteMirrorService?.operationID(forRemoteMessageID: "\(repliedTo)") {
            logger.info("[CHATOPS] A Telegram reply to message \(repliedTo) resolved clarification \(operationID) by correlation rather than by the conversation cursor.")
            await remoteMirrorService?.handleClarification(operationID: operationID, text: text)
            return
        }

        // 3. Parse command
        let command = ChatOpsCommand.parse(
            text: update.message?.text,
            callbackData: update.callback_query?.data,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // 4. Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            if let chatID = update.chatID {
                let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
                let tierName = config.securityTier.rawValue
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
            logger.info("[CHATOPS/SILENT] A Telegram input parsed to `.unknown` in chat \(chatID) and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive; if this was a button tap, its token no longer parses and every copy of that button in scrollback is inert.")
        }
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, chatID: Int64) async {
        guard let vm = viewModel else { return }

        // Ensure there's an active conversation
        guard let conversationID = config.activeConversationID else {
            await tell(chatID,
                       "No active conversation. Use /conversations to pick one or /new to create one.",
                       whenLost: "the user is not told their prompt was dropped for want of an active conversation, so they wait for an answer that is never coming.")
            return
        }

        // Resolve the backend profile for this conversation
        guard let profile = commands?.profile(boundTo: conversationID) else {
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

        // Single-path architecture: route through the SAME flow as Mac UI.
        // The RemoteMirrorService will observe the stream and mirror events back to Telegram.
        // Register the remote session so the mirror service knows where to send responses.
        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: telegramTransport!,
                chatID: "\(chatID)",
                source: .telegram
            )
        )

        // Submit through the main app flow — message appears in Mac UI, agent runs,
        // HITL banners show, and RemoteMirrorService handles the Telegram response.
        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .telegram,
            config: requestConfig
        )
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
