// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  HistoryCompactionService.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "HistoryCompaction")

// MARK: - Compaction Result

/// What a compaction would do, decided without calling the Intelligence Core.
/// Lets the UI announce compaction before the multi-second IC inference (`compactionStarted` is derived from it)
/// and gives the trigger/batch math a pure, testable seam.
struct CompactionPlan: Sendable {
    /// The oldest messages to summarize; recent turns are excluded.
    let turnsToCompact: [ChatMessage]
    /// Summary from the previous checkpoint, for cascading. Empty when this is the first.
    let priorSummary: String
    /// Sequential checkpoint number this run would produce (1-based).
    let checkpointNumber: Int
    /// User turns inside the batch — what the UI reports.
    let turnPairsInBatch: Int
    /// Estimated chars of all pending turns, for logging/tuning.
    let estimatedChars: Int
    /// Where the checkpoint goes: strictly after the last compacted message and strictly before the first one kept.
    /// Readers keep `timestamp > checkpoint.timestamp`.
    let checkpointTimestamp: Date
}

struct CompactionResult: Sendable {
    /// The synthetic checkpoint message to insert into chat history.
    let checkpointMessage: ChatMessage
    /// Number of turns that were summarized.
    let turnsCompacted: Int
    /// First ~120 chars of the summary for UI display.
    let summaryPreview: String
    /// Sequential checkpoint number (1-based).
    let checkpointNumber: Int
}

// MARK: - History Compaction Service

