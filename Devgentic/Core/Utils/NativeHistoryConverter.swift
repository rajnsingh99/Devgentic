//
//  NativeHistoryConverter.swift
//  Devgentic
//
//  Converts ChatMessage history into native user/assistant turn pairs
//  for providers that support turn-by-turn conversation history
//  (Anthropic, OpenAI, Google, Ollama native).
//
//  For each user↔agent pair, emits a `HistoryTurn` per side:
//    HistoryTurn(role: .user,      parts: [.text(userText), .media(image)…])
//    HistoryTurn(role: .assistant, parts: [.text(agentText)])
//
//  Agent text is PROSE ONLY — no tool summary. `buildAssistantContent` used to prepend
//  `[Used: tool(args) → result]` lines, and models reliably imitated the format instead of
//  calling tools, inventing markers and fabricating outputs. Tool-execution context lives
//  in the system prompt's `<episodic_memory>` XML (`EpisodicHistoryFormatter`) instead.
//
//  IMAGES: a user turn carries `.media` parts for every image attached to that
//  message, so a follow-up question about an image sent two turns ago still sees
//  it. Bytes are NOT loaded here — `.media` holds a `MediaReference`, resolved
//  lazily at request-build only for turns that survive the budget. Images ride
//  the same window trimming text gets: when a turn ages out, its images age out
//  with it. No most-recent-only policy, no image-special tiers.
//
//  Token safety: charBudget caps total history size. Oldest turns are dropped
//  first. Images weigh a flat token-realistic figure (`ImageTokenHeuristic`), NOT
//  their base64 length — otherwise one screenshot would evict a whole conversation.
//

import Foundation
import os

struct NativeHistoryConverter {

    private static let logger = Logger(subsystem: "com.devgentic", category: "NativeHistoryConverter")

    // MARK: - Checkpoint Extraction

    /// Extracts the latest checkpoint and filters history to only include messages after it.
    /// Returns checkpoint context turn pair (if any) and the filtered history.
    private static func extractCheckpointContext(from history: [ChatMessage]) -> (contextTurns: [HistoryTurn], filteredHistory: [ChatMessage]) {
        guard let checkpoint = history.last(where: {
            if case .checkpoint = $0.content { return true }
            return false
        }), case .checkpoint(let summary) = checkpoint.content else {
            return ([], history)
        }

        // Filter to only include messages after the checkpoint
        let filtered = history.filter { $0.timestamp > checkpoint.timestamp }

        // Create a context turn pair that injects the checkpoint summary
        let contextTurns: [HistoryTurn] = [
            HistoryTurn(role: .user, text: "[Prior conversation summary]:\n\(summary)"),
            HistoryTurn(role: .assistant, text: "Understood. I have context from the prior conversation.")
        ]

        return (contextTurns, filtered)
    }

    /// Converts ChatMessage history into native turn pairs for LLM API injection.
    ///
    /// - Parameters:
    ///   - history: The array of ChatMessages from the conversation.
    ///   - limit: Maximum number of turn pairs to include. Nil = all turns.
    ///   - charBudget: Maximum total character count for all history messages.
    ///     Oldest turns are dropped first when budget is exceeded.
    ///   - includeImages: Whether user turns may carry `.media` image parts. Callers
    ///     pass `false` when the target model can't see images (vision gate), so the
    ///     budget reflects what will actually be sent.
    /// - Returns: An array of `HistoryTurn` with alternating user/assistant roles.
    /// The ONE place a history strategy becomes native turn pairs.
    ///
    /// `AgentConnect` builds the request through this and the fit gauges size the request
    /// through it, so what they measure is what ships. The episodic channel already works
    /// this way (`EpisodicHistoryFormatter.build`); before that, four hand-rolled copies of
    /// the same switch drifted and silently lost content on one of them.
    ///
    /// - Parameter correlation: nil-equivalent ("") for measurement — the builders only log
    ///   when given one, so sizing the prompt does not emit trim warnings for prompts that
    ///   were never sent.
    static func build(
        strategy: HistoryStrategy,
        from history: [ChatMessage],
        charBudget: Int,
        includeImages: Bool = false,
        correlation: String = ""
    ) -> [HistoryTurn] {
        switch strategy {
        case .recentHistory:
            return buildNativeTurns(from: history, limit: EpisodicHistoryFormatter.recentTurnLimit,
                                    charBudget: charBudget, includeImages: includeImages,
                                    correlation: correlation)
        case .fullHistory:
            return buildNativeTurns(from: history, limit: nil, charBudget: charBudget,
                                    includeImages: includeImages, correlation: correlation)
        case .pointer:
            return buildPointerTurns(from: history, includeImages: includeImages,
                                     correlation: correlation)
        case .hybrid:
            return buildHybridTurns(from: history, inlineCount: EpisodicHistoryFormatter.hybridInlineCount,
                                    charBudget: charBudget, includeImages: includeImages,
                                    correlation: correlation)
        }
    }

