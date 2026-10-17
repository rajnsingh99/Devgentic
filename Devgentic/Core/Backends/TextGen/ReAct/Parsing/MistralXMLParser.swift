// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MistralXMLParser.swift
//  Devgentic
//
//  Step 3.2: Parser for the .mistralXML dialect.
//  Target: Pseudo-XML wrapping used by some Mistral variants.
//  Extracts the content, tool_name, and JSON arguments payload residing between <tool_call>...</tool_call> boundaries.
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MistralXMLParser")

struct MistralXMLParser: CognitiveParserProtocol {

    // Schemas for the old legacy JSON payload fallback
    private struct MistralToolCall: Decodable {
        let name: String
        let arguments: [String: JSONValue]
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        // 1. Extract tool calls and any embedded content using both marker styles
        let (embeddedContent, toolCalls) = extractToolCallsAndContent(from: rawResponse)

        // 2. Extract reasoning: Priority 1: Top-level <content>. Priority 2: Embedded <content>. Priority 3: Fallback extraction.
        let topLevelContent = extractTag("content", from: rawResponse)
        let reasoning = topLevelContent ?? embeddedContent ?? extractReasoningFallback(from: rawResponse)

        if !toolCalls.isEmpty {
            logger.info("MistralXMLParser: Extracted \(toolCalls.count) tool call(s).")
            // Filter template-stub narration ("Calling X…") out of the with-tools reasoning so
            // it doesn't pollute the working-memory scratchpad (#15 / G7). The termination path
            // below is deliberately NOT filtered — there the text is the final answer.
            return ModernCognitiveStep(reasoning: ReasoningQualityFilter.filter(reasoning), toolCalls: toolCalls)
        }