// Why: cold model load and prefill are uninterruptible, so summarization must not block the request path or rely on a
// timeout.
/// Evaluates whether conversation history needs compaction and produces IC-powered checkpoint summaries.
/// Off the request path: `evaluate` (cheap, no IC) decides during the turn, `scheduleExecution` summarizes in background.
/// The current request proceeds with uncompacted history; the persisted checkpoint benefits every later turn.
actor HistoryCompactionService {

    static let shared = HistoryCompactionService()

    /// History char usage ratio that triggers compaction (0.0–1.0).
    /// Compaction triggers when estimated history chars exceed this fraction of charBudget.
    private let charBudgetTriggerRatio = 0.6

    /// Overhead reserved for the system prompt + output in the IC model's context.
    private let icPromptOverheadChars = 800

    // MARK: - Background Delivery

    // Why: compaction can finish after its originating stream ended, and yielding to a finished continuation is a silent
    // no-op; data delivery must not ride stream events (only the optional UI chips do).
    /// Stream-independent delivery path for finished checkpoints: persists the message and splices it into the transcript.
    /// Registered once at startup by `MessagingCoordinator`, which holds both the persistence store and the history array.
    private var checkpointSink: (@Sendable (ChatMessage, UUID) async -> Void)?

    /// Conversations with a background compaction currently running. Prevents a second turn
    /// arriving mid-compaction from scheduling a duplicate summarization of the same batch
    /// (the checkpoint hasn't landed yet, so its planner would re-plan the same turns).
    private var backgroundRuns: Set<UUID> = []

    func setCheckpointSink(_ sink: @escaping @Sendable (ChatMessage, UUID) async -> Void) {
        checkpointSink = sink
    }

    /// Stream-independent UI reporting for automatic compaction: `begin` shows the progress row, `finish` its outcome.
    /// Registered at startup beside the checkpoint sink, since an automatic run starts after its turn's stream has ended.
    /// `begin` returns false when a row is already running for the conversation.
    private var activityBegin: (@Sendable (UUID) async -> Bool)?
    private var activityFinish: (@Sendable (UUID, ManualOutcome) async -> Void)?

    func setActivitySink(begin: @escaping @Sendable (UUID) async -> Bool,
                         finish: @escaping @Sendable (UUID, ManualOutcome) async -> Void) {
        activityBegin = begin
        activityFinish = finish
    }

    /// Which model summarizes, for manual and automatic compaction alike: the Intelligence Core when it is on, its History
    /// Compaction feature is on and a model is selected; otherwise the conversation's own model, which is always available.
    static func useIntelligenceCore(defaults: UserDefaults = .standard, icModelSelected: Bool) -> Bool {
        let master = defaults.bool(forKey: AppSettings.isIntelligenceCoreEnabledKey)
        let feature = defaults.object(forKey: AppSettings.ciFeatureHistoryCompactionKey) as? Bool ?? true
        return master && feature && icModelSelected
    }

    /// Marks a background run as started. Returns false when one is already in flight for
    /// this conversation. Internal (not private) so the dedup contract is unit-testable
    /// without triggering a real IC execution.
    func beginBackgroundRun(conversationID: UUID) -> Bool {
        guard !backgroundRuns.contains(conversationID) else { return false }
        backgroundRuns.insert(conversationID)
        return true
    }

    func endBackgroundRun(conversationID: UUID) {
        backgroundRuns.remove(conversationID)
    }

    // Why: no time limit: a model load or prefill is uninterruptible, so a timeout would only report late; compaction is a
    // tool-less bot call and the transcript row shows it is running.
    /// Runs the planned compaction off the request path; returns immediately while a background task summarizes.
    /// Summarized by the Intelligence Core when `useIntelligenceCore` says so, otherwise by the conversation's own model.
    /// `onEvent` receives optional stream chips; it is nil when the turn's stream has already ended (the normal case).
    func scheduleExecution(
        plan: CompactionPlan,
        conversationID: UUID,
        conversationModel: ProviderConfig,
        onEvent: (@Sendable (AgentStreamEvent) -> Void)? = nil,
        // Test seams, as on `compactNow`: a stand-in summarizer and delivery, so a test neither
        // loads a model nor replaces the app-wide checkpoint sink. Production passes neither.
        summarizerOverride: (@Sendable ([[String: String]]) async throws -> String)? = nil,
        deliverOverride: (@Sendable (ChatMessage, UUID) async -> Void)? = nil
    ) {
        guard beginBackgroundRun(conversationID: conversationID) else {
            logger.info("[COMPACTION] Background run already in flight for conversation \(conversationID.uuidString.prefix(8)) — duplicate schedule skipped; this turn keeps uncompacted history.")
            return
        }

        // `Task {}` inherits actor isolation, so the dedup bookkeeping in the defer runs
        // safely on this actor; the long model await inside merely suspends, never blocks it.
        Task {
            defer { endBackgroundRun(conversationID: conversationID) }
            let ownsRow = await activityBegin?(conversationID) ?? false
            let useIC = Self.useIntelligenceCore(icModelSelected: await IntelligenceCoreService.shared.hasModelSelected)
            logger.notice("[COMPACTION] Automatic compaction for \(conversationID.uuidString.prefix(8)) — \(plan.turnPairsInBatch) turn pairs, summarizer: \(useIC ? "Intelligence Core" : "conversation model '\(conversationModel.modelName)'"). No time limit; the transcript shows it running.")
            do {
                let result: CompactionResult
                if let summarizerOverride {
                    result = try await execute(plan: plan, conversationID: conversationID, summarize: summarizerOverride)
                } else if useIC {
                    // Through the coordinator, as a background run of its own, never under the finished turn's identity.
                    // See `runBackgroundLocal`.
                    result = try await LocalInferenceCoordinator.shared.runBackgroundIntelligence(feature: "Compaction") {
                        try await execute(plan: plan, conversationID: conversationID)
                    }
                } else {
                    result = try await LocalInferenceCoordinator.shared.runBackgroundLocal(
                        feature: "Compaction", conversationID: conversationID, config: conversationModel
                    ) {
                        let model = try await AgentConnect().initializeModel(config: conversationModel, isBotFlow: true)
                        return try await execute(plan: plan, conversationID: conversationID) { messages in
                            try await model.generate(messages: messages, tools: nil, responseSchema: nil)
                        }
                    }
                }

                if let sink = deliverOverride ?? checkpointSink {
                    await sink(result.checkpointMessage, conversationID)
                } else {
                    // Should be impossible after startup wiring; loud because the summary was paid for and then dropped,
                    // and the next turn will re-plan the same batch.
                    logger.error("[COMPACTION] No checkpoint sink registered — checkpoint #\(result.checkpointNumber) for conversation \(conversationID.uuidString.prefix(8)) is LOST and the work will repeat next turn.")
                }

                if ownsRow {
                    let original = plan.turnsToCompact.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
                    let summaryChars: Int = {
                        if case .checkpoint(let summary) = result.checkpointMessage.content { return summary.count }
                        return 0
                    }()
                    await activityFinish?(conversationID, .compacted(
                        turnPairs: result.turnsCompacted, originalChars: original, summaryChars: summaryChars,
                        usedIntelligenceCore: useIC, checkpointID: result.checkpointMessage.id))
                }
                onEvent?(.compactionCompleted(
                    turnsCompacted: result.turnsCompacted,
                    summaryPreview: result.summaryPreview,
                    checkpoint: result.checkpointMessage
                ))
                logger.notice("[COMPACTION] Background run complete — checkpoint #\(result.checkpointNumber), \(result.turnsCompacted) turns, conversationID: \(conversationID.uuidString.prefix(8))")
            } catch {
                if ownsRow { await activityFinish?(conversationID, .failed(error.localizedDescription)) }
                onEvent?(.compactionFailed(reason: error.localizedDescription))
                logger.warning("[COMPACTION] Background run failed: \(error.localizedDescription). History stays uncompacted; the next turn will re-plan. conversationID: \(conversationID.uuidString.prefix(8))")
            }
        }
    }

    private init() {}

    // MARK: - Manual compaction (the context gauge's "Compact now")

    /// What a manual compaction did, in words the gauge can show as-is.
    enum ManualOutcome: Equatable, Sendable {
        /// `checkpointID` is the card the summary was saved as, so the transcript row can jump to it
        /// — the card sits where the summarized turns end, usually well above the fold.
        case compacted(turnPairs: Int, originalChars: Int, summaryChars: Int, usedIntelligenceCore: Bool,
                       checkpointID: UUID)
        case nothingToCompact
        case alreadyRunning
        case failed(String)

        var message: String {
            switch self {
            case let .compacted(pairs, original, summary, usedIC, _):
                return "Summarized \(pairs) earlier turn(s): \(PromptFitCheck.roundedK(ContextOccupancy.tokens(original))) → \(PromptFitCheck.roundedK(ContextOccupancy.tokens(summary))) tokens"
                    + (usedIC ? " (Intelligence Core)." : " (this conversation's model).")
            case .nothingToCompact:
                return "Nothing to compact yet — the 5 most recent messages are always kept, and at least 4 older ones are needed."
            case .alreadyRunning:
                return "A compaction is already running for this conversation."
            case let .failed(reason):
                return "Compaction failed: \(reason)"
            }
        }
    }

    /// Compacts now, at the user's request, regardless of the automatic trigger.
    /// Summarizes with the IC when it is on and has a model, otherwise with the conversation's own model (`fallbackModel`).
    /// Uses the automatic planner with the trigger ratio at 0 (same batch rules, prompt, card, sink); transcript untouched.
    func compactNow(
        chatHistory: [ChatMessage],
        conversationID: UUID,
        contextWindow: Int,
        fallbackModel: ProviderConfig,
        // Test seams: a stand-in summarizer and delivery, so a test neither loads a model nor
        // replaces the app-wide checkpoint sink. Production passes neither.
        summarizerOverride: (@Sendable ([[String: String]]) async throws -> String)? = nil,
        deliverOverride: (@Sendable (ChatMessage, UUID) async -> Void)? = nil
    ) async -> ManualOutcome {
        let useIC = Self.useIntelligenceCore(icModelSelected: await IntelligenceCoreService.shared.hasModelSelected)
        let summarizerWindow = useIC ? await resolveICContextWindow() : contextWindow

        guard let plan = Self.planCompaction(
            chatHistory: chatHistory,
            charBudget: PromptFitCheck.historyCharBudget(forContextWindow: contextWindow),
            icContextWindow: summarizerWindow,
            charBudgetTriggerRatio: 0,
            icPromptOverheadChars: icPromptOverheadChars
        ) else {
            logger.info("[COMPACTION] Manual compaction for \(conversationID.uuidString.prefix(8)) found nothing to compact (\(chatHistory.count) messages). CONSEQUENCE: nothing changed.")
            return .nothingToCompact
        }
        guard beginBackgroundRun(conversationID: conversationID) else { return .alreadyRunning }
        defer { endBackgroundRun(conversationID: conversationID) }

        logger.notice("[COMPACTION] Manual compaction for \(conversationID.uuidString.prefix(8)) — \(plan.turnPairsInBatch) turn pairs, summarizer: \(useIC ? "Intelligence Core" : "conversation model '\(fallbackModel.modelName)'").")
        do {
            let result: CompactionResult
            if let summarizerOverride {
                result = try await execute(plan: plan, conversationID: conversationID, summarize: summarizerOverride)
            } else if useIC {
                // Manual 'Compact now' also runs through the coordinator, so it carries a run id and generates under the lock.
                result = try await LocalInferenceCoordinator.shared.runBackgroundIntelligence(feature: "Compaction (manual)") {
                    try await execute(plan: plan, conversationID: conversationID)
                }
            } else {
                result = try await LocalInferenceCoordinator.shared.runBackgroundLocal(
                    feature: "Compaction (manual)", conversationID: conversationID, config: fallbackModel
                ) {
                    let model = try await AgentConnect().initializeModel(config: fallbackModel, isBotFlow: true)
                    return try await execute(plan: plan, conversationID: conversationID) { messages in
                        try await model.generate(messages: messages, tools: nil, responseSchema: nil)
                    }
                }
            }
            guard let sink = deliverOverride ?? checkpointSink else {
                logger.error("[COMPACTION] No checkpoint sink registered — the manual checkpoint for \(conversationID.uuidString.prefix(8)) is LOST.")
                return .failed("the summary could not be saved")
            }
            await sink(result.checkpointMessage, conversationID)
            let original = plan.turnsToCompact.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
            let summaryChars: Int = {
                if case .checkpoint(let summary) = result.checkpointMessage.content { return summary.count }
                return 0
            }()
            return .compacted(turnPairs: result.turnsCompacted, originalChars: original,
                              summaryChars: summaryChars, usedIntelligenceCore: useIC,
                              checkpointID: result.checkpointMessage.id)
        } catch {
            logger.warning("[COMPACTION] Manual compaction failed for \(conversationID.uuidString.prefix(8)): \(error.localizedDescription). CONSEQUENCE: history is unchanged.")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Public API

    /// Evaluates whether compaction is needed and produces a checkpoint if so; a wrapper over `evaluate` + `execute`.
    /// It can only report after the IC inference has finished, so use the two-step form to announce compaction.
    /// Returns a `CompactionResult`, or nil if not needed. `charBudget` is the history character budget (60% of window × 4).
    func compactIfNeeded(
        chatHistory: [ChatMessage],
        conversationID: UUID,
        charBudget: Int
    ) async throws -> CompactionResult? {
        guard let plan = await evaluate(chatHistory: chatHistory, charBudget: charBudget) else {
            return nil
        }
        return try await execute(plan: plan, conversationID: conversationID)
    }

    /// Decides whether to compact and what to compact — WITHOUT calling the Intelligence
    /// Core. Cheap and side-effect free, so the caller can announce the work before paying
    /// for it.
    func evaluate(chatHistory: [ChatMessage], charBudget: Int) async -> CompactionPlan? {
        // The only async step: the IC model's context window drives batch sizing.
        let icContextWindow = await resolveICContextWindow()
        return Self.planCompaction(
            chatHistory: chatHistory,
            charBudget: charBudget,
            icContextWindow: icContextWindow,
            charBudgetTriggerRatio: charBudgetTriggerRatio,
            icPromptOverheadChars: icPromptOverheadChars
        )
    }

    /// Pure planning core: all trigger and batch arithmetic, no IC and no I/O.
    /// Internal and static so the math is unit-testable.
    static func planCompaction(
        chatHistory: [ChatMessage],
        charBudget: Int,
        icContextWindow: Int,
        charBudgetTriggerRatio: Double,
        icPromptOverheadChars: Int
    ) -> CompactionPlan? {

        // Step 1: Find the latest existing checkpoint (if any).
        let latestCheckpoint = findLatestCheckpoint(in: chatHistory)
        let checkpointNumber = (latestCheckpoint != nil) ? countCheckpoints(in: chatHistory) + 1 : 1

        // Step 2: Count and measure turns after the checkpoint.
        let turnsAfterCheckpoint: [ChatMessage]
        if let checkpoint = latestCheckpoint {
            turnsAfterCheckpoint = chatHistory.filter { $0.timestamp > checkpoint.timestamp }
        } else {
            turnsAfterCheckpoint = chatHistory
        }

        // Reported for triage only, not a gate: context pressure is a size question, answered by the char-budget trigger below;
        // the structural floor lives in the batch guard (keep the 5 most recent, require >= 4 compactable messages).
        let turnPairCount = turnsAfterCheckpoint.filter { $0.sender == .user }.count

        // Step 3: Estimate char size of pending turns.
        let estimatedChars = turnsAfterCheckpoint.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }

        let triggerChars = Int(Double(charBudget) * charBudgetTriggerRatio)
        guard estimatedChars > triggerChars else {
            logger.info("[COMPACTION] Skipped — \(estimatedChars) chars is under the \(triggerChars)-char trigger (\(turnPairCount) turn pairs since last checkpoint) → history passed through uncompacted.")
            return nil
        }

        // Step 5: Calculate batch size — how many turns can fit in one IC call.
        let inputBudgetChars = max(1000, (Int(Double(icContextWindow) * 0.70) * 4) - icPromptOverheadChars)

        // Include prior checkpoint summary in the budget if cascading.
        let priorSummary = latestCheckpoint.flatMap { extractCheckpointSummary(from: $0) } ?? ""
        let priorSummaryChars = priorSummary.isEmpty ? 0 : priorSummary.count + 100 // +100 for prompt framing

        let availableForTurns = max(500, inputBudgetChars - priorSummaryChars)

        // Step 6: Find the largest batch of oldest turns that fits.
        // We compact from oldest (after checkpoint) and keep recent turns untouched.
        let fitted = calculateBatch(
            turns: turnsAfterCheckpoint,
            availableChars: availableForTurns,
            keepRecentCount: 5 // Always keep last 5 messages (2-3 turn pairs) uncompacted
        )
        guard let boundary = alignBatchBoundary(fitted, in: turnsAfterCheckpoint) else {
            logger.info("[COMPACTION] Skipped — no clean boundary in the \(fitted.count)-message batch (it must end on a reply, at a point the next message's timestamp is strictly later) → history passed through uncompacted.")
            return nil
        }
        let turnsToCompact = boundary.batch

        // The only structural floor: never pay an IC inference to summarize fewer than ~2 turn pairs. With `keepRecentCount`
        // it also stops a short-but-huge history from compacting away everything it has.
        guard turnsToCompact.count >= 4 else {
            logger.info("[COMPACTION] Skipped — only \(turnsToCompact.count) message(s) fit the batch after keeping the 5 most recent (need >= 4) → history passed through uncompacted.")
            return nil
        }

        let turnPairsInBatch = turnsToCompact.filter { $0.sender == .user }.count
        logger.notice("[COMPACTION] Planned — \(turnPairsInBatch) turn pairs, ~\(estimatedChars) chars pending, checkpoint #\(checkpointNumber). IC context: \(icContextWindow) tokens.")

        return CompactionPlan(
            turnsToCompact: turnsToCompact,
            priorSummary: priorSummary,
            checkpointNumber: checkpointNumber,
            turnPairsInBatch: turnPairsInBatch,
            estimatedChars: estimatedChars,
            checkpointTimestamp: boundary.checkpointTimestamp
        )
    }

    // Why: readers keep only messages strictly after the checkpoint; a message inside its margin is in neither the summary
    // nor the history, and a batch ending on a user turn leaves an answer without its question.
    /// Trims a batch so the checkpoint can sit cleanly after it, and says where.
    /// The batch never ends on a user message and ends only where the next message is strictly later; the checkpoint goes
    /// halfway between the two (or 1 ms after the end when nothing follows). Nil when trimming leaves nothing.
    static func alignBatchBoundary(_ batch: [ChatMessage], in turns: [ChatMessage]) -> (batch: [ChatMessage], checkpointTimestamp: Date)? {
        var batch = batch
        while let last = batch.last {
            if last.sender == .user { batch.removeLast(); continue }
            let next = turns.count > batch.count ? turns[batch.count] : nil
            guard let next else { return (batch, last.timestamp.addingTimeInterval(0.001)) }
            let gap = next.timestamp.timeIntervalSince(last.timestamp)
            let midpoint = last.timestamp.addingTimeInterval(min(gap / 2, 0.001))
            if gap > 0, midpoint > last.timestamp, midpoint < next.timestamp {
                return (batch, midpoint)
            }
            batch.removeLast()   // the next message is not strictly later — no room for a checkpoint
        }
        return nil
    }

    /// Runs the planned compaction: one IC summarization, then the checkpoint message.
    /// The expensive half (a model load plus inference), unbounded by design; see `scheduleExecution`.
    func execute(plan: CompactionPlan, conversationID: UUID) async throws -> CompactionResult {
        try await execute(plan: plan, conversationID: conversationID) { messages in
            try await self.callIC(messages: messages)
        }
    }

    /// `execute` with the summarizing model supplied by the caller — the Intelligence Core for
    /// automatic compaction, and for a manual "Compact" with the IC off, the conversation's own
    /// model. Same prompt, same checkpoint, same metrics either way.
    func execute(
        plan: CompactionPlan,
        conversationID: UUID,
        summarize: @Sendable ([[String: String]]) async throws -> String
    ) async throws -> CompactionResult {
        let turnsToCompact = plan.turnsToCompact
        let checkpointNumber = plan.checkpointNumber
        let turnPairsInBatch = plan.turnPairsInBatch

        // Step 7: Build the summarization prompt and call the model.
        let turnRecords = formatTurnsForIC(turnsToCompact)
        let summary = try await summarize(Self.summaryMessages(turnRecords: turnRecords, priorSummary: plan.priorSummary))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            throw NSError(domain: "HistoryCompactionService", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "The model returned an empty summary. Compaction skipped."])
        }

        // Create the checkpoint ChatMessage, placed by the planner between the last compacted message and the first kept one.
        let checkpointTimestamp = plan.checkpointTimestamp

        let checkpointMessage = ChatMessage(
            id: UUID(),
            conversationId: conversationID,
            timestamp: checkpointTimestamp,
            sender: .agent,
            content: .checkpoint(summary: summary)
        )

        let preview = String(summary.prefix(120))

        // Compaction metrics for observability and tuning.
        let originalChars = turnsToCompact.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }
        let summaryChars = summary.count
        let ratio = originalChars > 0 ? Double(originalChars) / Double(summaryChars) : 0
        let savedChars = originalChars - summaryChars

        logger.notice("Compaction complete: checkpoint #\(checkpointNumber), \(turnPairsInBatch) turns compacted.")
        logger.notice("[Compaction Metrics] Original: \(originalChars) chars \u{2192} Summary: \(summaryChars) chars. Ratio: \(String(format: "%.1f", ratio)):1. Saved: \(savedChars) chars (~\(savedChars / 4) tokens).")

        return CompactionResult(
            checkpointMessage: checkpointMessage,
            turnsCompacted: turnPairsInBatch,
            summaryPreview: preview,
            checkpointNumber: checkpointNumber
        )
    }

    // MARK: - Helpers

    /// Finds the latest checkpoint message in the history.
    private static func findLatestCheckpoint(in history: [ChatMessage]) -> ChatMessage? {
        history.last(where: {
            if case .checkpoint = $0.content { return true }
            return false
        })
    }

    /// Counts existing checkpoints in the history.
    private static func countCheckpoints(in history: [ChatMessage]) -> Int {
        history.filter {
            if case .checkpoint = $0.content { return true }
            return false
        }.count
    }

    /// Extracts the summary text from a checkpoint message.
    private static func extractCheckpointSummary(from message: ChatMessage) -> String? {
        if case .checkpoint(let summary) = message.content { return summary }
        return nil
    }

    /// Resolves the IC model's context window from MLXModelService.
    private func resolveICContextWindow() async -> Int {
        let selectedModelName = UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? ""
        guard !selectedModelName.isEmpty else { return 4096 }

        // Wait for the scan: a list that hasn't populated yet is indistinguishable from a deleted model, and both silently
        // collapse the IC window to 4096, making compaction far more aggressive than the model requires.
        await MLXModelService.shared.ensureLoaded()
        return await MainActor.run {
            guard let model = MLXModelService.shared.installedModel(named: selectedModelName) else {
                // A miss is logged: this lookup feeds every compaction budget downstream, so a silent 4096 would make history
                // vanish with no explanation.
                logger.error("[COMPACTION] IC context-window lookup MISSED for model '\(selectedModelName)' — not among \(MLXModelService.shared.installedModels.count) installed model(s). CONSEQUENCE: falling back to a 4096-token IC window, so compaction runs far more aggressively than the model actually requires (frequent checkpoints, history disappearing). Re-select the Intelligence Core model.")
                return 4096
            }
            let profile = MLXModelService.shared.cachedCognitiveProfile(for: model)
            return profile.metadata?.contextWindow ?? 4096
        }
    }

    /// Calculates the largest batch of oldest turns that fits in the available char budget.
    /// Keeps the most recent `keepRecentCount` messages untouched.
    private static func calculateBatch(
        turns: [ChatMessage],
        availableChars: Int,
        keepRecentCount: Int
    ) -> [ChatMessage] {
        let compactable = Array(turns.dropLast(min(keepRecentCount, turns.count)))
        var accumulated = 0
        var batch: [ChatMessage] = []

        for msg in compactable {
            let charCount = msg.content.textContent?.count ?? 0
            if accumulated + charCount > availableChars && !batch.isEmpty {
                break
            }
            accumulated += charCount
            batch.append(msg)
        }

        return batch
    }

    /// Formats turns into a simplified text record for the IC prompt.
    private func formatTurnsForIC(_ turns: [ChatMessage]) -> String {
        var records: [String] = []

        for msg in turns {
            // Skip checkpoint messages — they're prior summaries, not real turns.
            if case .checkpoint = msg.content { continue }

            let role = msg.sender == .user ? "User" : "Agent"
            let text: String
            switch msg.content {
            case .plainText(let t), .markdownText(let t): text = t
            case .codeBlock(_, let code): text = code
            case .error(let title, let details, _, _): text = "\(title ?? "Error"): \(details)"
            case .mediaArtifact(let a): text = "[Media: \(a.label ?? a.kind.rawValue)]"
            case .checkpoint: continue // Already handled above
            // Skip, do not summarize: this build cannot read the content, so any text produced would be invented, and a
            // compaction summary is fed back to the model as fact.
            case .unknown: continue
            }
            let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text

            // Include tool summaries for agent messages
            var toolInfo = ""
            if msg.sender == .agent && !msg.timelineEvents.isEmpty {
                let tools = msg.flattenedTimelineEvents.compactMap { event -> String? in
                    if case .toolExecution(let data) = event {
                        let status = (data.isSuccess ?? false) ? "success" : "failed"
                        return "  - \(data.name) [\(status)]"
                    }
                    return nil
                }
                if !tools.isEmpty {
                    toolInfo = "\n  Tools used:\n" + tools.joined(separator: "\n")
                }
            }

            records.append("[\(role)]: \(truncated)\(toolInfo)")
        }

        return records.joined(separator: "\n\n")
    }


    /// The summarization prompt — shared by the Intelligence Core and the conversation's own model.
    static func summaryMessages(turnRecords: String, priorSummary: String) -> [[String: String]] {
        let systemPrompt = """
        You are a conversation history summarizer for an AI agent system. Produce a structured \
        summary that preserves critical operational details. Use bullet points.

        MUST preserve:
        - Tool names and their outcomes (success/failure)
        - File paths, URLs, and key identifiers discovered
        - Error patterns and user corrections/denials
        - Key decisions and findings

        MUST NOT include:
        - Verbose explanations or commentary
        - Redundant information already in the prior summary
        - Speculative or inferred context not present in the turns

        Keep the summary concise but complete. Target 200-400 words.
        """

        var userContent = ""
        if !priorSummary.isEmpty {
            userContent += "Prior conversation summary (include this context):\n\(priorSummary)\n\n---\n\n"
        }
        userContent += "Summarize the following conversation turns:\n\n\(turnRecords)"

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userContent]
        ]
        return messages
    }

    /// Calls the Intelligence Core to produce the checkpoint summary.
    /// Enforces a timeout to prevent blocking the agent pipeline indefinitely.
    private func callIC(messages: [[String: String]]) async throws -> String {
        // Release our hold however this ends (success, empty summary, timeout, cancellation); `releaseHold` is
        // idle-debounced, so the rest of this turn's IC work (response synthesis) still reuses the same load.
        defer { Task { await IntelligenceCoreService.shared.releaseHold(caller: .historyCompaction) } }

        // No timeout: an uninterruptible model load or prefill cannot be stopped by one, so it would only report late.
        let result = try await IntelligenceCoreService.shared.generate(
            messages: messages,
            maxTokens: 1024,
            temperature: 0.3,
            caller: .historyCompaction
        )

        let summary = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            logger.warning("IC returned empty summary for history compaction.")
            throw NSError(
                domain: "HistoryCompactionService",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Intelligence Core generated an empty summary. Compaction skipped."]
            )
        }

        return summary
    }
}