    static func buildNativeTurns(
        from history: [ChatMessage],
        limit: Int?,
        charBudget: Int,
        includeImages: Bool = false,
        correlation: String = ""
    ) -> [HistoryTurn] {

        // Extract checkpoint context — if a checkpoint exists, only convert turns after it.
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)

        let pairs = pairMessages(from: filteredHistory, includeImages: includeImages)
        guard !pairs.isEmpty else { return contextTurns }

        // Apply turn limit (take most recent)
        let limited: ArraySlice<TurnPair>
        if let limit = limit {
            limited = pairs.suffix(limit)
        } else {
            limited = pairs[pairs.startIndex...]
        }

        // Convert to turns
        var candidates: [(HistoryTurn, HistoryTurn)] = []
        for pair in limited {
            candidates.append((pair.userTurn, pair.assistantTurn))
        }

        // Apply char budget (newest-first, drop oldest when exceeded)
        var totalChars = 0
        var budgetedPairs: [(HistoryTurn, HistoryTurn)] = []

        for pair in candidates.reversed() {
            let pairChars = pair.0.budgetChars + pair.1.budgetChars
            if totalChars + pairChars > charBudget {
                break
            }
            totalChars += pairChars
            budgetedPairs.append(pair)
        }

        // Reverse back to chronological order and flatten
        budgetedPairs.reverse()
        var messages: [HistoryTurn] = contextTurns // Prepend checkpoint context if present
        for (user, assistant) in budgetedPairs {
            messages.append(user)
            messages.append(assistant)
        }

