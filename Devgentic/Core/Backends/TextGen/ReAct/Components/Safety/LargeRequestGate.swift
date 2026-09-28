// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  LargeRequestGate.swift
//  Devgentic
//
//  Asks the user before a cloud model is sent an unusually large request.
//
//  ⚠️ WHY THIS EXISTS (2026-09-27). Tool results are deliberately NOT cut below what fits
//  (`ToolResultBudget`, the user's 2026-09-24 rule), and cloud windows are huge — a 1M-token
//  OpenRouter model gives a native payload budget of ~2.25M chars. So "summarize these four log
//  files" sent 75,290 input tokens in one request with nothing on screen until it came back. That
//  is the right behaviour for a local model (free) and the wrong SURPRISE for a paid one. The user
//  chose a confirmation over a cap: nothing is cut, the user just sees the size first.
//
//  Scope: native (turn-array) runs against a remote endpoint. `AgentConnect` decides "remote" and
//  passes the threshold in `AgentInput.largeRequestConfirmChars`; 0 disables the gate, which is
//  what every local provider and every minimal/test constructor gets.
//

import Foundation

enum LargeRequestGate {

    /// The size the user asked to be warned at.
    static let thresholdTokens = 50_000

    /// Threshold in characters, on the same chars-per-token basis the context gauge and
    /// `PromptFitCheck` use — so "50K tokens" here means what the gauge would call 50K.
    static var thresholdChars: Int {
        Int(Double(thresholdTokens) * PromptFitCheck.charsPerToken)
    }

    /// The `AgentInput.largeRequestConfirmChars` value for a run: the threshold for a remote
    /// endpoint, 0 (gate off) for one that never leaves this machine.
    ///
    /// ⚠️ `ProviderClass` alone is not enough: it files every `.openAICompatible` profile under
    /// `.cloud`, but most of those are LM Studio / vLLM / llama.cpp on localhost, where a big
    /// request costs nothing and a banner would just be in the way.
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

    /// Whether this request needs a confirmation.
    ///
    /// Asked once per threshold-sized step of growth, not every iteration: after the user approves
    /// a 60K-token request, the next ask comes when the payload passes 60K + 50K. A run that stays
    /// over the line would otherwise re-prompt on every tool call.
    ///
    /// - Parameters:
    ///   - payloadChars: estimated size of the request about to be sent.
    ///   - thresholdChars: `AgentInput.largeRequestConfirmChars`; 0 or less disables the gate.
    ///   - approvedThroughChars: the largest payload the user has already approved in this run (0 if none).
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
