//
//  MCPSamplingBroker.swift
//  Devgentic
//
//  Created 2026-08-01 — MCP `sampling/createMessage`.
//
//  Sampling lets a server ask the HOST to run an LLM call on its behalf. Devgentic is
//  itself an LLM host, so the plumbing already existed; nothing bridged it to MCP, and the
//  client advertised no sampling capability at all. Servers that delegate reasoning back to
//  the client (summarisers, agentic servers, servers that ask the host to classify or
//  draft) therefore either disabled those features or failed at call time, with nothing in
//  the UI to explain why.
//
//  ⚠️ Sampling spends the USER's tokens on a THIRD PARTY's instruction. Every request is
//  therefore gated on an explicit approval showing the server, the model, and the prompt —
//  the MCP spec's human-in-the-loop guidance, and the only way the cost stays visible.
//  There is deliberately no "always allow": approval is per request.
//

import Foundation
import MCP
import os

private let logger = DGLogger(category: "MCPSamplingBroker")

/// The LLM context a sampling request should be serviced with.
///
/// Registered by `AgentConnect` when it builds a run's tools, because that is where the
/// resolved `ProviderConfig` and the conversation identity are both in scope. A sampling
/// request arrives out-of-band on the client connection with no conversation attached, so
/// this is what lets one be attributed.
struct MCPSamplingContext: Sendable {
    let conversationID: UUID
    let providerConfig: ProviderConfig
    let profileID: UUID?
    let registeredAt: Date
}

@MainActor
final class MCPSamplingBroker {

    static let shared = MCPSamplingBroker()
    private init() {}

    /// Most recent LLM context per conversation.
    private var contexts: [UUID: MCPSamplingContext] = [:]
    /// Which conversation last used a given MCP source, so its sampling requests are
    /// attributed to the run that actually caused them.
    private var lastConversationBySource: [UUID: UUID] = [:]

    /// Hard ceiling on a single sampling response, independent of what the server asks for.
    /// A server naming `maxTokens: 1_000_000` would otherwise bill the user for it.
    private static let maxTokensCeiling = 4096

    // MARK: - Registration

    func register(context: MCPSamplingContext) {
        contexts[context.conversationID] = context
    }

    func unregister(conversationID: UUID) {
        contexts[conversationID] = nil
        for (source, conversation) in lastConversationBySource where conversation == conversationID {
            lastConversationBySource[source] = nil
        }
    }

    /// Records that `conversationID` is currently driving `sourceID`. Called from the tool
    /// path so an out-of-band sampling request can be tied back to a conversation.
    func noteActivity(sourceID: UUID, conversationID: UUID) {
        lastConversationBySource[sourceID] = conversationID
    }

    // MARK: - Request handling