        // 3. No XML tool markers found — treat as a plain text (termination) response
        logger.warning("MistralXMLParser: No tool markers found. Treating as conversational exit.")
        return ModernCognitiveStep(reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines), toolCalls: [])
    }

    // MARK: - Private Extraction Helpers

    private func extractToolCallsAndContent(from text: String) -> (String?, [PendingToolCall]) {
        var results: [PendingToolCall] = []
        var reasoningText: String? = nil

        // Style 1: <tool_call>...
        let xmlPattern = #"<tool_call>([\s\S]*?)</tool_call>"#
        if let regex = try? NSRegularExpression(pattern: xmlPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                if let payloadRange = Range(match.range(at: 1), in: text) {
                    let payload = String(text[payloadRange])

                    // Attempt to extract new hybrid tags
                    let contentTag = extractTag("content", from: payload)
                    let toolNameTag = extractTag("tool_name", from: payload)
                    let argsTag = extractTag("arguments", from: payload)

                    // Capture the first <content> found as the primary reasoning
                    if let c = contentTag, reasoningText == nil {
                        reasoningText = c
                    }

                    if let tName = toolNameTag, let tArgs = argsTag {
                        // New Hybrid XML Format detected
                        let call = decodeHybridCall(name: tName, argsString: tArgs)
                        results.append(call)
                    } else {
                        // Fallback: old Mistral JSON format inside <tool_call>
                        var cleanedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Strip CDATA wrapper if present: <![CDATA[...]]> → ...
                        if cleanedPayload.hasPrefix("<![CDATA[") && cleanedPayload.hasSuffix("]]>") {
                            cleanedPayload = String(cleanedPayload.dropFirst(9).dropLast(3))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if let call = decodeSingleCall(cleanedPayload) {
                            results.append(call)
                        }
                    }
                }
            }
        }

        // Style 1b: <tool_call name="..." attr="..." /> — attribute-style self-closing XML
        if results.isEmpty {
            let attrPattern = #"<tool_call\s+([^>]*?)/>"#
            if let regex = try? NSRegularExpression(pattern: attrPattern, options: .caseInsensitive) {
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if let attrsRange = Range(match.range(at: 1), in: text) {
                        let attrsString = String(text[attrsRange])
                        if let call = parseAttributeStyleCall(attrsString) {
                            results.append(call)
                        }
                    }
                }
            }
        }

        // Style 2: [TOOL_CALLS] [...]  — extract JSON arrays after each marker.
        //   Handles multiple markers on separate lines by segmenting between markers.
        if results.isEmpty {
            let marker = "[TOOL_CALLS]"
            let segments = text.components(separatedBy: marker).dropFirst() // skip text before first marker
            for segment in segments {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                // String/escape-aware balanced `[...]` scan (#15): a `]` inside a JSON string
                // value must not terminate the array early (the old inline scan had no string-state).
                guard let arraySlice = BalancedJSONScanner.firstArray(in: trimmed) else { continue }
                guard let data = arraySlice.data(using: .utf8),
                      let calls = try? JSONDecoder().decode([MistralToolCall].self, from: data) else { continue }
                results.append(contentsOf: calls.map {
                    PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
                })
            }
        }

        return (reasoningText, results)
    }

    private func extractTag(_ tag: String, from text: String) -> String? {
        let pattern = #"<\#(tag)>([\s\S]*?)</\#(tag)>"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func extractReasoningFallback(from text: String) -> String {
        // Grab any text that appears before the first XML/bracket tool marker
        let markers = ["<tool_call>", "[TOOL_CALLS]"]
        for marker in markers {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { return before }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHybridCall(name: String, argsString: String) -> PendingToolCall {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String: JSONValue] = [:]

        // Try decoding the JSON arguments inside the <arguments> tag
        let cleanArgs = argsString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanArgs.isEmpty && cleanArgs != "{}" {
            // CR-19: the shared repairs (raw newlines, invalid escapes, trailing commas) first.
            if let decoded = JSONStructuralSanitizer.decodeObject(cleanArgs) {
                arguments = decoded
            } else {
                logger.warning("MistralXMLParser: Failed to decode hybrid JSON arguments: \(cleanArgs.count) chars (snippet at debug: model output is content, CR-57)")
                logger.debug("MistralXMLParser: snippet: \(cleanArgs.prefix(100))")
            }
        }
        return PendingToolCall(id: UUID().uuidString, name: cleanName, arguments: arguments)
    }

    private func decodeSingleCall(_ payload: String) -> PendingToolCall? {
        guard let data = payload.data(using: .utf8),
              let call = try? JSONDecoder().decode(MistralToolCall.self, from: data) else {
            // Clean trailing characters (Mistral sometimes appends stray chars)
            let cleaned = payload.trimmingCharacters(in: .init(charactersIn: " \t\n\r,;"))
            guard let cleanData = cleaned.data(using: .utf8),
                  let call = try? JSONDecoder().decode(MistralToolCall.self, from: cleanData) else {
                logger.warning("MistralXMLParser: Failed to decode fallback payload: \(payload.count) chars (snippet at debug: model output is content, CR-57)")
                logger.debug("MistralXMLParser: snippet: \(payload.prefix(200))")
                return nil
            }
            return PendingToolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments)
        }
        return PendingToolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments)
    }

    /// Parses attribute-style XML: `<tool_call name="list_directory" path="/tmp" />`
    /// Extracts `name` as the tool name and all other attributes as arguments.
    private func parseAttributeStyleCall(_ attrsString: String) -> PendingToolCall? {
        let attrPattern = #"(\w+)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: attrPattern) else { return nil }
        let matches = regex.matches(in: attrsString, range: NSRange(attrsString.startIndex..., in: attrsString))

        var toolName: String?
        var arguments: [String: JSONValue] = [:]

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: attrsString),
                  let valRange = Range(match.range(at: 2), in: attrsString) else { continue }
            let key = String(attrsString[keyRange])
            let val = String(attrsString[valRange])

            if key == "name" {
                toolName = val
            } else {
                arguments[key] = .string(val)
            }
        }

        guard let name = toolName, !name.isEmpty else { return nil }
        return PendingToolCall(id: UUID().uuidString, name: name, arguments: arguments)
    }
}
