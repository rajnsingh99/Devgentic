// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  AnthropicPromptCaching.swift
//  Devgentic
//
//  Claude caches nothing unless a request marks where its reusable prefix ends — a
//  `cache_control` breakpoint on a content block. Every other provider we use caches a shared
//  prefix on its own (MLX through `MLXPromptCache`, Ollama, OpenAI, Gemini); layout B
//  (`PromptBuilder`) is what makes that prefix the same from one request to the next. This marks
//  it for Claude.
//
//  Anthropic caches in order tools → system → messages, so one breakpoint covers everything
//  before it. A read needs an EARLIER request to have written an entry at that exact position, and
//  the API looks back about 20 content blocks from each breakpoint for one. So each breakpoint here
//  sits where the NEXT request will share the prefix:
//
//   1. The end of the system message — stable for the conversation (layout B). Every request of the
//      conversation reads the tools and the system message back from here.
//   2. The last turn BEFORE the current one — the conversation so far. The next message's request
//      carries the same turns plus two new ones, so it reads up to here. (The current turn itself is
//      never reused: next time it reappears as plain history, without its turn context.)
//   3. The end of the request — ONLY when tools are offered, i.e. an agent loop that will send this
//      request again with a tool result appended. Iteration N+1 reads all of iteration N.
//
//  A write costs 1.25× plain input, a read 0.1× (priced per model by `ModelPriceList`). A prefix below the model's minimum
//  (about 1,024 tokens; more on Haiku) is simply not cached — no error, no charge.
//
//  ⚠️ Not applied to one-off calls (`generate(messages:)`: planning, reflection, synthesis, titles,
//  the memory suggestion pass). Nothing sends their prompt twice, so a breakpoint would be a pure
//  25% surcharge on it.
//

import Foundation

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
