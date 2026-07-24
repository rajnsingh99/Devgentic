//
//  HistoryCompactionService.swift
//  Devgentic
//
//  IC-powered adaptive history compaction. Summarizes older conversation turns
//  into compact checkpoints using the Intelligence Core (local MLX model).
//  Batch size adapts to the IC model's context window — small models produce
//  frequent high-resolution checkpoints; large models compact in fewer passes.
//
//  Created by Devgentic Architect on 09/04/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "HistoryCompaction")

// MARK: - Compaction Result

/// What a compaction WOULD do, decided without calling the Intelligence Core.
///
/// Exists so the UI can announce compaction *before* the multi-second IC inference rather
/// than after it (the `compactionStarted` payload is derived from this decision, which is
/// why the event could not simply be moved earlier). It also gives the trigger/batch math a
/// pure, testable seam — previously every path past the guards ended in an IC call, so the
/// arithmetic could only be exercised by loading a model.
struct CompactionPlan: Sendable {
    /// The oldest messages to summarize (recent turns are deliberately excluded).
    let turnsToCompact: [ChatMessage]
    /// Summary from the previous checkpoint, for cascading. Empty when this is the first.
    let priorSummary: String
    /// Sequential checkpoint number this run would produce (1-based).
    let checkpointNumber: Int
    /// User turns inside the batch — what the UI reports.
    let turnPairsInBatch: Int
    /// Estimated chars of all pending turns, for logging/tuning.
    let estimatedChars: Int
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

/// Evaluates whether conversation history needs compaction and produces IC-powered
/// checkpoint summaries when triggered.
///
/// Compaction runs OFF the request path: `evaluate` (cheap, no IC) decides during the
/// turn, `scheduleExecution` runs the summarization in the background, and the persisted
/// checkpoint benefits every turn from the next one on. The current request proceeds with
/// uncompacted history — the history builders trim to budget, and the trigger fires at
/// ~36% of the context window, so one turn without relief costs little. This replaced a
/// synchronous design whose 30s "timeout" could not actually bound the stall (cold load
/// and prefill are uninterruptible).
actor HistoryCompactionService {

    static let shared = HistoryCompactionService()

    /// History char usage ratio that triggers compaction (0.0–1.0).
    /// Compaction triggers when estimated history chars exceed this fraction of charBudget.
    private let charBudgetTriggerRatio = 0.6

    /// Overhead reserved for the system prompt + output in the IC model's context.
    private let icPromptOverheadChars = 800

    // MARK: - Background Delivery

    /// Stream-independent delivery path for finished checkpoints: persists the message and
    /// splices it into the live transcript. Registered once at startup by
    /// `MessagingCoordinator` (the one object holding both the persistence store and the
    /// live history array).
    ///
    /// This exists because compaction no longer runs on the request path — it can finish
    /// AFTER the originating stream has ended, and yielding to a finished continuation is a
    /// silent no-op. Data delivery therefore must not ride stream events; only the optional
    /// UI chips do.
    private var checkpointSink: (@Sendable (ChatMessage, UUID) async -> Void)?

    /// Conversations with a background compaction currently running. Prevents a second turn
    /// arriving mid-compaction from scheduling a duplicate summarization of the same batch
    /// (the checkpoint hasn't landed yet, so its planner would re-plan the same turns).
    private var backgroundRuns: Set<UUID> = []

    func setCheckpointSink(_ sink: @escaping @Sendable (ChatMessage, UUID) async -> Void) {
        checkpointSink = sink
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

    /// Runs the planned compaction OFF the request path.
    ///
    /// Returns immediately; the IC inference happens in a background task. The current
    /// request proceeds with uncompacted history (the history builders trim to budget), and
    /// the checkpoint benefits every turn from the next one on — viable only because
    /// checkpoints are persisted now; when they were request-local this would have deferred
    /// the work for nothing.
    ///
    /// - Parameter onEvent: Best-effort UI chips (`.compactionCompleted` / `.compactionFailed`).
    ///   Called after the sink has delivered, so data never depends on it. If the stream has
    ///   already finished, the yield is a harmless no-op and the persisted checkpoint card
    ///   in the transcript is the durable evidence.
    func scheduleExecution(
        plan: CompactionPlan,
        conversationID: UUID,
        onEvent: @escaping @Sendable (AgentStreamEvent) -> Void
    ) {
        guard beginBackgroundRun(conversationID: conversationID) else {
            logger.info("[COMPACTION] Background run already in flight for conversation \(conversationID.uuidString.prefix(8)) — duplicate schedule skipped; this turn keeps uncompacted history.")
            return
        }

        // `Task {}` inherits actor isolation, so the dedup bookkeeping in the defer runs
        // safely on this actor; the long IC await inside merely suspends, never blocks it.
        Task {
            defer { endBackgroundRun(conversationID: conversationID) }
            do {
                let result = try await execute(plan: plan, conversationID: conversationID)

                if let sink = checkpointSink {
                    await sink(result.checkpointMessage, conversationID)
                } else {
                    // Should be impossible after startup wiring; loud because the
                    // consequence is severe — the summary was paid for and then dropped,
                    // and the next turn will re-plan the same batch.
                    logger.error("[COMPACTION] No checkpoint sink registered — checkpoint #\(result.checkpointNumber) for conversation \(conversationID.uuidString.prefix(8)) is LOST and the work will repeat next turn.")
                }

                onEvent(.compactionCompleted(
                    turnsCompacted: result.turnsCompacted,
                    summaryPreview: result.summaryPreview,
                    checkpoint: result.checkpointMessage
                ))
                logger.notice("[COMPACTION] Background run complete — checkpoint #\(result.checkpointNumber), \(result.turnsCompacted) turns, conversationID: \(conversationID.uuidString.prefix(8))")
            } catch {
                onEvent(.compactionFailed(reason: error.localizedDescription))
                logger.warning("[COMPACTION] Background run failed: \(error.localizedDescription). History stays uncompacted; the next turn will re-plan. conversationID: \(conversationID.uuidString.prefix(8))")
            }
        }
    }

    private init() {}

    // MARK: - Public API

    /// Evaluates whether compaction is needed and produces a checkpoint if so.
    ///
    /// Convenience wrapper over `evaluate` + `execute`. Callers that want to tell the user
    /// compaction is happening should use the two-step form instead — this one can only
    /// report after the IC inference has already finished.
    ///
    /// - Parameters:
    ///   - chatHistory: The full conversation history.
    ///   - conversationID: Current conversation UUID.
    ///   - charBudget: The history character budget (60% of context window × 4).
    /// - Returns: A `CompactionResult` if compaction was performed, or `nil` if not needed.
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

    /// Pure planning core — all trigger and batch arithmetic, no IC and no I/O.
    ///
    /// Internal + static so the math is unit-testable. Before the split, every path that got
    /// past the guards ended in an IC call, so these numbers could only be exercised by
    /// loading a model — which is why the trigger logic had almost no real coverage.
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

        // Reported for triage only — NOT a gate. A `minTurnThreshold = 15` user-turn
        // guard used to sit here, but context pressure is a size question, not a count
        // question: the char-budget trigger below already answers it in the same units
        // the budget is expressed in, and derived from the model's own context window.
        // Two gates in different units could only ever disagree — and this one silently
        // won, refusing to compact histories that were genuinely over budget.
        // The structural floor now lives entirely in the batch guard further down
        // (keep the 5 most recent, require >= 4 compactable messages).
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
        let turnsToCompact = calculateBatch(
            turns: turnsAfterCheckpoint,
            availableChars: availableForTurns,
            keepRecentCount: 5 // Always keep last 5 messages (2-3 turn pairs) uncompacted
        )

        // The ONLY structural floor now that the turn-count gate is gone: never pay an IC
        // inference to summarize fewer than ~2 turn pairs. Combined with `keepRecentCount`
        // this also stops a short-but-huge history (a couple of very large messages) from
        // compacting away everything it has.
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
            estimatedChars: estimatedChars
        )
    }