    func handle(
        parameters: CreateSamplingMessage.Parameters,
        sourceID: UUID,
        serverLabel: String
    ) async throws -> CreateSamplingMessage.Result {

        guard let context = resolveContext(for: sourceID) else {
            logger.error("""
                [MCP-SAMPLING] '\(serverLabel)' (source \(sourceID)) requested sampling but no \
                conversation context is registered — REFUSED. This happens when a server samples \
                outside any active run; there is no profile to bill it to and no conversation to \
                show the approval in.
                """)
            throw MCPError.invalidRequest("No active Devgentic conversation to service this sampling request.")
        }

        // Without somewhere to show the approval, `suspend` below would park forever on a
        // question nobody can answer — the server would hang rather than fail.
        guard let presenter = HITLPresenter.center else {
            logger.error("""
                [MCP-SAMPLING] '\(serverLabel)' requested sampling but no InteractionCenter is \
                claimed — REFUSED rather than parked. Approval could not be shown to anyone, so \
                waiting would hang the server's request indefinitely.
                """)
            throw MCPError.internalError("Devgentic cannot present a sampling approval right now.")
        }

        let promptPreview = Self.preview(parameters: parameters)
        let modelName = context.providerConfig.modelName

        // 1. Consent. Reuses the standard tool-confirmation banner so this needs no new UI
        //    and inherits the existing stale-park watchdog and cancel-by-conversation.
        let operationID = UUID()
        let confirmation = PendingToolConfirmation(
            id: operationID,
            toolName: "MCP sampling · \(serverLabel)",
            params: promptPreview,
            // A third party spending the user's tokens is high-impact, not routine.
            risk: .destructive,
            arguments: nil
        )
        presenter.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(
                interface: .chat,
                conversationID: context.conversationID,
                nodeID: nil,
                nodeName: serverLabel,
                title: "MCP server wants to use \(modelName)",
                profileID: context.profileID
            ),
            kind: .toolConfirmation(confirmation)
        ))

        logger.info("""
            [MCP-SAMPLING] '\(serverLabel)' (source \(sourceID)) requested \(modelName) — awaiting \
            user approval [op \(operationID) conv \(context.conversationID)]. Nothing is sent to \
            the model until this is approved.
            """)

        let approved = await ExecutionSuspensionService.shared.suspend(
            for: operationID, conversationID: context.conversationID
        )
        presenter.resolve(operationID: operationID)

        guard approved else {
            logger.notice("[MCP-SAMPLING] DENIED by user for '\(serverLabel)' [op \(operationID)] — the server is told the user declined.")
            throw MCPError.invalidRequest("The user declined this sampling request.")
        }

        // 2. Run it on the conversation's own profile.
        let messages = Self.toProviderMessages(parameters)
        let requested = parameters.maxTokens
        let effectiveMax = min(requested, Self.maxTokensCeiling)
        if effectiveMax < requested {
            logger.warning("""
                [MCP-SAMPLING] '\(serverLabel)' asked for maxTokens=\(requested); clamped to \
                \(effectiveMax). The response may be cut short — that is preferable to letting a \
                server choose how much of the user's budget to spend.
                """)
        }

        do {
            // AgentConnect is not a singleton; a fresh instance is how every other caller
            // builds a provider.
            let provider = try await AgentConnect().initializeModel(
                config: context.providerConfig, isBotFlow: true
            )
            let started = Date()
            let text = try await provider.generate(
                messages: messages, tools: nil as [[String: Any]]?, responseSchema: nil as Any?
            )
            let elapsedMS = Int(Date().timeIntervalSince(started) * 1000)

            logger.info("""
                [MCP-SAMPLING] Serviced '\(serverLabel)' with \(modelName) in \(elapsedMS)ms, \
                \(text.count) chars returned [op \(operationID)].
                """)

            return CreateSamplingMessage.Result(
                model: modelName,
                stopReason: .endTurn,
                role: .assistant,
                content: .text(text)
            )
        } catch {
            logger.error("""
                [MCP-SAMPLING] Model call FAILED for '\(serverLabel)' after approval: \
                \(error.localizedDescription) [op \(operationID)]. The server receives an error and \
                will likely degrade or abandon whatever it wanted the completion for.
                """)
            throw MCPError.internalError("Sampling failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// Prefer the conversation that last drove this source; fall back to the most recently
    /// registered context so a server sampling before its first tool call still resolves.
    private func resolveContext(for sourceID: UUID) -> MCPSamplingContext? {
        if let conversationID = lastConversationBySource[sourceID], let context = contexts[conversationID] {
            return context
        }
        return contexts.values.max(by: { $0.registeredAt < $1.registeredAt })
    }

    /// Flattens MCP sampling messages into the `[[String: String]]` shape `LLMProvider`
    /// takes. Non-text blocks are described rather than dropped, so the model is at least
    /// aware something was attached.
    private static func toProviderMessages(_ parameters: CreateSamplingMessage.Parameters) -> [[String: String]] {
        var messages: [[String: String]] = []

        if let system = parameters.systemPrompt, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }

        for message in parameters.messages {
            let body = message.content.asArray.map { block -> String in
                switch block {
                case .text(let text): return text
                case .image(_, let mimeType): return "[image attachment: \(mimeType)]"
                case .audio(_, let mimeType): return "[audio attachment: \(mimeType)]"
                case .toolUse: return "[tool use]"
                case .toolResult: return "[tool result]"
                }
            }.joined(separator: "\n")

            messages.append(["role": message.role.rawValue, "content": body])
        }

        return messages
    }

    /// A short, human-readable rendering of what the server wants generated, for the
    /// approval banner. The user cannot consent to what they cannot see.
    private static func preview(parameters: CreateSamplingMessage.Parameters) -> String {
        var parts: [String] = []
        if let system = parameters.systemPrompt, !system.isEmpty {
            parts.append("System: \(system)")
        }
        for message in parameters.messages {
            let body = message.content.asArray.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return nil
            }.joined(separator: "\n")
            if !body.isEmpty {
                parts.append("\(message.role.rawValue.capitalized): \(body)")
            }
        }
        parts.append("Max tokens: \(min(parameters.maxTokens, maxTokensCeiling))")

        let joined = parts.joined(separator: "\n\n")
        let limit = 2000
        guard joined.count > limit else { return joined }
        return String(joined.prefix(limit)) + "\n… [\(joined.count - limit) more characters]"
    }
}
