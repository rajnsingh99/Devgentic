// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LargeRequestGate.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Asks the user before a cloud model is sent an unusually large request: nothing is cut, but the user sees the size
/// first, since tool results are not truncated below what fits. Applies to native (turn-array) runs against a remote
/// endpoint; `AgentConnect` passes the threshold in `AgentInput.largeRequestConfirmChars`, and 0 disables the gate.
enum LargeRequestGate {

    /// The size the user asked to be warned at.
    static let thresholdTokens = 50_000

    /// Threshold in characters, on the same chars-per-token basis the context gauge and
    /// `PromptFitCheck` use — so "50K tokens" here means what the gauge would call 50K.
    static var thresholdChars: Int {
        Int(Double(thresholdTokens) * PromptFitCheck.charsPerToken)
    }

    /// The `AgentInput.largeRequestConfirmChars` value for a run: the threshold for a remote endpoint, 0 (gate off) for
    /// one that never leaves this machine. `ProviderClass` alone is not enough, since `.openAICompatible` is often a
    /// local server where a big request costs nothing.
    static func confirmChars(provider: ApiProvider, baseURL: String?) -> Int {
        guard ProviderClass(apiProvider: provider) == .cloud else { return 0 }
        if provider == .openAICompatible,
           let host = baseURL.flatMap({ URL(string: $0.trimmingCharacters(in: .whitespaces)) })?.host?.lowercased(),
           EndpointTransportSecurity.isLoopback(host) {
            return 0
        }
        return thresholdChars
    }

    /// The pseudo tool name the confirmation banner is raised under. Reusing the tool-confirmation
    /// path gets the banner, the ChatOps mirror, parking and "Allow for this chat" for free; an
    /// "Allow for this chat" grant on it means "stop asking about request size in this chat".
    static let bannerToolName = "large_cloud_request"

    /// Whether this request needs a confirmation, asked once per threshold-sized step of growth rather than on every
    /// iteration. `payloadChars` is the estimated size, `thresholdChars` of 0 or less disables the gate, and
    /// `approvedThroughChars` is the largest payload already approved in this run.
    static func needsConfirmation(payloadChars: Int, thresholdChars: Int, approvedThroughChars: Int) -> Bool {
        guard thresholdChars > 0 else { return false }
        let nextAsk = approvedThroughChars > 0 ? approvedThroughChars + thresholdChars : thresholdChars
        return payloadChars >= nextAsk
    }

    static func estimatedTokens(chars: Int) -> Int {
        Int((Double(chars) / PromptFitCheck.charsPerToken).rounded())
    }

    /// The banner body.
    static func bannerText(payloadChars: Int, modelName: String) -> String {
        let tokens = estimatedTokens(chars: payloadChars)
        return """
            The next request to \(modelName) is about \(tokens.formatted()) tokens (\(payloadChars.formatted()) characters), \
            over the \(thresholdTokens.formatted())-token warning level. Cloud providers bill for every input token, \
            and this request resends the whole conversation, including earlier tool results.

            Allow to send it. Deny to stop the run here; nothing is sent.
            """
    }

    /// What the user sees in the chat when they decline.
    static func declinedText(payloadChars: Int) -> String {
        "*Stopped before sending a ~\(estimatedTokens(chars: payloadChars).formatted())-token request to the cloud model.* "
            + "Ask for a narrower task (fewer or smaller files) to keep the request small."
    }
}
