// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  SlackChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Slack ChatOps: routes Socket Mode events through the security gate, parses them into
/// commands, and dispatches them. Free text goes through `ChatOpsCommandService.submitTurn`; `RemoteMirrorService`
/// mirrors events back.
@Observable @MainActor
final class SlackChatOpsBridge {

    private let logger = DGLogger(category: "SlackChatOpsBridge")

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

    /// Which start this is. [LIFE-2] A run compares it on completion to see whether it is still the
    /// one that owns the connection state.
    private var generation: UInt64 = 0

    /// Message identities already run, so one message cannot start two agent runs.
    /// See `SlackEventAdmission` for why this deduplicates rather than filtering on event type.
    private var admission = SlackEventAdmission()

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

        // Refuses a second start (see `ChatOpsBridgeStart.shouldProceed`): `stop()` would kill an in-flight tool approval.
        // Placed after the credential guards so a start that cannot work is reported as a missing token, not a duplicate.
        guard ChatOpsBridgeStart.shouldProceed(isRunning: isRunning, provider: .slack, logger: logger) else { return }

        // The run's own identity, bumped on every start so the trailing block can tell whether it is still the live run.
        generation &+= 1
        let thisGeneration = generation

        isRunning = true

        // The one case where this bridge announces itself unprompted: a pairing without a recorded account is refused by the
        // gate on every message, so the remote user sees a bot that stopped answering. See `ChatOpsUpgradeNotice`.
        if ChatOpsUpgradeNotice.needsRepairing(addressPresent: config.slackAuthorizedChannelID != nil,
                                               authorizedUserID: config.slackAuthorizedUserID),
           ChatOpsUpgradeNotice.claimAnnouncement(for: .slack) {
            Task { [weak self] in
                guard let self else { return }
                guard let channelID = self.config.slackAuthorizedChannelID else { return }
                await self.tell(channelID, ChatOpsUpgradeNotice.message, whenLost: "the remote user is not told WHY the bot stopped answering, so they keep sending commands into a bridge that refuses every one of them and have no way to learn that re-pairing is the fix.")
                self.logger.error("[CHATOPS] Told the paired slack chat that this Mac needs re-pairing: the pairing predates per-sender authorization and records no account. CONSEQUENCE: every remote command is refused until the user re-pairs from Settings — without this notice the bot simply went silent and the user had no way to learn why.")
            }
        }

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await socket.start()
            self.logger.info("SlackChatOpsBridge started — listening for Slack events.")

            for await event in stream {
                await self.handleSocketEvent(event)
            }

            // See the twin in `ChatOpsBridge.start()`: only the socket client knows whether the stream ended because `stop()` was
            // called or because Slack will never accept this token again.
            let terminalFailure = await socket.terminalFailure

