// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  ContextCutLog.swift
//  Devgentic
//
//  What the LAST turn of each conversation had to cut to fit the model's context — shown in the
//  context gauge instead of on every tool card.
//
//  ⚠️ WHY IT EXISTS (2026-09-24). With no limit below what fits, a cut now only happens when the
//  room genuinely runs out — and when it does, the user should be able to find out without it
//  cluttering the transcript. The user chose the gauge as the place (their words: managing the
//  context is the user's responsibility, so the gauge must show them what happened). The executor
//  already logs `[TOOLRESULT]`, but a log line is invisible to anyone not running `log stream`.
//
//  In-memory only, by design: it describes the most recent turn, which is gone on relaunch anyway.
//

import Foundation
import Observation

@MainActor
@Observable
final class ContextCutLog {

    static let shared = ContextCutLog()

    /// One tool result that reached the model shorter than the tool produced it.
    struct ResultCut: Equatable, Sendable {
        let toolName: String
        let originalChars: Int
        let keptChars: Int
    }

    /// A step whose prompt filled the model's window — the PROVIDER cut it, not the app.
    ///
    /// ⚠️ Decided from the provider's REAL prompt-token count, never from the app's estimate.
    /// The estimate is deliberately pessimistic (3 chars/token): on device 2026-09-24 it said
    /// "over budget" at steps 2 and 3 while Ollama counted 5.6K of 8K, and only step 5 (8,051 of
    /// 8,192) truly overflowed. Reporting the estimate would have named the wrong step.
    struct Overflow: Equatable, Sendable {
        let step: Int
        let promptTokens: Int
        let windowTokens: Int
    }

    /// Everything the most recent turn in a conversation cut.
    struct TurnRecord: Equatable, Sendable {
        let traceID: String
        var cuts: [ResultCut] = []
        /// Older tool exchanges the native path summarized out to stay within the window.
        var compactedExchanges = 0
        /// The FIRST step that filled the window. Later ones add nothing a user can act on.
        var overflow: Overflow? = nil

        var isEmpty: Bool { cuts.isEmpty && compactedExchanges == 0 && overflow == nil }
    }

    private(set) var latest: [UUID: TurnRecord] = [:]

    /// A different trace means a new turn: the previous turn's record is replaced, never merged —
    /// the gauge promises "last turn", not "ever".
    func recordCut(_ cut: ResultCut, conversationID: UUID, traceID: String) {
        var record = current(conversationID: conversationID, traceID: traceID)
        record.cuts.append(cut)
        latest[conversationID] = record
    }

    func recordCompaction(droppedExchanges: Int, conversationID: UUID, traceID: String) {
        guard droppedExchanges > 0 else { return }
        var record = current(conversationID: conversationID, traceID: traceID)
        record.compactedExchanges += droppedExchanges
        latest[conversationID] = record
    }

    func recordOverflow(_ overflow: Overflow, conversationID: UUID, traceID: String) {
        var record = current(conversationID: conversationID, traceID: traceID)
        guard record.overflow == nil else { return }
        record.overflow = overflow
        latest[conversationID] = record
    }

    /// The share of the window a step's real prompt count must reach to count as filled.
    /// Ollama cuts to fit and then reports the cut size, which lands just under the window
    /// (8,051 of 8,192 on device) — a strict "≥ window" would never fire.
    static let overflowFraction = 0.97

    /// Whether a real prompt count means the provider had to cut the prompt.
    nonisolated static func isOverflow(promptTokens: Int, windowTokens: Int) -> Bool {
        windowTokens > 0 && Double(promptTokens) >= Double(windowTokens) * overflowFraction
    }

    /// The overflow a step's usage reveals, or nil. Estimated counts (MLX) never qualify — only a
    /// provider's own count can say the provider cut the prompt.
    nonisolated static func overflow(in usage: TokenUsage, step: Int, windowTokens: Int) -> Overflow? {
        guard !usage.isEstimated, isOverflow(promptTokens: usage.inputTokens, windowTokens: windowTokens) else { return nil }
        return Overflow(step: step, promptTokens: usage.inputTokens, windowTokens: windowTokens)
    }

    func lastTurn(for conversationID: UUID?) -> TurnRecord? {
        guard let conversationID, let record = latest[conversationID], !record.isEmpty else { return nil }
        return record
    }

    private func current(conversationID: UUID, traceID: String) -> TurnRecord {
        if let existing = latest[conversationID], existing.traceID == traceID { return existing }
        return TurnRecord(traceID: traceID)
    }

    /// From the executor, which is not on the main actor. Fire-and-forget: this is display state.
    nonisolated static func post(cut: ResultCut, conversationID: UUID, traceID: String) {
        Task { @MainActor in shared.recordCut(cut, conversationID: conversationID, traceID: traceID) }
    }

    nonisolated static func post(overflow: Overflow, conversationID: UUID, traceID: String) {
        Task { @MainActor in shared.recordOverflow(overflow, conversationID: conversationID, traceID: traceID) }
    }

    nonisolated static func post(compactedExchanges: Int, conversationID: UUID, traceID: String) {
        Task { @MainActor in
            shared.recordCompaction(droppedExchanges: compactedExchanges, conversationID: conversationID, traceID: traceID)
        }
    }
}
