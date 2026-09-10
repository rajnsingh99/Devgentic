// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2026 Raj Singh
//
//  DiscordChatOpsBridge.swift
//  Devgentic
//
//  Created by Raj Singh on 24/03/26.
//

import Foundation
import SwiftData
import os

/// The core orchestrator for Discord ChatOps.
///
/// Routes incoming Discord Gateway events through the security gate, parses them into commands,
/// and dispatches them to the appropriate handler.
///
/// Uses the single-path architecture: remote messages flow through
/// `MainApplicationViewModel.submitRemoteMessage()` — the same path as the Mac UI.
/// The `RemoteMirrorService` handles mirroring events back to the transport.
@Observable @MainActor
final class DiscordChatOpsBridge {

    private let logger = Logger(subsystem: DGLogger.subsystem, category: "DiscordChatOpsBridge")

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

        isRunning = true

        listeningTask = Task { [weak self] in
            guard let self else { return }

            let stream = await gateway.start()
            self.logger.info("DiscordChatOpsBridge started — listening for Discord events.")

            for await event in stream {
                await self.handleGatewayEvent(event)
            }

            await MainActor.run {
                self.isRunning = false
                self.logger.info("DiscordChatOpsBridge stopped.")
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
    }

    // MARK: - Event Routing

    private func handleGatewayEvent(_ event: DiscordGatewayEvent) async {
        switch event {
        case .ready(let ready):
            // Store application ID and register slash commands
            await apiClient?.setApplicationID(ready.application.id)
            if let guildID = config.discordGuildID, let appID = ready.application.id as String? {
                // ⚠️⚠️ THE SUCCESS LINE USED TO FIRE UNCONDITIONALLY, one statement below a `try?`.
                // A failed registration therefore logged "Registered slash commands for guild X" —
                // the single place a field debugger would look actively asserted the opposite of
                // what happened. It now lives in the success branch, where it is true.
                do {
                    try await apiClient?.registerSlashCommands(applicationID: appID, guildID: guildID)
                    logger.info("[CHATOPS] Registered slash commands for guild \(guildID).")
                } catch {
                    logger.error("[CHATOPS] Failed to register Discord slash commands for guild \(guildID): \(error.localizedDescription). CONSEQUENCE: the user types \"/\" in Discord and Devgentic's commands are missing or STALE — a renamed verb keeps its old name and answers with a usage hint forever. Nothing retries until the next gateway READY.")
                }
            } else {
                // ⚠️ NAMED RATHER THAN LEFT AS AN EMPTY ELSE. Without a guild id no slash command is
                // ever registered, and the symptom is identical to a failed registration.
                let guild = config.discordGuildID ?? "nil"
                logger.error("[CHATOPS] Discord READY arrived with no guild id (\(guild)) or no application id, so NO slash commands were registered. CONSEQUENCE: the user sees none of Devgentic's commands in Discord's \"/\" menu; they remain reachable only by typing them as ordinary messages.")
            }

        case .messageCreate(let message):
            await handleMessage(message)

        case .interactionCreate(let interaction):
            await handleInteraction(interaction)

        case .disconnected(let error):
            // ⚠️ A PERMANENT close is not a disconnect to shrug at. The gateway client stops its
            // reconnect loop for these, so this is the last event the bridge will ever see — and
            // the cause (a rejected token, a privileged intent left disabled) is something only
            // the user can fix.
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
        guard await securityGate.authorizeDiscord(channelID: channelID, config: config) else { return }

        // Parse command
        let command = ChatOpsCommand.parseDiscord(
            text: message.content,
            awaitingClarification: commands?.isAwaitingClarification ?? false
        )

        // Tier enforcement
        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            let tierName = config.securityTier.rawValue
            logger.error("[CHATOPS] A Discord \(String(describing: command)) from channel \(channelID) was refused by the \(tierName) security tier. CONSEQUENCE: the command did nothing; without this line a tier refusal left no trace at all, so \"the bot ignored my message\" was unanswerable from the logs.")
            await tell(channelID, msg, whenLost: "the remote user is not told why their command was refused, so a tier-blocked command and a dead bridge look identical to them — and the refusal itself is logged nowhere else.")
            return
        }

        // Route
        await routeCommand(command, channelID: channelID)
    }

    // MARK: - Interaction Handling

    /// The `custom_id` of the modal's single text field.
    ///
    /// ⚠️ FIXED, and deliberately not the operation id. The operation travels on the MODAL's
    /// `custom_id`; the FIELD only has to be findable when the submission comes back, and giving it
    /// a stable name keeps the read on the submission side a constant rather than a reconstruction.
    private static let clarificationFieldID = "answer"

    /// Opens the free-text modal for a parked clarification.
    ///
    /// ⚠️ THE MODAL'S `custom_id` CARRIES THE OPERATION ID, and that is the entire point of slice 4
    /// on Discord: the answer comes back naming the clarification it answers, instead of being
    /// resolved against whichever conversation the provider cursor happened to point at — which
    /// made a second parked clarification unanswerable and let a `/new` in between misroute the
    /// reply into a brand-new agent run.
    private func openClarificationModal(operationID: UUID, interaction: DiscordInteraction) async {
        do {
            try await apiClient?.respondToInteraction(
                interactionID: interaction.id,
                interactionToken: interaction.token,
                type: DiscordInteractionResponsePayload.modal,
                data: DiscordInteractionCallbackData(
                    components: [.actionRow([
                        // ⚠️ Discord requires each Text Input to be the SOLE child of its own row.
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
            // ⚠️ NOT `try?`. A failed modal-open is the user's whole interaction failing, and the
            // old code swallowed ack errors silently — so "the button does nothing" had no trace.
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

        // ⚠️ ACK BEFORE RESOLVING. Resolving resumes a parked agent run, which is unbounded work;
        // the 3-second deadline is not. A silent ack is right here because the mirror edits the
        // original prompt in place when the clarification resolves — that edit IS the feedback.
        await respond(to: interaction,
                      type: DiscordInteractionResponsePayload.deferredUpdateMessage,
                      whenLost: "the modal shows Discord's red \"This interaction failed\" even though the answer below IS accepted and the run does resume — so the user believes their answer was lost and is likely to send it again as a new message, starting a second run.")

        logger.info("[CHATOPS] A Discord modal resolved clarification \(operationID) by correlation rather than by the conversation cursor (\(answer.count) characters).")
        await remoteMirrorService?.handleClarification(operationID: operationID, text: answer)
    }


    /// Sends an interaction's response, and says what the user is left looking at when it fails.
    ///
    /// ⚠️⚠️ AN INTERACTION HAS EXACTLY ONE INITIAL RESPONSE AND A THREE-SECOND DEADLINE. Every call
    /// site was `try? await apiClient?.respondToInteraction(...)`, and `respondToInteraction` throws
    /// WITHOUT logging internally — so a failed ack or reply left the user staring at Discord's red
    /// "This interaction failed", or at a spinner that never resolves, with nothing written down
    /// anywhere. That is precisely the failure this file's ordering comments were written to remove,
    /// surviving one layer below them.
    ///
    /// ⚠️ `whenLost` IS REQUIRED, NOT DEFAULTED: the five call sites fail in visibly different ways
    /// — a missing modal, an unresolved spinner, an unexplained refusal — and one shared sentence
    /// would describe four of them wrongly.
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
        // ⚠️⚠️ TWO DIFFERENT QUESTIONS, AND ONE VARIABLE USED TO ANSWER BOTH. This was
        // `interaction.channel_id ?? config.discordAuthorizedChannelID ?? ""`, and that single
        // expression fed BOTH the allowlist check and the reply address. For the reply address the
        // fallback is harmless — posting into the user's own paired channel is always safe. For the
        // allowlist it was a BYPASS: `authorizeDiscord` compares its argument against
        // `discordAuthorizedChannelID`, so substituting that very value made the guard compare the
        // authorized id with itself and pass unconditionally. Any interaction arriving without a
        // `channel_id` was therefore authorized by construction.
        //
        // They are separated here so the fallback cannot reach the gate. `originChannelID` is
        // evidence — nil means "the payload did not say" — and `replyChannelID` is an address.
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
            // ⚠️ WAS A BARE `return` — no ack, no log. Discord shows the user a red "Something went
            // wrong" three seconds later and nothing was recorded anywhere, which is how a whole
            // interaction type could be unsupported without leaving a trace.
            logger.error("[CHATOPS] Discord interaction type \(interaction.type) is not handled by this build. CONSEQUENCE: the user is told the interaction is unsupported instead of watching it fail silently, and this line names the type so the gap is findable.")
            await respond(to: interaction,
                          type: DiscordInteractionResponsePayload.channelMessageWithSource,
                          data: DiscordInteractionCallbackData(content: "That control is not supported by this version of Devgentic."),
                          whenLost: "the user is not told the control is unsupported and simply sees \"This interaction failed\" — the silent outcome the branch above was written to replace.")
            return
        }

        // 2. ⚠️ GATES BEFORE ANY ACK, AND THE ORDER IS LOAD-BEARING TWICE OVER.
        //    (a) A MODAL IS THE ACKNOWLEDGEMENT. Discord permits exactly one initial response per
        //        interaction, so a modal cannot follow a deferred ack — anything that decides
        //        whether to open one must run first.
        //    (b) The old order acked FIRST and gated after, so an interaction from an unauthorised
        //        channel — or one that tripped the rate limiter — received a deferred "thinking…"
        //        and then returned, leaving that placeholder in the channel FOREVER because nothing
        //        ever edited it.
        //    Both gates are actor hops with no network in them, so the 3-second budget is intact.
        if let originChannelID {
            guard await securityGate.authorizeDiscord(channelID: originChannelID, config: config) else {
                logger.error("[CHATOPS] A Discord interaction from channel \(originChannelID) was refused by the channel allowlist or the rate limiter. CONSEQUENCE: nothing is acknowledged, so Discord marks the interaction failed — which is the honest outcome, and strictly better than the permanent \"thinking…\" placeholder the previous ordering left behind.")
                return
            }
        } else if interaction.type == DiscordInteraction.modalSubmit {
            // ⚠️ THE ONE DOCUMENTED EXEMPTION, and it matches what Slack already does for its own
            // view submissions: a modal is not IN a channel, so there is no channel to check. The
            // allowlist already ran on the button tap that opened it, and the answer is correlated
            // by the operation id carried in the modal's `custom_id` — not by where it came from.
            // The tier gate below still applies, because that is about the ACT, not the place.
            logger.info("[CHATOPS] A Discord modal submission carried no channel_id, so the channel allowlist was skipped for it. CONSEQUENCE: this is expected — a modal is not in a channel; the allowlist ran when the button that opened it was tapped, and the tier gate still applies below.")
        } else {
            // ⚠️ REFUSED, NOT WAVED THROUGH. Without a channel id there is no evidence this came
            // from the paired channel, and the old fallback turned that absence into a pass.
            logger.error("[CHATOPS] A Discord interaction of type \(interaction.type) arrived with NO channel_id, so it cannot be matched against the channel allowlist. CONSEQUENCE: it is refused and nothing is acknowledged. Previously the authorized channel id was substituted here, which made the allowlist compare that id with itself and admit the interaction unchecked.")
            return
        }

        guard await securityGate.canExecute(command, tier: config.securityTier) else {
            let msg = await securityGate.denialMessage(for: command, tier: config.securityTier)
            // ⚠️ A DIRECT REPLY, not an edit. `editInteractionResponse` only works after a deferred
            // ack, and there is deliberately no longer one at this point.
            // ⚠️ THIS IS THE INTERACTION'S ONE PERMITTED RESPONSE. If it fails the user gets
            // Discord's red "This interaction failed" with no explanation — and previously with no
            // log either, which is the "the button does nothing and nothing was recorded" failure
            // the ordering comment above was written to eliminate.
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

    /// Resolves the three HITL decisions, and reports whether this was one.
    ///
    /// ⚠️ A RETURNED BOOL RATHER THAN A `default: break` FALL-THROUGH, and the distinction is the
    /// point. This was an inline switch whose default arm was a bare `break` — correct, because it
    /// falls through to more routing below, but INDISTINGUISHABLE at a glance from the bare `break`
    /// arms in this same file that really did drop a command and record nothing. One of those
    /// shapes is a filter and the other is a silent drop; making the filter return a value means a
    /// reader (and a scan) can tell them apart without tracing what follows.
    ///
    /// It is deliberately the same shape as `routeThroughService`, which answers the same question
    /// for the command service's verbs.
    ///
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


    /// ⚠️ ONE DECISION, TWO ADDRESSES. Discord used to render `/conversations` two different ways —
    /// a button grid when it arrived as a channel message, a numbered plain-text list when it
    /// arrived as a slash command — because "reply into the interaction" was built as a SECOND CODE
    /// PATH that re-derived its own text. Both callers now render the same view; only the
    /// destination differs.
    ///
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

    /// [C8] Answers the parked clarification. ⚠️ Derived at the moment of the reply, never
    /// remembered from when the prompt was sent.
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
            // ⚠️ UNREACHABLE BY DESIGN, and named rather than defaulted so it says so. The button
            // is intercepted in `handleInteraction` before routing (opening the modal IS that
            // interaction's one response) and the submission is intercepted alongside it. Arriving
            // here means one of those intercepts was removed, and the symptom would otherwise be a
            // button that silently does nothing — the failure this switch's own comment describes.
            logger.error("[CHATOPS] A Discord `.answerClarification(\(operationID))` reached routeCommand, which should be impossible: the modal intercepts in handleInteraction run first. CONSEQUENCE: the Answer button did nothing and the run stays parked.")
        default:
            // ⚠️ NOT "HANDLED ELSEWHERE" FOR EVERY CASE, which is what this comment used to imply.
            // `.unknown` reaches here from a plain text message that matched no verb, and from a
            // button whose callback token no longer parses — a stale button from a superseded
            // grammar, which chat scrollback keeps forever.
            logger.info("[CHATOPS/SILENT] A Discord \(String(describing: command)) reached the end of routeCommand and was dropped. CONSEQUENCE: the user received NO reply at all and cannot tell whether the bot is alive; if this is a button tap, its callback token no longer parses and every copy of that button in scrollback is now inert.")
        }
    }

    /// ⚠️ THE DIVERGENCE FIX. This used to re-derive plain text for three verbs, post STRAY CHANNEL
    /// MESSAGES for `/new` and `/cancel` (leaving Discord's deferred "thinking…" hanging forever),
    /// and drop `switch:` on a `default: break` — which is why the conversation buttons were inert.
    /// It now renders the same views as the message path, addressed to the interaction.
    private func routeInteractionCommand(_ command: ChatOpsCommand, interaction: DiscordInteraction, channelID: String) async {
        let channel = RemoteChannel(provider: .discord, channelID: channelID)
        if await routeThroughService(command, to: .interactionReply(
            channel: channel,
            interactionToken: interaction.token
        )) {
            return
        }

        // ⚠️⚠️ THE RETURN VALUE WAS DISCARDED WITH `_ =`, AND THAT LEFT A PERMANENT "THINKING…".
        // This path is only reached AFTER the interaction has been acked with a deferred response,
        // and Discord shows that placeholder until something edits it. A command the service does
        // not own fell out of here having acked and posted nothing, so the placeholder stayed in
        // the channel forever — the exact failure the deferred-ack ordering above was fixed to
        // prevent, reachable through the front door.
        //
        // ⚠️ REACHABLE, NOT THEORETICAL. An unregistered or renamed slash name parses to `.unknown`
        // (ChatOpsCommand.swift:79), `.unknown` is allowed at every tier
        // (ChatOpsSecurityGate.swift:63), so it passes both gates, gets the ack, and lands here. A
        // guild command left behind by a rename is enough.
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
        guard let vm = viewModel else { return }

        guard let conversationID = config.discordActiveConversationID else {
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

        // Send typing indicator
        // ⚠️ DELIBERATELY SWALLOWED — see the matching note in ChatOpsBridge. A typing indicator is
        // decoration with no consequence to name: it expires on its own and the reply arrives
        // regardless. Logging a line per message for it would bury the drops that do matter.
        try? await apiClient?.sendTypingIndicator(channelID: channelID)

        let requestConfig = BackendRequestConfig(profile: profile)

        // Register the remote session for mirroring
        guard let transport = discordTransport else { return }

        remoteMirrorService?.registerSession(
            conversationID: conversationID,
            info: RemoteSessionInfo(
                transport: transport,
                chatID: channelID,
                source: .discord
            )
        )

        vm.submitRemoteMessage(
            prompt: text,
            conversationID: conversationID,
            source: .discord,
            config: requestConfig
        )
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

/// ⚠️ The BRIDGE conforms, not the transport: a transport renders to a destination it is given,
/// while announcing means knowing this provider's OWN paired channel. Only the bridge knows both.
extension DiscordChatOpsBridge: RemoteAnnouncing {

    var provider: RemoteChannel.Provider { .discord }

    /// ⚠️ Requires a live listener AND a paired channel. A bridge that was stopped, or was never
    /// paired, must announce nothing — otherwise a notification would be addressed to a channel the
    /// user has disconnected.
    var canAnnounce: Bool {
        isRunning && config.discordBotToken != nil && config.discordAuthorizedChannelID != nil
    }

    func isMirroring(_ conversationID: UUID?) -> Bool {
        // ⚠️ nil is NOT a duplicate: an app-wide notification (a finished download) belongs to no
        // conversation, so nothing is already reporting it.
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