            await MainActor.run {
                let isOwner = self.generation == thisGeneration
                if isOwner { self.isRunning = false }
                ChatOpsBridgeShutdown.report(terminalFailure: terminalFailure,
                                             provider: .slack,
                                             isOwner: isOwner,
                                             logger: self.logger) { self.config.slackConnectionState = $0 }
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

        // Releases what this run owned: a stopped bridge must not keep a live API client or, through `ChatOpsCommandService`, a
        // strong reference to the main view model, which would defeat the `weak var viewModel`.
        apiClient = nil
        socketClient = nil
        slackTransport = nil
        commands = nil
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

    /// Slack subtypes that are channel housekeeping rather than something a person said to the bot. Anything not listed is
    /// routed (see `handleMessage`); adding a subtype here deliberately ignores it.
    private static let housekeepingSubtypes: Set<String> = [
        "bot_message", "message_changed", "message_deleted", "message_replied", "tombstone",
        "channel_join", "channel_leave", "channel_topic", "channel_purpose", "channel_name",
        "channel_archive", "channel_unarchive", "group_join", "group_leave",
    ]

    private func handleMessage(_ event: SlackEvent) async {
        // The bot's own echo is deliberately unlogged: this bridge posts constantly and a line per echo would bury real drops.
        guard event.bot_id == nil else { return }

        // An ignore-list, not `subtype == nil`: `file_share` (a message typed with a file attached) must reach the routing
        // switch. An unmodelled subtype is routed and at worst logged, rather than silently dropped.
        if let subtype = event.subtype, Self.housekeepingSubtypes.contains(subtype) { return }

        guard let channelID = event.channel else {
            logger.warning("[CHATOPS/SILENT] A Slack '\(event.type)' event arrived with no channel id and was dropped. CONSEQUENCE: it cannot be routed and cannot even be answered, because there is nowhere to post a reply — if this was a command, the operator sees the bot ignore them with no explanation anywhere.")
            return
        }
        guard let text = event.text else {
            logger.warning("[CHATOPS/SILENT] A Slack '\(event.type)' event in channel \(channelID) carried no text and was dropped. CONSEQUENCE: nothing is routed and nothing is posted back. A message whose content is entirely an attachment lands here, so an operator sending a file with no caption sees silence.")
            return
        }

        // One message, one run; see `admitOnce`.
        guard admitOnce(event, channelID: channelID) else { return }

        // Security gate
        let authorization = await securityGate.authorizeSlack(channelID: channelID,
                                                senderID: event.user,
                                                config: config)
        if case .refused(let refusal) = authorization {
            // The one refusal the operator is owed: other arms stay silent (answering an unpaired room confirms a Mac is
            // listening), but a throttled sender has already proved they are the paired operator.
            if refusal.mayReply, ChatOpsThrottleNotice.claim(for: .slack),
               case .rateLimited(let retry) = refusal.reason {
                await tell(channelID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }

        // Parse command
        let command = ChatOpsCommand.parseSlack(
            text: text,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier(for: .slack)) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .slack))
            let tierName = config.securityTier(for: .slack).rawValue
            logger.error("[CHATOPS] A Slack \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        // A work-starting command redelivered long after it was sent is skipped, not run late.
        if RemoteCommandAge.isAgeGated(command),
           let age = RemoteCommandAge.staleAge(sentAt: RemoteCommandAge.slackSentAt(event.ts)) {
            logger.warning("[CHATOPS] A Slack \(String(describing: command)) in channel \(channelID) was sent \(Int(age))s ago. CONSEQUENCE: NOT run (older than \(Int(RemoteCommandAge.maxAge))s); the operator is told to send it again.")
            await tell(channelID, RemoteCommandAge.notice(age: age),
                       whenLost: "the operator is not told their old command was skipped, so it looks as if the bot ignored it.")
            return
        }

        await routeCommand(command, channelID: channelID)
    }


    /// Whether this event is the first delivery of its message, logging the reason when it is not. Slack sends one envelope
    /// per matching subscription (`app_mention` and `message.channels`), so messages are deduplicated rather than
    /// type-filtered; see `SlackEventAdmission`.
    private func admitOnce(_ event: SlackEvent, channelID: String) -> Bool {
        switch admission.admit(type: event.type, channel: channelID, ts: event.ts) {
        case .admit:
            return true
        case .duplicate(let key, let type):
            logger.info("[CHATOPS] Ignored a repeat delivery of Slack message \(key) arriving as '\(type)'. CONSEQUENCE: the prompt runs ONCE — this is the copy Slack sends for a second matching event subscription, or a redelivery of an envelope that was not acked in time.")
            return false
        case .admitUnidentified(let type):
            logger.error("[CHATOPS] A Slack '\(type)' event carried no `ts`, so it cannot be identified. CONSEQUENCE: it is handled anyway — refusing it would make the bot go deaf for an event shape this build does not model — but it cannot be deduplicated, so a second delivery of the same message would run twice.")
            return true
        }
    }

    // MARK: - Interaction Handling

    /// The modal's identifiers. Fixed, because only the OPERATION needs to travel — and it travels
    /// in `private_metadata`, not in these.
    private static let clarificationCallbackID = "clarification_answer"
    private static let clarificationBlockID = "answer_block"
    private static let clarificationFieldID = "answer"

    private func handleInteraction(_ payload: SlackInteractivePayload) async {
        // Route by payload type first: a `view_submission` has no `actions` array and must not fall into the block-actions
        // guard.
        if payload.type == SlackInteractivePayload.viewSubmission {
            await resolveClarificationModal(payload)
            return
        }

        guard let action = payload.actions?.first else {
            logger.error("[CHATOPS] A Slack interactive payload of type \(payload.type) carried no action and is not a view submission. CONSEQUENCE: it is ignored — but this line names the type, so an unsupported interaction is findable instead of vanishing the way view submissions used to.")
            return
        }
        // `originChannelID` is evidence for the allowlist check and `replyChannelID` is only an address; using the authorized
        // id as a fallback for evidence would make the guard compare it with itself.
        let originChannelID = payload.channel?.id
        let replyChannelID = payload.channel?.id ?? config.slackAuthorizedChannelID ?? ""

        // Parse action_id using the same callback data format
        let command = ChatOpsCommand.parseSlack(actionID: action.action_id)

        // Button taps pass the same channel-authorization and tier gate as slash commands. No fallback: a payload without a
        // channel is refused; view submissions are routed to `resolveClarificationModal` above.
        guard let originChannelID else {
            logger.error("[CHATOPS] A Slack \(payload.type) payload carried no channel, so it cannot be matched against the channel allowlist. CONSEQUENCE: it is refused. Previously the authorized channel id was substituted here, which made the allowlist compare that id with itself and admit the interaction unchecked.")
            return
        }
        let authorization = await securityGate.authorizeSlack(channelID: originChannelID,
                                                senderID: payload.user?.id,
                                                config: config)
        if case .refused(let refusal) = authorization {
            // The one refusal the operator is owed: other arms stay silent (answering an unpaired room confirms a Mac is
            // listening), but a throttled sender has already proved they are the paired operator.
            if refusal.mayReply, ChatOpsThrottleNotice.claim(for: .slack),
               case .rateLimited(let retry) = refusal.reason {
                await tell(originChannelID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }
        guard await securityGate.canExecute(command, tier: config.securityTier(for: .slack)) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .slack))
            let tierName = config.securityTier(for: .slack).rawValue
            logger.error("[CHATOPS] A Slack button \(String(describing: command)) from channel \(replyChannelID) was refused by the \(tierName) security tier. CONSEQUENCE: the tap did nothing; without this line a tier refusal left no trace at all.")
            await tell(replyChannelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        // The modal must be opened from this payload: only it carries the `trigger_id`, which expires in about three seconds.
        if case .answerClarification(let operationID) = command {
            await openClarificationModal(operationID: operationID, payload: payload, channelID: replyChannelID)
            return
        }

        // Delegates to the service so a button and a slash command reach the same decision for a shared verb.
        if await routeThroughService(command, channelID: replyChannelID) { return }

        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        default:
            // Reached by an `action_id` that parses to `.unknown` (a malformed token or a button from a superseded grammar still in
            // scrollback); logged so orphaned buttons are visible in the field.
            logger.warning("[CHATOPS/SILENT] A Slack button \(String(describing: command)) was dropped after both gates passed. CONSEQUENCE: the tap changed nothing and produced no reply; its callback token no longer parses, so every copy of that button in scrollback is inert.")
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
            // The operation travels in `private_metadata`: a modal is not in a channel, so a submission carries no `channel` to
            // infer it from.
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

        // Tier only, not the channel allowlist: a submission has no channel, and the channel gate already ran when the opening
        // button was tapped; the tier gate is about the act itself.
        guard await securityGate.canExecute(.answerClarification(operationID: operationID),
                                            tier: config.securityTier(for: .slack)) else {
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

        let authorization = await securityGate.authorizeSlack(channelID: channelID,
                                                senderID: payload.user_id,
                                                config: config)
        if case .refused(let refusal) = authorization {
            // The one refusal the operator is owed: other arms stay silent (answering an unpaired room confirms a Mac is
            // listening), but a throttled sender has already proved they are the paired operator.
            if refusal.mayReply, ChatOpsThrottleNotice.claim(for: .slack),
               case .rateLimited(let retry) = refusal.reason {
                await tell(channelID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }

        // `payload.text` is the argument Slack sends after the command name; it is passed so argument-taking verbs keep their
        // argument.
        let command = ChatOpsCommand.parseSlack(
            slashCommand: payload.command,
            slashArgument: payload.text)

        guard await securityGate.canExecute(command, tier: config.securityTier(for: .slack)) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .slack))
            let tierName = config.securityTier(for: .slack).rawValue
            logger.error("[CHATOPS] A Slack slash command \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Command Routing

    /// One decision, one address: Slack has no interaction-reply destination wired (`response_url` is decoded but unused),
    /// so every view goes to the channel. - Returns: whether the command was one the service owns.
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

    /// Answers the parked clarification, derived at the moment of the reply and never remembered from when the prompt was
    /// sent.
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


    /// Posts a plain-text message that explains something to the remote user, and logs when it does not arrive. `whenLost`
    /// is required, not defaulted, so every call site states what the user loses if the message is dropped.
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
            // Unreachable by design: the button and the submission are intercepted in `handleInteraction` before routing, so
            // reaching here means an intercept is missing and the button would silently do nothing.
            logger.error("[CHATOPS] A Slack `.answerClarification(\(operationID))` reached routeCommand, which should be impossible: the modal intercept in handleInteraction runs first. CONSEQUENCE: the Answer button did nothing and the run stays parked.")
        case .pairingAttempt:
            // A well-formed PIN arriving outside a pairing window (pairing services run their own poll loops), usually a re-sent
            // code; named explicitly so it is not reported as an unknown-command drop.
            logger.info("[CHATOPS] A pairing PIN arrived with no pairing window open. CONSEQUENCE: it is ignored — pairing is already complete, or the window expired and the user must start it again from Settings.")

        default:
            // Not 'handled elsewhere' for every case: `.unknown` genuinely ends here, from a message matching no verb or an unknown
            // slash command.
            logger.warning("[CHATOPS/SILENT] A Slack \(String(describing: command)) reached the end of routeCommand and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive.")
        }
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, channelID: String) async {
        // No liveness guard here: `ChatOpsCommandService` holds its host weakly and answers a lost one through `hostLost` /
        // `hostUnavailable`, so the command is refused and the user is told.

        guard let conversationID = config.slackActiveConversationID else {
            await tell(channelID,
                       "No active conversation. Use /conversations to pick one or /new to create one.",
                       whenLost: "the user is not told their prompt was dropped for want of an active conversation, so they wait for an answer that is never coming.")
            return
        }

        guard let commands, let profile = commands.profile(boundTo: conversationID) else {
            await tell(channelID, "⚠️ No agent profile found for this conversation.",
                       whenLost: "the user is not told their prompt was dropped because the conversation resolves to no backend profile, so they wait for an answer that is never coming.")
            return
        }

        let requestConfig = BackendRequestConfig(profile: profile)

        // `submitTurn` bundles admission, mirror registration and submit so bridges cannot order them differently; the
        // transport is resolved inside the closure so a missing one tells the user instead of dropping silently.
        let admission = commands.submitTurn(
            prompt: text,
            conversationID: conversationID,
            source: .slack,
            config: requestConfig,
            attachMirror: { [weak self] in
                guard let self,
                      let transport = self.slackTransport,
                      let mirror = self.remoteMirrorService else { return false }
                mirror.registerSession(
                    conversationID: conversationID,
                    info: RemoteSessionInfo(transport: transport, chatID: channelID, source: .slack)
                )
                return true
            }
        )

        if case .refused(let message, let consequence) = admission {
            await tell(channelID, message, whenLost: consequence)
        }
    }

}

// MARK: - Announcing (slice 3)

/// The bridge conforms, not the transport: announcing needs this provider's own paired channel, which only the bridge
/// knows.
extension SlackChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .slack }

    /// Requires a live listener and a paired channel, so a stopped or never-paired bridge announces nothing.
    var canAnnounce: Bool {
        isRunning && config.slackBotToken != nil && config.slackAuthorizedChannelID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // nil is not a duplicate: an app-wide notification (a finished download) belongs to no conversation, so nothing else is
        // reporting it.
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
