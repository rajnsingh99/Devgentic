// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MCPElicitationBroker.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import MCP
import os

private let logger = DGLogger(category: "MCPElicitationBroker")

/// Services MCP `elicitation/create`: the in-protocol way for a server to ask the user something mid-tool-call.
/// Routes elicitation into the app's human-in-the-loop surface (InteractionCenter + ExecutionSuspensionService).
/// Only form-mode is serviced, answered as free text mapped onto the schema's fields; URL-mode is declined explicitly.
@MainActor
final class MCPElicitationBroker {

    static let shared = MCPElicitationBroker()
    private init() {}

    /// Conversation to raise the question in, keyed by MCP source. Populated from the tool
    /// path — an elicitation arrives out-of-band and carries no conversation of its own.
    private var conversationBySource: [UUID: UUID] = [:]

    func noteActivity(sourceID: UUID, conversationID: UUID) {
        conversationBySource[sourceID] = conversationID
    }

    func forget(conversationID: UUID) {
        for (source, conversation) in conversationBySource where conversation == conversationID {
            conversationBySource[source] = nil
        }
    }

    func handle(
        parameters: CreateElicitation.Parameters,
        sourceID: UUID,
        serverLabel: String
    ) async throws -> CreateElicitation.Result {

        guard let conversationID = conversationBySource[sourceID] else {
            logger.error("""
                [MCP-ELICIT] '\(serverLabel)' (source \(sourceID)) asked the user a question but no \
                conversation is associated with this source — DECLINED. There is no surface to show \
                the question in, so the server is told the request was cancelled.
                """)
            return CreateElicitation.Result(action: .cancel, content: nil)
        }

        switch parameters {
        case .url(let urlParameters):
            // Opening a server-chosen URL is a trust decision, not a form fill. Decline
            // loudly rather than silently doing nothing.
            logger.warning("""
                [MCP-ELICIT] '\(serverLabel)' requested URL-mode elicitation \
                (\(MCPRedaction.redact(url: urlParameters.url))) — DECLINED. Devgentic services \
                form-mode elicitation only; the server should fall back to a form or a tool error.
                """)
            return CreateElicitation.Result(action: .decline, content: nil)

        case .form(let formParameters):
            return await handleForm(
                formParameters,
                sourceID: sourceID,
                serverLabel: serverLabel,
                conversationID: conversationID
            )
        }
    }

    // MARK: - Form mode

    private func handleForm(
        _ parameters: CreateElicitation.Parameters.FormParameters,
        sourceID: UUID,
        serverLabel: String,
        conversationID: UUID
    ) async -> CreateElicitation.Result {

        // No presenter means `suspendForClarification` below would park on a question
        // nobody can ever see; cancel instead of hanging the server's call.
        guard let presenter = HITLPresenter.center else {
            logger.error("""
                [MCP-ELICIT] '\(serverLabel)' asked the user a question but no InteractionCenter \
                is claimed — CANCELLED rather than parked, since waiting would hang the server's \
                request on a prompt that could never be displayed.
                """)
            return CreateElicitation.Result(action: .cancel, content: nil)
        }

        // Nobody to ask: a scheduled or woken run shows no banner, so this question would park until the run's limit ended it.
        // Cancelled at once; the server learns no answer is coming.
        guard await ExecutionSuspensionService.shared.canReachAHuman(inConversation: conversationID) else {
            logger.notice("[MCP-ELICIT] '\(serverLabel)' asked a question during an UNATTENDED run [conv \(conversationID)]. CONSEQUENCE: cancelled without parking — nobody can answer it.")
            return CreateElicitation.Result(action: .cancel, content: nil)
        }

        let fields = Self.fieldNames(in: parameters.requestedSchema)
        let operationID = UUID()

        // Reuse the clarification surface: it is the existing "agent needs a text answer
        // from the user" path, complete with banner, stale watchdog, and cancel-by-conversation.
        let question = Self.composeQuestion(message: parameters.message, fields: fields)
        presenter.enqueue(PendingHITL(
            id: operationID,
            origin: HITLOrigin(
                interface: .chat,
                conversationID: conversationID,
                nodeID: nil,
                nodeName: serverLabel,
                title: "\(serverLabel) needs input",
                profileID: nil
            ),
            kind: .clarification(PendingClarification(id: operationID, question: question))
        ))

        logger.info("""
            [MCP-ELICIT] '\(serverLabel)' (source \(sourceID)) is asking the user for \
            \(fields.isEmpty ? "free-form input" : "\(fields.count) field(s): \(fields.joined(separator: ", "))") \
            [op \(operationID) conv \(conversationID)]. The tool call is parked until answered.
            """)

        let answer = await ExecutionSuspensionService.shared.suspendForClarification(
            for: operationID, conversationID: conversationID
        )
        presenter.resolve(operationID: operationID)

        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.notice("[MCP-ELICIT] User dismissed '\(serverLabel)'s question [op \(operationID)] — server told the request was cancelled.")
            return CreateElicitation.Result(action: .cancel, content: nil)
        }

        // Map the answer onto the requested schema: one field takes the whole answer; with several, free text can't be split
        // reliably, so it goes to the first field and the rest stay absent (a partial accept, not fabricated values).
        var content: [String: Value] = [:]
        if let first = fields.first {
            content[first] = .string(answer)
            if fields.count > 1 {
                logger.warning("""
                    [MCP-ELICIT] '\(serverLabel)' requested \(fields.count) fields but the answer is \
                    free text; only '\(first)' was populated. The server may re-ask or reject. A \
                    structured form UI would fix this properly.
                    """)
            }
        }

        logger.info("[MCP-ELICIT] Answered '\(serverLabel)' [op \(operationID)] with \(content.count) field(s).")
        return CreateElicitation.Result(action: .accept, content: content.isEmpty ? nil : content)
    }

    // MARK: - Schema helpers

    /// Field names from the requested schema, in a stable order.
    private static func fieldNames(in schema: Elicitation.RequestSchema) -> [String] {
        guard let encoded = try? JSONEncoder().encode(schema),
              let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let properties = object["properties"] as? [String: Any] else {
            return []
        }
        // Prefer the declared `required` order so the field we can actually populate is the
        // one the server most needs.
        let required = (object["required"] as? [String]) ?? []
        let rest = properties.keys.filter { !required.contains($0) }.sorted()
        return required + rest
    }

    private static func composeQuestion(message: String, fields: [String]) -> String {
        guard !fields.isEmpty else { return message }
        if fields.count == 1 {
            return "\(message)\n\n(Answer for: \(fields[0]))"
        }
        return "\(message)\n\n(Requested: \(fields.joined(separator: ", ")) — the first will be filled from your answer.)"
    }
}

// MARK: - Host bridge

/// `elicitation/create` handler for `MCPClientService`. See MCPHostBridge.swift.
extension MCPElicitationBroker: MCPElicitationRequestHandling {}