    /// Runs the planned compaction: one IC summarization, then the checkpoint message.
    /// This is the expensive half — a model load plus inference. ⚠️ It is NOT bounded by
    /// `icTimeoutSeconds`; see the note on that property.
    func execute(plan: CompactionPlan, conversationID: UUID) async throws -> CompactionResult {
        let turnsToCompact = plan.turnsToCompact
        let checkpointNumber = plan.checkpointNumber
        let turnPairsInBatch = plan.turnPairsInBatch

        // Step 7: Build the IC prompt and call generate().
        let turnRecords = formatTurnsForIC(turnsToCompact)
        let summary = try await callIC(turnRecords: turnRecords, priorSummary: plan.priorSummary)

        // Step 8: Create the checkpoint ChatMessage.
        // Timestamp is set just after the last compacted message for correct ordering.
        let lastCompactedTimestamp = turnsToCompact.last?.timestamp ?? Date()
        let checkpointTimestamp = lastCompactedTimestamp.addingTimeInterval(0.001)

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

        return await MainActor.run {
            guard let model = MLXModelService.shared.installedModels.first(where: { $0.displayName == selectedModelName }) else {
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

    /// When compaction ASKS the IC inference to stop.
    ///
    /// ⚠️ This is NOT a wall-clock bound, despite how the race below reads. Verified
    /// 2026-07-20 across the Swift semantics and the pinned mlx-swift-lm checkout:
    ///
    ///  • `withThrowingTaskGroup` cancels remaining children AND AWAITS them before
    ///    propagating, so when the timeout child throws, `callIC` still cannot return
    ///    until the generate child actually finishes. The timer decides when cancellation
    ///    is *requested*, never when this function returns.
    ///  • Only the token-decode loop is cancellation-aware (`Evaluate.swift` checks
    ///    `Task.isCancelled` per token). The two phases most likely to consume the whole
    ///    window — a cold model load, and prompt prefill (`LLMModel.prepare`, a plain
    ///    synchronous chunked loop) — have NO cancellation checks. Compaction is by
    ///    construction the app's largest-prompt IC call (~70% of the IC context window),
    ///    so it is the most exposed to the uninterruptible prefill.
    ///  • While it overruns it still holds `ModelContainer`'s mutex, whose waiter queue
    ///    parks in a bare `withCheckedContinuation` with no cancellation handler — so the
    ///    next IC caller in the same turn (response synthesis) queues behind it and cannot
    ///    itself be timed out or stopped. Wrapping that caller in this same pattern would
    ///    not help; the pattern does not compose.
    ///
    /// Consequence for the UI: `.compactionFailed` is emitted from the `catch`, so it
    /// appears when the inference truly ends — NOT at 30s. Any bound has to come from not
    /// entering (an admission gate, or a smaller prompt), or from taking compaction off the
    /// synchronous request path.
    private let icTimeoutSeconds: UInt64 = 30

    /// Calls the Intelligence Core to produce the checkpoint summary.
    /// Enforces a timeout to prevent blocking the agent pipeline indefinitely.
    private func callIC(turnRecords: String, priorSummary: String) async throws -> String {
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

        // Release our hold however this ends (success, empty summary, timeout, cancellation).
        // Compaction was the ONLY IC consumer that never did this, so once it ran the model
        // stayed resident for the app's lifetime unless some other feature happened to free
        // it. `releaseHold` is idle-debounced, so the rest of this turn's IC work (response
        // synthesis) still reuses the same load rather than paying a second one.
        defer { Task { await IntelligenceCoreService.shared.releaseHold(caller: .historyCompaction) } }

        // Race IC inference against a timeout to prevent blocking the agent pipeline.
        let result = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await IntelligenceCoreService.shared.generate(
                    messages: messages,
                    maxTokens: 1024,
                    temperature: 0.3,
                    caller: .historyCompaction
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: self.icTimeoutSeconds * 1_000_000_000)
                throw NSError(
                    domain: "HistoryCompactionService",
                    code: 408,
                    userInfo: [NSLocalizedDescriptionKey: "IC inference timed out after \(self.icTimeoutSeconds)s."]
                )
            }

            // First task to complete wins — the other is cancelled.
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }

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
