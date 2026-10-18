// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicPromptCaching.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

/// Marks `cache_control` breakpoints on Claude requests so the stable prefix (tools, system, earlier turns) is cached.
/// Not applied to one-off calls, whose prompt is never sent twice.
enum AnthropicPromptCaching {

    static let breakpoint: [String: Any] = ["type": "ephemeral"]

    /// The API rejects a request with more than four breakpoints.
    static let maxBreakpoints = 4

    /// Marks `body`'s reusable prefix in place. `body` is a finished Messages API body whose
    /// `system` is a string (or absent) and whose `messages` hold string or block-array content.
    /// - Returns: how many breakpoints were set, for the request log.
    @discardableResult
    static func markBreakpoints(in body: inout [String: Any]) -> Int {
        var count = 0

        // 1. The system message.
        if let system = body["system"] as? String, !system.isEmpty {
            body["system"] = [["type": "text", "text": system, "cache_control": breakpoint]]
            count += 1
        }

        guard var messages = body["messages"] as? [[String: Any]], !messages.isEmpty else { return count }

        // 2. The last turn before the current one. The current turn starts at the last user message
        //    that is not a tool result: a bot's question, or an agent run's kickoff turn.
        var marked = Set<Int>()
        if let current = messages.lastIndex(where: { isUserTurn($0) }), current > 0,
           let message = marking(messages[current - 1]) {
            messages[current - 1] = message
            marked.insert(current - 1)
            count += 1
        }

        // 3. The end of the request, when this is an agent loop that will be sent again.
        let offersTools = (body["tools"] as? [[String: Any]])?.isEmpty == false
        let last = messages.count - 1
        if offersTools, !marked.contains(last), count < maxBreakpoints, let message = marking(messages[last]) {
            messages[last] = message
            count += 1
        }

        body["messages"] = messages
        return count
    }

    /// A user message that starts a turn — not a `tool_result` carrier on an agent loop.
    private static func isUserTurn(_ message: [String: Any]) -> Bool {
        guard message["role"] as? String == "user" else { return false }
        guard let blocks = message["content"] as? [[String: Any]] else { return true }
        return !blocks.contains { $0["type"] as? String == "tool_result" }
    }

    /// `message` with a breakpoint on its last markable block, or nil when it has none. A string
    /// becomes a one-block array. Thinking blocks cannot carry a breakpoint, and the API rejects an
    /// empty text block, so neither is marked.
    private static func marking(_ message: [String: Any]) -> [String: Any]? {
        var message = message
        if let text = message["content"] as? String {
            guard !text.isEmpty else { return nil }
            message["content"] = [["type": "text", "text": text, "cache_control": breakpoint]]
            return message
        }
        guard var blocks = message["content"] as? [[String: Any]],
              let index = blocks.lastIndex(where: isMarkable) else { return nil }
        blocks[index]["cache_control"] = breakpoint
        message["content"] = blocks
        return message
    }

    private static func isMarkable(_ block: [String: Any]) -> Bool {
        switch block["type"] as? String {
        case "thinking", "redacted_thinking": return false
        case "text": return !((block["text"] as? String)?.isEmpty ?? true)
        default: return true
        }
    }
}
