// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  CodeFenceShield.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation

// Why: the sanitizer's blanket fence strip cannot be dropped (parsers rely on it) but would corrupt argument values.
/// Keeps code fences inside a tool call's JSON string values out of reach of the fence stripper.
/// Before parsing, each ``` inside a JSON string literal of a balanced `{…}` becomes a placeholder, restored afterwards.
/// A fence that wraps a call is outside every literal and is still stripped. Non-JSON-string dialects are not covered.
enum CodeFenceShield {

    /// Three private-use scalars. A model cannot produce them by accident, they survive JSON
    /// decoding untouched, and no sanitizer step or parser matches them.
    static let placeholder = "\u{E000}\u{E0F0}\u{E000}"

    private static let fence = "```"

    /// The text with every ``` inside a JSON string literal replaced, and how many were replaced.
    static func shield(_ text: String) -> (text: String, count: Int) {
        guard text.contains(fence) else { return (text, 0) }
        var output = ""
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let object = BalancedJSONScanner.balancedRange(in: text, from: cursor, opener: "{") {
            output += text[cursor..<object.lowerBound]
            let (shieldedObject, replaced) = shieldingStringLiterals(in: text[object])
            output += shieldedObject
            count += replaced
            cursor = object.upperBound
        }
        output += text[cursor...]
        return (output, count)
    }

    /// Walks one balanced object with the scanner's own string/escape rules.
    private static func shieldingStringLiterals(in object: Substring) -> (String, Int) {
        var output = ""
        var count = 0
        var inString = false
        var escaped = false
        var index = object.startIndex
        while index < object.endIndex {
            let c = object[index]
            if inString, !escaped, object[index...].hasPrefix(fence) {
                output += placeholder
                count += 1
                index = object.index(index, offsetBy: fence.count)
                continue
            }
            if escaped { escaped = false }
            else if c == "\\" && inString { escaped = true }
            else if c == "\"" { inString.toggle() }
            output.append(c)
            index = object.index(after: index)
        }
        return (output, count)
    }

    static func unshield(_ text: String) -> String {
        text.replacingOccurrences(of: placeholder, with: fence)
    }

    static func unshield(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(unshield(text))
        case .array(let items): return .array(items.map(unshield))
        case .object(let fields): return .object(fields.mapValues(unshield))
        case .number, .bool, .null: return value
        }
    }

    /// The step with the placeholder turned back into ``` everywhere text reaches the run.
    static func unshield(_ step: ModernCognitiveStep) -> ModernCognitiveStep {
        ModernCognitiveStep(
            reasoning: unshield(step.reasoning),
            thought: step.thought.map(unshield),
            toolCalls: step.toolCalls.map {
                PendingToolCall(id: $0.id, name: $0.name, arguments: $0.arguments.mapValues(unshield))
            },
            tokenUsage: step.tokenUsage,
            parseOutcome: step.parseOutcome,
            reasoningReplay: step.reasoningReplay,
            callsRecoveredFromText: step.callsRecoveredFromText.map(unshield),
            // Carried through, or every rejected sibling call would be dropped here.
            rejectedCalls: step.rejectedCalls.map {
                RejectedSiblingCall(
                    call: PendingToolCall(id: $0.call.id, name: $0.call.name, arguments: $0.call.arguments.mapValues(unshield)),
                    reason: $0.reason)
            }
        )
    }
}