        logTrim(strategy: "native", candidates: candidates.count, kept: budgetedPairs.count, chars: totalChars, budget: charBudget, turns: messages, correlation: correlation)
        return messages
    }

    // MARK: - Pointer Turns (Skeleton + Tool Reference)

    /// Builds compact native turn pairs where every assistant message is a skeleton
    /// with tool names and a pointer to `get_conversation_history(index)`.
    /// No charBudget needed — skeletons are minimal.
    ///
    /// ⚠️ This strategy has no budget seam, so image parts would be UNBOUNDED here.
    /// Images are therefore never attached on the pointer path — the whole point of
    /// pointers is a minimal payload. `includeImages` is accepted for call-site
    /// symmetry and deliberately ignored; the omission is logged.
    static func buildPointerTurns(from history: [ChatMessage], includeImages: Bool = false, correlation: String = "") -> [HistoryTurn] {
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)
        let pairs = pairMessages(from: filteredHistory, includeImages: false)
        guard !pairs.isEmpty else { return contextTurns }

        if includeImages {
            // Count attachments straight off the source messages. Re-running
            // pairMessages purely to tally them would rebuild every assistant
            // prose string on a hot path and throw the result away.
            let dropped = filteredHistory.reduce(0) { total, message in
                total + (message.sender == .user ? (message.attachedImageFiles?.count ?? 0) : 0)
            }
            if dropped > 0 {
                logger.info("[HISTORY] \(correlation) omitted \(dropped) history image(s): pointer strategy carries skeletons only (no char budget to bound them) — model will not see prior-turn images this request")
            }
        }

        var messages: [HistoryTurn] = contextTurns

        for (index, pair) in pairs.enumerated() {
            messages.append(pair.userTurn)

            // Build compact tool list from the original message
            let toolList = pair.toolNames.isEmpty ? "" : "[\(pair.toolNames.joined(separator: ", "))] "
            let assistant = "\(toolList)Call get_conversation_history(\(index)) for full response."
            messages.append(HistoryTurn(role: .assistant, text: assistant))
        }

        return messages
    }

    // MARK: - Hybrid Turns (Recent Full + Older Pointers)

    /// Builds native turn pairs with a split strategy:
    /// - Older turns: pointer skeletons (compact tool list + pointer)
    /// - Recent turns (last `inlineCount`): full content with tool summaries and response text
    ///
    /// - Parameters:
    ///   - history: The array of ChatMessages.
    ///   - inlineCount: Number of most recent turns with full content (default 3).
    ///   - charBudget: Character budget applied only to the full inline turns.
    ///   - includeImages: Images attach only to the budgeted RECENT turns, never to
    ///     the unbudgeted pointer segment (same rationale as `buildPointerTurns`).
    static func buildHybridTurns(
        from history: [ChatMessage],
        inlineCount: Int = 3,
        charBudget: Int,
        includeImages: Bool = false,
        correlation: String = ""
    ) -> [HistoryTurn] {
        // Extract checkpoint context — if a checkpoint exists, only convert turns after it.
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)

        let pairs = pairMessages(from: filteredHistory, includeImages: includeImages)
        guard !pairs.isEmpty else { return contextTurns }

        let totalPairs = pairs.count
        let pointerCount = max(0, totalPairs - inlineCount)

        var messages: [HistoryTurn] = contextTurns // Prepend checkpoint context if present

        // Older turns — pointer format. Strip media: this segment has no budget.
        var pointerDroppedImages = 0
        for index in 0..<pointerCount {
            let pair = pairs[index]
            pointerDroppedImages += pair.userTurn.imageMedia.count
            messages.append(HistoryTurn(role: .user, text: pair.userTurn.text))

            let toolList = pair.toolNames.isEmpty ? "" : "[\(pair.toolNames.joined(separator: ", "))] "
            let assistant = "\(toolList)Call get_conversation_history(\(index)) for full response."
            messages.append(HistoryTurn(role: .assistant, text: assistant))
        }
        if pointerDroppedImages > 0 {
            logger.info("[HISTORY] \(correlation) omitted \(pointerDroppedImages) image(s) from the hybrid pointer segment (unbudgeted skeletons) — model will not see those prior-turn images")
        }

        // Recent turns — full format (with charBudget)
        var recentChars = 0
        var recentMessages: [HistoryTurn] = []

        for index in (pointerCount..<totalPairs).reversed() {
            let pair = pairs[index]
            let pairChars = pair.userTurn.budgetChars + pair.assistantTurn.budgetChars
            if recentChars + pairChars > charBudget {
                break
            }
            recentChars += pairChars
            recentMessages.insert(pair.assistantTurn, at: 0)
            recentMessages.insert(pair.userTurn, at: 0)
        }

        messages.append(contentsOf: recentMessages)
        logTrim(strategy: "hybrid", candidates: totalPairs - pointerCount, kept: recentMessages.count / 2, chars: recentChars, budget: charBudget, turns: messages, correlation: correlation)
        return messages
    }

    // MARK: - Budget Logging

    /// The converter used to trim silently. A conversation could lose its oldest
    /// turns with nothing in the log to distinguish "trimmed to fit" from "there
    /// was nothing to include" — and now that images carry weight, a single large
    /// attachment can push several text turns out. Log the drop and its cause.
    private static func logTrim(strategy: String, candidates: Int, kept: Int, chars: Int, budget: Int, turns: [HistoryTurn], correlation: String) {
        let images = turns.totalImageCount
        if kept < candidates {
            logger.info("[HISTORY] \(correlation) \(strategy): trimmed to \(kept)/\(candidates) turn pair(s) — \(chars)/\(budget) chars, \(images) image(s) carried; older turns dropped to fit the budget and are NOT visible to the model")
        } else if images > 0 {
            logger.info("[HISTORY] \(correlation) \(strategy): \(kept) turn pair(s), \(chars)/\(budget) chars, \(images) image(s) carried")
        }
    }

    // MARK: - Internal Types

    private struct TurnPair {
        let userTurn: HistoryTurn
        let assistantTurn: HistoryTurn
        let toolNames: [String]
    }

    // MARK: - Pairing

    /// Pairs consecutive user↔agent messages into logical turns.
    ///
    /// Images attach to the USER side only — assistant turns never carry media.
    private static func pairMessages(from history: [ChatMessage], includeImages: Bool) -> [TurnPair] {
        var pairs: [TurnPair] = []
        var pendingUser: HistoryTurn? = nil

        for message in history {
            if message.sender == .user {
                let text = message.content.textContent ?? ""
                var parts: [HistoryTurn.Part] = [.text(text)]
                if includeImages {
                    parts.append(contentsOf: mediaParts(for: message))
                }
                pendingUser = HistoryTurn(role: .user, parts: parts)

            } else if message.sender == .agent, let userTurn = pendingUser {
                let agentText = buildAssistantContent(from: message)

                // Extract tool names for pointer skeleton
                var toolNames: [String] = []
                for event in message.flattenedTimelineEvents {
                    if case .toolExecution(let data) = event, !data.isExecuting {
                        let status = (data.isSuccess ?? false) ? "" : " | Failed"
                        toolNames.append("\(data.name)\(status)")
                    }
                }

                pairs.append(TurnPair(
                    userTurn: userTurn,
                    assistantTurn: HistoryTurn(role: .assistant, text: agentText),
                    toolNames: toolNames
                ))
                pendingUser = nil
            }
        }

        return pairs
    }

    /// Builds `.media` parts for a user message's attached images.
    ///
    /// BYTES-FIRST resolution order: the persisted `binaryData` blob wins over the
    /// source `url`. The URL leg is unreliable after relaunch — we persist raw URL
    /// strings, not security-scoped bookmarks, so a moved/deleted file or a lapsed
    /// sandbox scope makes it unreadable. The blob is durable by construction.
    private static func mediaParts(for message: ChatMessage) -> [HistoryTurn.Part] {
        guard let images = message.attachedImageFiles, !images.isEmpty else { return [] }
        return images.map { file in
            let reference: MediaReference = file.binaryData.isEmpty
                ? .diskPath(file.url)
                : .ephemeralData(file.binaryData)
            if file.binaryData.isEmpty {
                logger.info("[HISTORY] image '\(file.name)' has no persisted bytes — falling back to disk path \(file.url.path), which may be stale after relaunch")
            }
            return .media(kind: .image, reference: reference, label: file.name)
        }
    }

    // MARK: - Assistant Content Builder

    /// Builds the assistant message content — **prose response text only**.
    ///
    /// Prior iterations of this function prepended `[Used: tool(args) → result]`
    /// summaries before the response. Models reliably mimic this format in their
    /// next response, inventing fake `[Used:]` markers and fabricating tool
    /// outputs. Tool-execution context now lives in the system-prompt's
    /// `<episodic_memory>` XML (built by `EpisodicHistoryFormatter`), so this
    /// function keeps the assistant turn clean of anything resembling a
    /// structural tool call.
    private static func buildAssistantContent(from message: ChatMessage) -> String {
        message.content.textContent ?? ""
    }
}
