//
//  NativeHistoryConverter.swift
//  Devgentic
//
//  Converts ChatMessage history into native user/assistant turn pairs
//  for providers that support turn-by-turn conversation history
//  (Anthropic, OpenAI, Google, Ollama native).
//
//  For each user↔agent pair, emits:
//    {"role": "user", "content": userText}
//    {"role": "assistant", "content": agentText}
//
//  Agent text includes a compact tool summary when tools were used,
//  preserving tool execution context without requiring native tool_call/tool_result roles.
//
//  Token safety: charBudget caps total history size. Oldest turns are dropped first.
//

import Foundation

struct NativeHistoryConverter {

    // MARK: - Checkpoint Extraction

    /// Extracts the latest checkpoint and filters history to only include messages after it.
    /// Returns checkpoint context turn pair (if any) and the filtered history.
    private static func extractCheckpointContext(from history: [ChatMessage]) -> (contextTurns: [[String: String]], filteredHistory: [ChatMessage]) {
        guard let checkpoint = history.last(where: {
            if case .checkpoint = $0.content { return true }
            return false
        }), case .checkpoint(let summary) = checkpoint.content else {
            return ([], history)
        }

        // Filter to only include messages after the checkpoint
        let filtered = history.filter { $0.timestamp > checkpoint.timestamp }

        // Create a context turn pair that injects the checkpoint summary
        let contextTurns: [[String: String]] = [
            ["role": "user", "content": "[Prior conversation summary]:\n\(summary)"],
            ["role": "assistant", "content": "Understood. I have context from the prior conversation."]
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
    /// - Returns: An array of message dictionaries with alternating user/assistant roles.
    static func buildNativeTurns(
        from history: [ChatMessage],
        limit: Int?,
        charBudget: Int
    ) -> [[String: String]] {

        // Extract checkpoint context — if a checkpoint exists, only convert turns after it.
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)

        let pairs = pairMessages(from: filteredHistory)
        guard !pairs.isEmpty else { return contextTurns }

        // Apply turn limit (take most recent)
        let limited: ArraySlice<TurnPair>
        if let limit = limit {
            limited = pairs.suffix(limit)
        } else {
            limited = pairs[pairs.startIndex...]
        }

        // Convert to message dicts
        var candidates: [([String: String], [String: String])] = []
        for pair in limited {
            let userMsg = ["role": "user", "content": pair.userText]
            let assistantMsg = ["role": "assistant", "content": pair.assistantText]
            candidates.append((userMsg, assistantMsg))
        }

        // Apply char budget (newest-first, drop oldest when exceeded)
        var totalChars = 0
        var budgetedPairs: [([String: String], [String: String])] = []

        for pair in candidates.reversed() {
            let pairChars = pair.0["content"]!.count + pair.1["content"]!.count
            if totalChars + pairChars > charBudget {
                break
            }
            totalChars += pairChars
            budgetedPairs.append(pair)
        }

        // Reverse back to chronological order and flatten
        budgetedPairs.reverse()
        var messages: [[String: String]] = contextTurns // Prepend checkpoint context if present
        for (user, assistant) in budgetedPairs {
            messages.append(user)
            messages.append(assistant)
        }

        return messages
    }

    // MARK: - Pointer Turns (Skeleton + Tool Reference)

    /// Builds compact native turn pairs where every assistant message is a skeleton
    /// with tool names and a pointer to `get_conversation_history(index)`.
    /// No charBudget needed — skeletons are minimal.
    static func buildPointerTurns(from history: [ChatMessage]) -> [[String: String]] {
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)
        let pairs = pairMessages(from: filteredHistory)
        guard !pairs.isEmpty else { return contextTurns }

        var messages: [[String: String]] = contextTurns

        for (index, pair) in pairs.enumerated() {
            messages.append(["role": "user", "content": pair.userText])

            // Build compact tool list from the original message
            let toolList = pair.toolNames.isEmpty ? "" : "[\(pair.toolNames.joined(separator: ", "))] "
            let assistant = "\(toolList)Call get_conversation_history(\(index)) for full response."
            messages.append(["role": "assistant", "content": assistant])
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
    static func buildHybridTurns(
        from history: [ChatMessage],
        inlineCount: Int = 3,
        charBudget: Int
    ) -> [[String: String]] {
        // Extract checkpoint context — if a checkpoint exists, only convert turns after it.
        let (contextTurns, filteredHistory) = extractCheckpointContext(from: history)

        let pairs = pairMessages(from: filteredHistory)
        guard !pairs.isEmpty else { return contextTurns }

        let totalPairs = pairs.count
        let pointerCount = max(0, totalPairs - inlineCount)

        var messages: [[String: String]] = contextTurns // Prepend checkpoint context if present

        // Older turns — pointer format
        for index in 0..<pointerCount {
            let pair = pairs[index]
            messages.append(["role": "user", "content": pair.userText])

            let toolList = pair.toolNames.isEmpty ? "" : "[\(pair.toolNames.joined(separator: ", "))] "
            let assistant = "\(toolList)Call get_conversation_history(\(index)) for full response."
            messages.append(["role": "assistant", "content": assistant])
        }

        // Recent turns — full format (with charBudget)
        var recentChars = 0
        var recentMessages: [[String: String]] = []

        for index in (pointerCount..<totalPairs).reversed() {
            let pair = pairs[index]
            let pairChars = pair.userText.count + pair.assistantText.count
            if recentChars + pairChars > charBudget {
                break
            }
            recentChars += pairChars
            recentMessages.insert(["role": "assistant", "content": pair.assistantText], at: 0)
            recentMessages.insert(["role": "user", "content": pair.userText], at: 0)
        }

        messages.append(contentsOf: recentMessages)
        return messages
    }

    // MARK: - Internal Types

    private struct TurnPair {
        let userText: String
        let assistantText: String
        let toolNames: [String]
    }

    // MARK: - Pairing

    /// Pairs consecutive user↔agent messages into logical turns.
    private static func pairMessages(from history: [ChatMessage]) -> [TurnPair] {
        var pairs: [TurnPair] = []
        var pendingUserText: String? = nil

        for message in history {
            if message.sender == .user {
                pendingUserText = message.content.textContent ?? ""

            } else if message.sender == .agent, let userText = pendingUserText {
                let agentText = buildAssistantContent(from: message)

                // Extract tool names for pointer skeleton
                var toolNames: [String] = []
                for event in message.timelineEvents {
                    if case .toolExecution(let data) = event, !data.isExecuting {
                        let status = (data.isSuccess ?? false) ? "" : " | Failed"
                        toolNames.append("\(data.name)\(status)")
                    }
                }

                pairs.append(TurnPair(userText: userText, assistantText: agentText, toolNames: toolNames))
                pendingUserText = nil
            }
        }

        return pairs
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
