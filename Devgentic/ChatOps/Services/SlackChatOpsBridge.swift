// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  SlackChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Slack ChatOps.
///
/// Routes incoming Slack Socket Mode events through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler.
///
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class SlackChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "SlackChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: SlackAPIClient?
    private var socketClient: SlackSocketClient?
    private let securityGate = ChatOpsSecurityGate()
    private var slackTransport: SlackTransport?

    /// [C7] Decides what every verb shows. Provider-scoped to `.slack`, so it reads and writes the
    /// SLACK conversation cursor.
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

    func start() {
        guard let botToken = config.slackBotToken, !botToken.isEmpty,
              let appToken = config.slackAppToken, !appToken.isEmpty else {
            logger.warning("Cannot start SlackChatOpsBridge — missing bot or app token.")
            return
        }

        let client = SlackAPIClient(botToken: botToken)
        let socket = SlackSocketClient(appToken: appToken)
        let transport = SlackTransport(apiClient: client)

        self.apiClient = client
        self.socketClient = socket
        self.slackTransport = transport

        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        if let vm = viewModel {
            self.commands = ChatOpsCommandService(
                provider: .slack,
                runControl: vm,
                commanding: vm,
                conversations: ChatPersistenceStore.shared
            )
        }

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await socket.start()
            self.logger.info("SlackChatOpsBridge started — listening for Slack events.")

            for await event in stream {
                await self.handleSocketEvent(event)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("SlackChatOpsBridge stopped.")
            }
        }
    }

    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await socketClient?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("SlackChatOpsBridge stopped.")
    }

    // MARK: - Event Routing

    private func handleSocketEvent(_ event: SlackSocketEvent) async {
        switch event {
        case .connected:
            logger.info("Slack Socket Mode connected.")

        case .message(let slackEvent):
            await handleMessage(slackEvent)

        case .interaction(let payload):
            await handleInteraction(payload)

        case .slashCommand(let payload):
            await handleSlashCommand(payload)

        case .disconnected(let error):
            if let error {
                logger.error("Slack Socket disconnected: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ event: SlackEvent) async {
        // Ignore bot messages
        guard event.bot_id == nil, event.subtype == nil else { return }
        guard let channelID = event.channel, let text = event.text else { return }

        // Security gate
        guard await securityGate.authorizeSlack(channelID: channelID, config: config) else { return }

        // Parse command
        let command = ChatOpsCommand.parseSlack(
            text: text,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            let tierName = config.securityTier.rawValue
            logger.error("[CHATOPS] A Slack \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Interaction Handling

    /// The modal's identifiers. Fixed, because only the OPERATION needs to travel — and it travels
    /// in `private_metadata`, not in these.
    private static let clarificationCallbackID = "clarification_answer"
    private static let clarificationBlockID = "answer_block"
    private static let clarificationFieldID = "answer"

    private func handleInteraction(_ payload: SlackInteractivePayload) async {
        // ⚠️ ROUTE BY PAYLOAD TYPE FIRST. A `view_submission` has no `actions` array, so the
        // `guard let action = payload.actions?.first else { return }` below used to drop every
        // modal submission on its first line — silently, with no log, so the user's typed answer
        // disappeared and nothing recorded that it had ever arrived.
        if payload.type == SlackInteractivePayload.viewSubmission {
            await resolveClarificationModal(payload)
            return
        }

        guard let action = payload.actions?.first else {
            logger.error("[CHATOPS] A Slack interactive payload of type \(payload.type) carried no action and is not a view submission. CONSEQUENCE: it is ignored — but this line names the type, so an unsupported interaction is findable instead of vanishing the way view submissions used to.")
            return
        }
        // ⚠️⚠️ TWO DIFFERENT QUESTIONS, AND ONE VARIABLE USED TO ANSWER BOTH — the same defect
        // Discord's `handleInteraction` carried. This was
        // `payload.channel?.id ?? config.slackAuthorizedChannelID ?? ""` feeding BOTH the allowlist
        // check and the reply address. As an address the fallback is harmless; as evidence it was a
        // BYPASS, because `authorizeSlack` compares its argument against `slackAuthorizedChannelID`
        // — so substituting that value made the guard compare the authorized id with itself and
        // pass unconditionally. A payload with no channel was authorized by construction.
        let originChannelID = payload.channel?.id
        let replyChannelID = payload.channel?.id ?? config.slackAuthorizedChannelID ?? ""

        // Parse action_id using the same callback data format
        let command = ChatOpsCommand.parseSlack(actionID: action.action_id)

        // [D1] Security: button taps must pass the same channel-authorization + tier gate as slash
        // commands. This path previously bypassed BOTH — a HITL approve/deny/gate button could resolve
        // below the .full tier or from an unauthorized channel.
        //
        // ⚠️ NO FALLBACK HERE. A `block_actions` payload from a message always names its channel;
        // one that does not cannot be matched against the allowlist, so it is refused rather than
        // admitted. View submissions are the genuine no-channel case and never reach this line —
        // they are routed to `resolveClarificationModal` above, which documents its own exemption.
        guard let originChannelID else {
            logger.error("[CHATOPS] A Slack \(payload.type) payload carried no channel, so it cannot be matched against the channel allowlist. CONSEQUENCE: it is refused. Previously the authorized channel id was substituted here, which made the allowlist compare that id with itself and admit the interaction unchecked.")
            return
        }
        guard await securityGate.authorizeSlack(channelID: originChannelID, config: config) else { return }
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            let tierName = config.securityTier.rawValue
            logger.error("[CHATOPS] A Slack button \(String(describing: command)) from channel \(replyChannelID) was refused by the \(tierName) security tier. CONSEQUENCE: the tap did nothing; without this line a tier refusal left no trace at all.")
            await tell(replyChannelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        // ⚠️ The modal must be opened from THIS payload, because only it carries the `trigger_id`
        // — which expires in about three seconds and cannot be reused.
        if case .answerClarification(let operationID) = command {
            await openClarificationModal(operationID: operationID, payload: payload, channelID: replyChannelID)
            return
        }

        // ⚠️ This switch used to duplicate `.switchConversation` and `.newConversation`, which
        // `routeCommand` also handled — two arms for one verb, the shape that lets renderings drift.
        // Delegating means a button and a slash command reach the same decision.
        if await routeThroughService(command, channelID: replyChannelID) { return }

        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        default:
            // ⚠️ A TAP THAT DIED HERE LEFT NO TRACE AT ALL. It is reached by an `action_id` that
            // parses to `.unknown` — a malformed token, or any button from a superseded callback
            // grammar still sitting in Slack scrollback, which Slack keeps indefinitely. The user
            // taps, the message does not change, and no line records that taps are arriving and
            // dying, so a grammar change that orphans old buttons is invisible in the field.
            logger.info("[CHATOPS/SILENT] A Slack button \(String(describing: command)) was dropped after both gates passed. CONSEQUENCE: the tap changed nothing and produced no reply; its callback token no longer parses, so every copy of that button in scrollback is inert.")
        }
    }

    /// Opens the free-text modal for a parked clarification.
    private func openClarificationModal(operationID: UUID, payload: SlackInteractivePayload, channelID: String) async {
        guard let triggerID = payload.trigger_id else {
            logger.error("[CHATOPS] A Slack answer button arrived with no trigger_id, so no modal can be opened for clarification \(operationID). CONSEQUENCE: the user is told to type in the channel instead of tapping a button that does nothing.")
            await tell(channelID, "Type your answer in this channel — the form could not be opened.",
                       whenLost: "the user is left with a button that did nothing and no instruction to type instead, so the run stays parked with no route to answer it.")
            return
        }

        let view = SlackModalView(
            callbackID: Self.clarificationCallbackID,
            // ⚠️ THE OPERATION TRAVELS HERE. A modal is not in a channel, so a submission carries no
            // `channel` to infer anything from; `private_metadata` is the one field that goes out
            // with the view and comes back untouched.
            privateMetadata: CallbackToken.answerClarification(operationID: operationID).wire,
            title: "Answer the agent",
            blocks: [
                SlackInputBlock(
                    blockID: Self.clarificationBlockID,
                    label: "Your answer",
                    element: SlackPlainTextInput(
                        actionID: Self.clarificationFieldID,
                        placeholder: "Type your answer…"
                    )
                )
            ]
        )

        do {
            try await apiClient?.openView(triggerID: triggerID, view: view)
            logger.info("[CHATOPS] Opened a Slack answer modal for clarification \(operationID).")
        } catch {
            logger.error("[CHATOPS] Failed to open the Slack answer modal for clarification \(operationID): \(error.localizedDescription). CONSEQUENCE: the button appears to do nothing, the run stays parked, and typing in the channel is the only route left.")
        }
    }

    /// Resolves a clarification from a submitted modal.
    private func resolveClarificationModal(_ payload: SlackInteractivePayload) async {
        guard let metadata = payload.view?.private_metadata,
              case .answerClarification(let operationID) = ChatOpsCommand.parseCallbackData(metadata) else {
            logger.error("[CHATOPS] A Slack view submission carried private_metadata \(payload.view?.private_metadata ?? "nil"), which names no parked clarification. CONSEQUENCE: the typed answer is DROPPED and the run stays parked; this is what a modal outliving a grammar change looks like.")
            return
        }

        // ⚠️ TIER ONLY, NOT THE CHANNEL ALLOWLIST. A submission has no channel to check — the modal
        // is not in one — and the channel gate already ran when the button that opened it was
        // tapped. The tier gate still applies because it is about the ACT, not about where it began.
        guard await securityGate.canExecute(.answerClarification(operationID: operationID),
                                            tier: config.securityTier) else {
            logger.error("[CHATOPS] A Slack modal answer for clarification \(operationID) was refused by the security tier. CONSEQUENCE: the run stays parked and the answer is discarded.")
            return
        }

        let answer = payload.submittedValue(
            blockID: Self.clarificationBlockID,
            actionID: Self.clarificationFieldID
        ) ?? ""

        logger.info("[CHATOPS] A Slack modal resolved clarification \(operationID) by correlation rather than by the conversation cursor (\(answer.count) characters).")
        await remoteMirrorService?.handleClarification(operationID: operationID, text: answer)
    }

    // MARK: - Slash Command Handling

    private func handleSlashCommand(_ payload: SlackSlashCommandPayload) async {
        let channelID = payload.channel_id

        guard await securityGate.authorizeSlack(channelID: channelID, config: config) else { return }

        // ⚠️ `payload.text` is the argument Slack sends after the command name. It was decoded and
        // never read, so an argument-taking slash verb arrived stripped of its argument.
        let command = ChatOpsCommand.parseSlack(
            slashCommand: payload.command,
            slashArgument: payload.text)

        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            let tierName = config.securityTier.rawValue
            logger.error("[CHATOPS] A Slack slash command \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Command Routing

    /// ⚠️ ONE DECISION, ONE ADDRESS. Unlike Discord, Slack has no interaction-reply destination
    /// wired: `response_url` is decoded on both the interactive and slash payloads
    /// (`SlackModels.swift:89`, `:111`) and read nowhere, so every view goes to the channel. Adding
    /// that destination is a real feature — it would make tier denials and `/status` ephemeral
    /// instead of public — but it is not this commit, whose job is to change nothing.
    ///
    /// - Returns: whether the command was one the service owns.
    private func routeThroughService(_ command: ChatOpsCommand, channelID: String) async -> Bool {
        let destination = RemoteDestination.channel(RemoteChannel(provider: .slack, channelID: channelID))
        switch command {
        case .conversations:
            await render(commands?.conversationList(offset: 0), to: destination)
        case .conversationPage(let offset):
            await render(commands?.conversationList(offset: offset), to: destination)
        case .searchConversations(let query):
            await render(commands?.searchConversations(query: query), to: destination)
        case .conversationHistory(let argument):
            await render(commands?.conversationHistory(argument: argument), to: destination)
        case .newConversation:
            await render(commands?.newConversation(), to: destination)
        case .status:
            await render(commands?.status(), to: destination)
        case .cancel:
            await render(await commands?.cancelRun(), to: destination)
        case .help:
            await render(commands?.help(), to: destination)
        case .switchConversation(let uuid):
            await render(commands?.switchConversation(to: uuid), to: destination)
        case .profiles:
            await render(commands?.profileList(), to: destination)
        case .selectProfile(let profileID):
            await render(commands?.selectProfile(profileID), to: destination)
        case .useProfile(let profileName):
            await render(commands?.useProfile(named: profileName), to: destination)
        default:
            return false
        }
        return true
    }

    /// [C8] Answers the parked clarification. ⚠️ Derived at the moment of the reply, never
    /// remembered from when the prompt was sent.
    private func resolveClarification(_ text: String) async {
        guard let operationID = commands?.pendingClarificationOperationID() else {
            logger.error("[CHATOPS] A clarification answer arrived but no clarification is pending for the bound conversation. CONSEQUENCE: the reply was DROPPED rather than submitted as a new agent turn, and the remote user received no acknowledgement.")
            return
        }
        await remoteMirrorService?.handleClarification(operationID: operationID, text: text)
    }

    /// [C7] Posts a decided view. A failure is LOGGED rather than swallowed by `try?`.
    private func render(_ view: RemoteView?, to destination: RemoteDestination) async {
        guard let view else {
            logger.error("[CHATOPS] A Slack command produced no view because the command service was never built — start() ran without a view model. CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        guard let transport = slackTransport else {
            logger.error("[CHATOPS] No Slack transport while rendering a view. CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        do {
            try await transport.render(view, to: destination)
        } catch {
            logger.error("[CHATOPS] Failed to render a view to Slack: \(error.localizedDescription). CONSEQUENCE: the remote user receives NO reply for a command that succeeded locally.")
        }
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
    private func tell(_ channelID: String, _ text: String, whenLost consequence: String) async {
        guard let apiClient else {
            logger.error("[CHATOPS] No Slack API client while telling the user: \"\(text.prefix(60))\". CONSEQUENCE: \(consequence)")
            return
        }
        do {
            _ = try await apiClient.postMessage(channel: channelID, text: RemoteEgressSanitizer.credentialsOnly(text))
        } catch {
            logger.error("[CHATOPS] Failed to tell the Slack user \"\(text.prefix(60))\": \(error.localizedDescription). CONSEQUENCE: \(consequence)")
        }
    }

    private func routeCommand(_ command: ChatOpsCommand, channelID: String) async {
        if await routeThroughService(command, channelID: channelID) { return }
        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        case .clarificationResponse(let text):
            await resolveClarification(text)
        case .freeText(let text):
            await handleFreeText(text, channelID: channelID)
        case .answerClarification(let operationID):
            // ⚠️ UNREACHABLE BY DESIGN, and named rather than defaulted so it says so. The button is
            // intercepted in `handleInteraction` before routing — the modal must be opened from the
            // payload that carries the `trigger_id`, which expires in seconds — and the submission
            // is intercepted alongside it. Reaching here means an intercept was removed, and the
            // symptom would be a button that silently does nothing: the exact failure this switch's
            // `default: break` once produced for `switch:`.
            //
            // ⚠️ THIS ARM PREVIOUSLY POSTED "form dialogs are not available here yet", which was
            // true for exactly one slice. `views.open` landed; the copy would otherwise have gone
            // on telling users to type their answer at a modal that works.
            logger.error("[CHATOPS] A Slack `.answerClarification(\(operationID))` reached routeCommand, which should be impossible: the modal intercept in handleInteraction runs first. CONSEQUENCE: the Answer button did nothing and the run stays parked.")
        default:
            // ⚠️ NOT "HANDLED ELSEWHERE" FOR EVERY CASE — `.unknown` genuinely ends here, from a
            // message that matched no verb or a slash command this build does not know.
            logger.info("[CHATOPS/SILENT] A Slack \(String(describing: command)) reached the end of routeCommand and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive.")
        }
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, channelID: String) async {
        guard let vm = viewModel else { return }

        guard let conversationID = config.slackActiveConversationID else {
            await tell(channelID,
                       "No active conversation. Use /conversations to pick one or /new to create one.",
                       whenLost: "the user is not told their prompt was dropped for want of an active conversation, so they wait for an answer that is never coming.")
            return
        }

        guard let profile = commands?.profile(boundTo: conversationID) else {
            await tell(channelID, "⚠️ No agent profile found for this conversation.",
                       whenLost: "the user is not told their prompt was dropped because the conversation resolves to no backend profile, so they wait for an answer that is never coming.")
            return
        }

        let requestConfig = BackendRequestConfig(profile: profile)

        guard let transport = slackTransport else { return }

        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: transport,
                chatID: channelID,
                source: .slack
            )
        )

        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .slack,
            config: requestConfig
        )
    }

}

// MARK: - Announcing (slice 3)

/// ⚠️ The BRIDGE conforms, not the transport: a transport renders to a destination it is given,
/// while announcing means knowing this provider's OWN paired channel. Only the bridge knows both.
extension SlackChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .slack }

    /// ⚠️ Requires a live listener AND a paired channel. A bridge that was stopped, or was never
    /// paired, must announce nothing — otherwise a notification would be addressed to a channel the
    /// user has disconnected.
    var canAnnounce: Bool {
        isRunning && config.slackBotToken != nil && config.slackAuthorizedChannelID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // ⚠️ nil is NOT a duplicate: an app-wide notification (a finished download) belongs to no
        // conversation, so nothing is already reporting it.
        guard let conversationID else { return false }
        return remoteMirrorService?.isMirroring(conversationID) ?? false
    }

    func announce(_ view: RemoteView) async -> Bool {
        guard let transport = slackTransport, let channelID = config.slackAuthorizedChannelID else {
            logger.error("[CHATOPS] Cannot announce on \(self.provider.rawValue) — no transport or no paired channel. CONSEQUENCE: this notification reaches the Mac only, and the remote user is never told.")
            return false
        }
        do {
            try await transport.render(view, to: .channel(RemoteChannel(provider: provider, channelID: channelID)))
        } catch {
            logger.error("[CHATOPS] Failed to announce on \(self.provider.rawValue): \(error.localizedDescription). CONSEQUENCE: the notification is lost — announcements are fire-and-forget and nothing retries them.")
            return false
        }
        return true
    }
}
