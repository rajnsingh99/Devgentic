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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "HistoryCompaction")

// MARK: - Compaction Result

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
/// checkpoint summaries when triggered. Runs synchronously before the agent so the
/// current request immediately benefits from the compacted history.
actor HistoryCompactionService {

    static let shared = HistoryCompactionService()

    /// Minimum turns since last checkpoint before compaction is considered.
    private let minTurnThreshold = 15

    /// History char usage ratio that triggers compaction (0.0–1.0).
    /// Compaction triggers when estimated history chars exceed this fraction of charBudget.
    private let charBudgetTriggerRatio = 0.6

    /// Overhead reserved for the system prompt + output in the IC model's context.
    private let icPromptOverheadChars = 800

    private init() {}

    // MARK: - Public API

    /// Evaluates whether compaction is needed and produces a checkpoint if so.
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

        // Pair into user↔agent turn pairs for counting.
        let turnPairCount = turnsAfterCheckpoint.filter { $0.sender == .user }.count

        guard turnPairCount >= minTurnThreshold else {
            logger.debug("Compaction skipped: only \(turnPairCount) turns since last checkpoint (threshold: \(self.minTurnThreshold)).")
            return nil
        }

        // Step 3: Estimate char size of pending turns.
        let estimatedChars = turnsAfterCheckpoint.reduce(0) { $0 + ($1.content.textContent?.count ?? 0) }

        guard estimatedChars > Int(Double(charBudget) * charBudgetTriggerRatio) else {
            logger.debug("Compaction skipped: estimated chars \(estimatedChars) below trigger (\(Int(Double(charBudget) * self.charBudgetTriggerRatio))).")
            return nil
        }

        // Step 4: Resolve IC model's context window for adaptive batch sizing.
        let icContextWindow = await resolveICContextWindow()

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

        guard turnsToCompact.count >= 4 else { // At least 2 turn pairs worth compacting
            logger.debug("Compaction skipped: batch too small (\(turnsToCompact.count) messages).")
            return nil
        }

        let turnPairsInBatch = turnsToCompact.filter { $0.sender == .user }.count
        logger.notice("Compaction triggered: \(turnPairsInBatch) turn pairs, ~\(estimatedChars) chars. IC context: \(icContextWindow) tokens.")

        // Step 7: Build the IC prompt and call generate().
        let turnRecords = formatTurnsForIC(turnsToCompact)
        let summary = try await callIC(turnRecords: turnRecords, priorSummary: priorSummary)

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
    private func findLatestCheckpoint(in history: [ChatMessage]) -> ChatMessage? {
        history.last(where: {
            if case .checkpoint = $0.content { return true }
            return false
        })
    }

    /// Counts existing checkpoints in the history.
    private func countCheckpoints(in history: [ChatMessage]) -> Int {
        history.filter {
            if case .checkpoint = $0.content { return true }
            return false
        }.count
    }

    /// Extracts the summary text from a checkpoint message.
    private func extractCheckpointSummary(from message: ChatMessage) -> String? {
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
    private func calculateBatch(
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
            case .error(let title, let details): text = "\(title ?? "Error"): \(details)"
            case .image(_, let alt, _): text = "[Image: \(alt ?? "image attachment")]"
            case .mediaArtifact(let a): text = "[Media: \(a.label ?? a.kind.rawValue)]"
            case .checkpoint: continue // Already handled above
            }
            let truncated = text.count > 500 ? String(text.prefix(500)) + "..." : text

            // Include tool summaries for agent messages
            var toolInfo = ""
            if msg.sender == .agent && !msg.timelineEvents.isEmpty {
                let tools = msg.timelineEvents.compactMap { event -> String? in
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

    /// Maximum time allowed for IC inference before the compaction is aborted.
    /// Prevents blocking the agent pipeline on slow machines or large models.
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
