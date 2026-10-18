// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  DiscordChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Discord ChatOps: routes Gateway events through the security gate and dispatches
/// commands.
/// Free text goes through `ChatOpsCommandService.submitTurn` (admission, mirror registration, submit).
@Observable @MainActor
final class DiscordChatOpsBridge {

    private let logger = DGLogger(category: "DiscordChatOpsBridge")

    // MARK: - Dependencies

    private weak var viewModel: MainApplicationViewModel?
    private var apiClient: DiscordAPIClient?
    private var gatewayClient: DiscordGatewayClient?
    private let securityGate = ChatOpsSecurityGate()
    private var discordTransport: DiscordTransport?

    /// [C6] Decides what every verb shows. Provider-scoped to `.discord`, so it reads and writes the
    /// DISCORD conversation cursor rather than Telegram's.
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

    /// Starts the Discord Gateway connection and begins processing events.
    func start() {
        guard let token = config.discordBotToken, !token.isEmpty else {
            logger.warning("Cannot start DiscordChatOpsBridge — no bot token configured.")
            return
        }

        let client = DiscordAPIClient(botToken: token)
        let gateway = DiscordGatewayClient(botToken: token)
        let transport = DiscordTransport(apiClient: client)

        self.apiClient = client
        self.gatewayClient = gateway
        self.discordTransport = transport

        // Create RemoteMirrorService if ViewModel provides ActiveStreamManager
        if let asm = viewModel?.activeStreamManager {
            self.remoteMirrorService = RemoteMirrorService(activeStreamManager: asm)
        }

        if let vm = viewModel {
            self.commands = ChatOpsCommandService(
                provider: .discord,
                runControl: vm,
                commanding: vm,
                conversations: ChatPersistenceStore.shared
            )
        }

        // Refuses a second start (see `ChatOpsBridgeStart.shouldProceed`), placed after the credential guards so bad
        // config is reported first.
        guard ChatOpsBridgeStart.shouldProceed(isRunning: isRunning, provider: .discord, logger: logger) else { return }

        // The run's own identity, bumped on every start so the trailing block can tell whether it is still the live run.
        generation &+= 1
        let thisGeneration = generation

        isRunning = true

        // The one case where this bridge announces itself unprompted: a pre-authorization pairing is refused silently (see
        // `ChatOpsUpgradeNotice`).
        if ChatOpsUpgradeNotice.needsRepairing(addressPresent: config.discordAuthorizedChannelID != nil,
                                               authorizedUserID: config.discordAuthorizedUserID),
           ChatOpsUpgradeNotice.claimAnnouncement(for: .discord) {
            Task { [weak self] in
                guard let self else { return }
                guard let channelID = self.config.discordAuthorizedChannelID else { return }
                await self.tell(channelID, ChatOpsUpgradeNotice.message, whenLost: "the remote user is not told WHY the bot stopped answering, so they keep sending commands into a bridge that refuses every one of them and have no way to learn that re-pairing is the fix.")
                self.logger.error("[CHATOPS] Told the paired discord chat that this Mac needs re-pairing: the pairing predates per-sender authorization and records no account. CONSEQUENCE: every remote command is refused until the user re-pairs from Settings — without this notice the bot simply went silent and the user had no way to learn why.")
            }
        }

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await gateway.start()
            self.logger.info("DiscordChatOpsBridge started — listening for Discord events.")

            for await event in stream {
                await self.handleGatewayEvent(event)
            }

            // Reports a terminal gateway failure (revoked token, intents refusal) as a failed Settings state, as the other
            // bridges do.
            let terminalFailure = await gateway.terminalFailure

            await MainActor.run {
                let isOwner = self.generation == thisGeneration
                if isOwner { self.isRunning = false }
                ChatOpsBridgeShutdown.report(terminalFailure: terminalFailure,
                                             provider: .discord,
                                             isOwner: isOwner,
                                             logger: self.logger) { self.config.discordConnectionState = $0 }
            }
        }
    }

    /// Stops the Gateway connection and cleans up.
    func stop() {
        listeningTask?.cancel()
        listeningTask = nil

        Task {
            await gatewayClient?.stop()
        }

        // [D2] Detach the mirror service so a stopped transport stops mirroring, then drop the strong ref.
        remoteMirrorService?.teardown()
        remoteMirrorService = nil

        isRunning = false
        logger.info("DiscordChatOpsBridge stopped.")

        // Releases everything this run owned; a stopped bridge must not hold a live API client or a strong reference to
        // the view model.
        apiClient = nil
        gatewayClient = nil
        discordTransport = nil
        commands = nil
    }

    // MARK: - Event Routing

    private func handleGatewayEvent(_ event: DiscordGatewayEvent) async {
        switch event {
        case .ready(let ready):
            // Store application ID and register slash commands
            await apiClient?.setApplicationID(ready.application.id)
            if let guildID = config.discordGuildID, let appID = ready.application.id as String? {
                // The success line is logged only in the success branch.
                do {
                    try await apiClient?.registerSlashCommands(applicationID: appID, guildID: guildID)
                    logger.info("[CHATOPS] Registered slash commands for guild \(guildID).")
                } catch {
                    logger.error("[CHATOPS] Failed to register Discord slash commands for guild \(guildID): \(error.localizedDescription). CONSEQUENCE: the user types \"/\" in Discord and Devgentic's commands are missing or STALE — a renamed verb keeps its old name and answers with a usage hint forever. Nothing retries until the next gateway READY.")
                }
            } else {
                // Named rather than left as an empty else: without a guild id no slash command registers, which looks like a
                // failed registration.
                let guild = config.discordGuildID ?? "nil"
                logger.error("[CHATOPS] Discord READY arrived with no guild id (\(guild)) or no application id, so NO slash commands were registered. CONSEQUENCE: the user sees none of Devgentic's commands in Discord's \"/\" menu; they remain reachable only by typing them as ordinary messages.")
            }

        case .messageCreate(let message):
            await handleMessage(message)

        case .interactionCreate(let interaction):
            await handleInteraction(interaction)

        case .disconnected(let error):
            // A permanent close ends the reconnect loop, so this is the bridge's last event; only the user can fix the cause.
            if case .gatewayClosedPermanently(let code, let reason)? = error as? DiscordAPIError {
                logger.error("[CHATOPS] Discord is DISABLED until this is fixed — Gateway close \(code): \(reason) CONSEQUENCE: no Discord command, HITL prompt or mirrored response will be delivered, and the bridge will not retry on its own.")
            } else if let error {
                logger.error("Discord Gateway disconnected: \(error.localizedDescription)")
            }
            // Reconnection for transient failures is handled inside the gateway client.

        case .resumed:
            logger.info("Discord Gateway resumed.")
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: DiscordMessage) async {
        // Ignore bot's own messages
        guard message.author.bot != true else { return }

        let channelID = message.channel_id

        // Security gate
        let authorization = await securityGate.authorizeDiscord(channelID: channelID,
                                                  senderID: message.author.id,
                                                  config: config)
        if case .refused(let refusal) = authorization {
            // The one refusal the operator is owed: a throttled sender is the paired operator, so telling them leaks nothing.
            if refusal.mayReply, ChatOpsThrottleNotice.claim(for: .discord),
               case .rateLimited(let retry) = refusal.reason {
                await tell(channelID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }

        // Parse command
        let command = ChatOpsCommand.parseDiscord(
            text: message.content,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier(for: .discord)) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .discord))
            let tierName = config.securityTier(for: .discord).rawValue
            logger.error("[CHATOPS] A Discord \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all, so \"the bot ignored my message\" was unanswerable from the logs.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        // A work-starting command replayed long after it was sent is skipped, not run late.
        if RemoteCommandAge.isAgeGated(command),
           let age = RemoteCommandAge.staleAge(sentAt: RemoteCommandAge.discordSentAt(message.timestamp)) {
            logger.warning("[CHATOPS] A Discord \(String(describing: command)) in channel \(channelID) was sent \(Int(age))s ago. CONSEQUENCE: NOT run (older than \(Int(RemoteCommandAge.maxAge))s); the operator is told to send it again.")
            await tell(channelID, RemoteCommandAge.notice(age: age),
                       whenLost: "the operator is not told their old command was skipped, so it looks as if the bot ignored it.")
            return
        }

        // Route
        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Interaction Handling

    /// The `custom_id` of the modal's single text field.
    /// Fixed rather than the operation id: the operation travels on the modal's `custom_id`; the field only needs a
    /// findable name.
    private static let clarificationFieldID = "answer"

    /// Opens the free-text modal for a parked clarification.
    /// The modal's `custom_id` carries the operation id, so the answer names the clarification it answers.
    private func openClarificationModal(operationID: UUID, interaction: DiscordInteraction) async {
        do {
            try await apiClient?.respondToInteraction(
                interactionID: interaction.id,
                interactionToken: interaction.token,
                type: DiscordInteractionResponsePayload.modal,
                data: DiscordInteractionCallbackData(
                    components: [.actionRow([
                        // Discord requires each text input to be the sole child of its own row.
                        .textInput(
                            customID: Self.clarificationFieldID,
                            label: "Your answer",
                            placeholder: "Type your answer…"
                        )
                    ])],
                    custom_id: CallbackToken.answerClarification(operationID: operationID).wire,
                    title: "Answer the agent"
                )
            )
            logger.info("[CHATOPS] Opened a Discord answer modal for clarification \(operationID).")
        } catch {
            // Not `try?`: a failed modal-open is the user's whole interaction failing, so it is logged.
            logger.error("[CHATOPS] Failed to open the Discord answer modal for clarification \(operationID): \(error.localizedDescription). CONSEQUENCE: the user sees Discord's red \"This interaction failed\", the run stays parked, and the only other way to answer is to type in the channel.")
        }
    }

    /// Resolves a clarification from a submitted modal.
    private func resolveClarificationModal(_ interaction: DiscordInteraction, command: ChatOpsCommand) async {
        guard case .answerClarification(let operationID) = command else {
            logger.error("[CHATOPS] A Discord modal was submitted with an unrecognised custom_id \(interaction.data?.custom_id ?? "nil"). CONSEQUENCE: the typed answer is DROPPED and the run stays parked; this happens when a modal outlives a grammar change.")
            await respond(to: interaction,
                          type: DiscordInteractionResponsePayload.channelMessageWithSource,
                          data: DiscordInteractionCallbackData(content: "That form is no longer recognised — reply in the channel instead."),
                          whenLost: "the user's typed answer was already dropped, and now they are not even told to reply in the channel instead — they see \"This interaction failed\" and the run stays parked with no route to answer it.")
            return
        }

        let answer = interaction.submittedValue(forCustomID: Self.clarificationFieldID) ?? ""

        // Ack before resolving: resolving resumes an unbounded agent run, but the ack has a 3-second deadline.
        await respond(to: interaction,
                      type: DiscordInteractionResponsePayload.deferredUpdateMessage,
                      whenLost: "the modal shows Discord's red \"This interaction failed\" even though the answer below IS accepted and the run does resume — so the user believes their answer was lost and is likely to send it again as a new message, starting a second run.")

        logger.info("[CHATOPS] A Discord modal resolved clarification \(operationID) by correlation rather than by the conversation cursor (\(answer.count) characters).")
        await remoteMirrorService?.handleClarification(operationID: operationID, text: answer)
    }


    /// Sends an interaction's response and logs what the user is left looking at when it fails.
    /// An interaction has one initial response and a three-second deadline; `whenLost` states each call site's
    /// consequence.
    private func respond(
        to interaction: DiscordInteraction,
        type: Int,
        data: DiscordInteractionCallbackData? = nil,
        whenLost consequence: String
    ) async {
        do {
            try await apiClient?.respondToInteraction(
                interactionID: interaction.id,
                interactionToken: interaction.token,
                type: type,
                data: data
            )
        } catch {
            logger.error("[CHATOPS] Failed to respond to Discord interaction \(interaction.id) (type \(type)): \(error.localizedDescription). CONSEQUENCE: \(consequence)")
        }
    }

    private func handleInteraction(_ interaction: DiscordInteraction) async {
        // Origin and reply are separate: `originChannelID` is evidence (nil means unstated) and feeds the allowlist;
        // `replyChannelID` is only an address.
        let originChannelID = interaction.channel_id
        let replyChannelID = interaction.channel_id ?? config.discordAuthorizedChannelID ?? ""

        // 1. PARSE FIRST. Pure, no I/O, and a gate cannot judge a command it has not seen.
        let command: ChatOpsCommand
        switch interaction.type {
        case DiscordInteraction.messageComponent, DiscordInteraction.modalSubmit:
            command = ChatOpsCommand.parseDiscord(customID: interaction.data?.custom_id)
        case DiscordInteraction.applicationCommand:
            command = ChatOpsCommand.parseDiscord(slashCommandName: interaction.data?.name)
        default:
            // An unhandled interaction type is logged and answered, not dropped without an ack.
            logger.error("[CHATOPS] Discord interaction type \(interaction.type) is not handled by this build. CONSEQUENCE: the user is told the interaction is unsupported instead of watching it fail silently, and this line names the type so the gap is findable.")
            await respond(to: interaction,
                          type: DiscordInteractionResponsePayload.channelMessageWithSource,
                          data: DiscordInteractionCallbackData(content: "That control is not supported by this version of Devgentic."),
                          whenLost: "the user is not told the control is unsupported and simply sees \"This interaction failed\" — the silent outcome the branch above was written to replace.")
            return
        }

        // Gates run before any ack: a modal is the acknowledgement, and an ack followed by a refusal would leave a stuck
        // "thinking" placeholder.
        if let originChannelID {
            let authorization = await securityGate.authorizeDiscord(channelID: originChannelID,
                                                      senderID: interaction.member?.user?.id,
                                                      config: config)
        if case .refused(let refusal) = authorization {
            // The one refusal the operator is owed: a throttled sender is the paired operator, so telling them leaks nothing.
            if refusal.mayReply, ChatOpsThrottleNotice.claim(for: .discord),
               case .rateLimited(let retry) = refusal.reason {
                await tell(originChannelID,
                           "⏳ Too many commands at once. Try again in \(Int(retry.rounded(.up)))s.",
                           whenLost: "the paired operator is not told their command was throttled, so they see the bot ignore them and cannot tell a rate limit from a crash.")
            }
            return
        }
        } else if interaction.type == DiscordInteraction.modalSubmit {
            // The one exemption: a modal submission has no channel; the allowlist ran on the opening tap and the operation id
            // correlates the answer.
            logger.info("[CHATOPS] A Discord modal submission carried no channel_id, so the channel allowlist was skipped for it. CONSEQUENCE: this is expected — a modal is not in a channel; the allowlist ran when the button that opened it was tapped, and the tier gate still applies below.")
        } else {
            // Refused: without a channel id there is no evidence the interaction came from the paired channel.
            logger.error("[CHATOPS] A Discord interaction of type \(interaction.type) arrived with NO channel_id, so it cannot be matched against the channel allowlist. CONSEQUENCE: it is refused and nothing is acknowledged. Previously the authorized channel id was substituted here, which made the allowlist compare that id with itself and admit the interaction unchecked.")
            return
        }

        guard await securityGate.canExecute(command, tier: config.securityTier(for: .discord)) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier(for: .discord))
            // A direct reply, not an edit: `editInteractionResponse` needs a deferred ack. This is the interaction's one
            // response, so failure is logged.
            do {
                try await apiClient?.respondToInteraction(
                    interactionID: interaction.id,
                    interactionToken: interaction.token,
                    type: DiscordInteractionResponsePayload.channelMessageWithSource,
                    data: DiscordInteractionCallbackData(content: msg)
                )
            } catch {
                logger.error("[CHATOPS] Failed to send a Discord tier denial for \(String(describing: command)): \(error.localizedDescription). CONSEQUENCE: the user sees Discord's red \"This interaction failed\" and is never told the refusal was a security-tier decision they can change in Settings.")
            }
            return
        }

        // 3. Opening the modal IS this interaction's one response, so it returns here.
        if case .answerClarification(let operationID) = command,
           interaction.type == DiscordInteraction.messageComponent {
            await openClarificationModal(operationID: operationID, interaction: interaction)
            return
        }

        // 4. A submitted modal carries the answer, correlated by the operation id in its custom_id.
        if interaction.type == DiscordInteraction.modalSubmit {
            await resolveClarificationModal(interaction, command: command)
            return
        }

        // 5. Everything else keeps the deferred ack it has always had.
        if interaction.type == DiscordInteraction.messageComponent {
            await respond(to: interaction,
                          type: DiscordInteractionResponsePayload.deferredUpdateMessage,
                          whenLost: "the button tap is never acknowledged, so Discord marks it failed after three seconds — and because the ack failed, the reply that follows has no deferred response to edit and may not reach the user either.")
        } else if interaction.type == DiscordInteraction.applicationCommand {
            await respond(to: interaction,
                          type: DiscordInteractionResponsePayload.deferredChannelMessage,
                          whenLost: "the slash command is never acknowledged, so Discord marks it failed after three seconds and the reply that follows has no deferred response to edit.")
        }

        // Route HITL commands directly.
        if await routeHITL(command) { return }

        // For slash commands, route and send response via followup
        await routeInteractionCommand(command, interaction: interaction, channelID: replyChannelID)
    }

    // MARK: - Command Routing

    /// Resolves the three HITL decisions and reports whether the command was one.
    /// Returns a Bool so a filter is distinguishable from a silent-drop `break`.
    /// - Returns: whether the command was a HITL decision and has been resolved.
    private func routeHITL(_ command: ChatOpsCommand) async -> Bool {
        switch command {
        case .approveHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: true)
        case .denyHITL(let operationID):
            await remoteMirrorService?.handleApproval(operationID: operationID, approved: false)
        case .gateChoiceHITL(let operationID, let optionIndex):
            await remoteMirrorService?.handleGate(operationID: operationID, optionIndex: optionIndex)
        default:
            return false
        }
        return true
    }


    /// Routes a command the command service owns, rendering the same view for every destination.
    /// - Returns: whether the command was one the service owns.
    private func routeThroughService(_ command: ChatOpsCommand, to destination: RemoteDestination) async -> Bool {
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

    /// Answers the parked clarification; the operation id is derived at the moment of the reply, never remembered from
    /// the prompt.
    private func resolveClarification(_ text: String) async {
        guard let operationID = commands?.pendingClarificationOperationID() else {
            logger.error("[CHATOPS] A clarification answer arrived but no clarification is pending for the bound conversation. CONSEQUENCE: the reply was DROPPED rather than submitted as a new agent turn, and the remote user received no acknowledgement.")
            return
        }
        await remoteMirrorService?.handleClarification(operationID: operationID, text: text)
    }

    /// [C6] Posts a decided view. A failure is LOGGED rather than swallowed by `try?`.
    private func render(_ view: RemoteView?, to destination: RemoteDestination) async {
        guard let view else {
            logger.error("[CHATOPS] A Discord command produced no view because the command service was never built — start() ran without a view model. CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        guard let transport = discordTransport else {
            logger.error("[CHATOPS] No Discord transport while rendering a view. CONSEQUENCE: the remote user receives NO reply and the command looks ignored.")
            return
        }
        do {
            try await transport.render(view, to: destination)
        } catch {
            logger.error("[CHATOPS] Failed to render a view to Discord: \(error.localizedDescription). CONSEQUENCE: the remote user receives NO reply for a command that succeeded locally.")
        }
    }


    /// Posts a plain-text message that explains something to the remote user, and logs when it does not arrive.
    /// `whenLost` is required so each call site states what the user loses if the explanation is dropped.
    private func tell(_ channelID: String, _ text: String, whenLost consequence: String) async {
        guard let apiClient else {
            logger.error("[CHATOPS] No Discord API client while telling the user: \"\(text.prefix(60))\". CONSEQUENCE: \(consequence)")
            return
        }
        do {
            _ = try await apiClient.sendMessage(channelID: channelID, content: RemoteEgressSanitizer.credentialsOnly(text))
        } catch {
            logger.error("[CHATOPS] Failed to tell the Discord user \"\(text.prefix(60))\": \(error.localizedDescription). CONSEQUENCE: \(consequence)")
        }
    }

    private func routeCommand(_ command: ChatOpsCommand, channelID: String) async {
        if await routeThroughService(command, to: .channel(RemoteChannel(provider: .discord, channelID: channelID))) {
            return
        }
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
            // Unreachable by design: the button and the modal submission are intercepted before routing; arriving here means
            // an intercept is missing.
            logger.error("[CHATOPS] A Discord `.answerClarification(\(operationID))` reached routeCommand, which should be impossible: the modal intercepts in handleInteraction run first. CONSEQUENCE: the Answer button did nothing and the run stays parked.")
        case .pairingAttempt:
            // A well-formed PIN outside a pairing window, usually a re-sent code after pairing succeeded; named so it is not
            // logged as an unknown drop.
            logger.info("[CHATOPS] A pairing PIN arrived with no pairing window open. CONSEQUENCE: it is ignored — pairing is already complete, or the window expired and the user must start it again from Settings.")

        default:
            // `.unknown` reaches here from unmatched text and from stale buttons whose callback token does not parse.
            logger.warning("[CHATOPS/SILENT] A Discord \(String(describing: command)) reached the end of routeCommand and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive; if this is a button tap, its callback token no longer parses and every copy of that button in scrollback is now inert.")
        }
    }

    /// Routes an interaction command to the same views the message path renders, addressed to the interaction.
    private func routeInteractionCommand(_ command: ChatOpsCommand, interaction: DiscordInteraction, channelID: String) async {
        let channel = RemoteChannel(provider: .discord, channelID: channelID)
        if await routeThroughService(command, to: .interactionReply(
            channel: channel,
            interactionToken: interaction.token
        )) {
            return
        }

        // A command the service does not own would leave the deferred "thinking" placeholder forever; an unregistered
        // slash name reaches here as `.unknown`.
        logger.error("[CHATOPS] A Discord interaction carried \(String(describing: command)), which no command handler owns. CONSEQUENCE: the deferred \"thinking…\" placeholder is resolved with an explanation instead of being left in the channel forever; the command itself did nothing, and this line names it so the gap is findable.")

        // Resolving the placeholder is the whole point, so this posts even though there is nothing
        // useful to say — an edited message the user can read beats a spinner that never stops.
        await render(
            .notice(Notice(
                tone: .warning,
                body: "That command is not available in this version of Devgentic. Use /help to see what is."
            )),
            to: .interactionReply(channel: channel, interactionToken: interaction.token)
        )
    }

    // MARK: - Command Handlers

    private func handleFreeText(_ text: String, channelID: String) async {
        // No liveness guard: `ChatOpsCommandService` holds its host weakly and tells the user when it is lost.

        guard let conversationID = config.discordActiveConversationID else {
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

        // Sends a typing indicator; deliberately swallowed, since it expires on its own and a log line per message would
        // bury real drops.
        try? await apiClient?.sendTypingIndicator(channelID: channelID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // The transport is resolved inside the closure, so a nil transport becomes a refusal the user is told about, not a
        // silent drop.
        let admission = commands.submitTurn(
            prompt: text,
            conversationID: conversationID,
            source: .discord,
            config: requestConfig,
            attachMirror: { [weak self] in
                guard let self,
                      let transport = self.discordTransport,
                      let mirror = self.remoteMirrorService else { return false }
                mirror.registerSession(
                    conversationID: conversationID,
                    info: RemoteSessionInfo(transport: transport, chatID: channelID, source: .discord)
                )
                return true
            }
        )

        if case .refused(let message, let consequence) = admission {
            await tell(channelID, message, whenLost: consequence)
        }
    }

    // MARK: - Text Builders


}

// MARK: - DiscordAPIClient Extension

extension DiscordAPIClient {
    func setApplicationID(_ id: String) {
        self.applicationID = id
    }
}

// MARK: - Announcing (slice 3)

/// The bridge conforms, not the transport: announcing needs this provider's own paired channel, which only the
/// bridge knows.
extension DiscordChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .discord }

    /// Requires a live listener and a paired channel; a stopped or never-paired bridge must announce nothing.
    var canAnnounce: Bool {
        isRunning && config.discordBotToken != nil && config.discordAuthorizedChannelID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // A nil conversation is not a duplicate: an app-wide notification belongs to no conversation, so nothing else
        // reports it.
        guard let conversationID else { return false }
        return remoteMirrorService?.isMirroring(conversationID) ?? false
    }

    func announce(_ view: RemoteView) async -> Bool {
        guard let transport = discordTransport, let channelID = config.discordAuthorizedChannelID else {
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
