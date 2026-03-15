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

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MistralXMLParser")

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
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: toolCalls)
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
                        let cleanedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let call = decodeSingleCall(cleanedPayload) {
                            results.append(call)
                        }
                    }
                }
            }
        }

        // Style 2: [TOOL_CALLS] [...]  — extract the JSON array after the tag
        if results.isEmpty, let markerRange = text.range(of: "[TOOL_CALLS]", options: .caseInsensitive) {
            let afterMarker = String(text[markerRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Find the opening bracket of the JSON array
            if let arrayStart = afterMarker.firstIndex(of: "["),
               let data = afterMarker[arrayStart...].data(using: .utf8),
               let calls = try? JSONDecoder().decode([MistralToolCall].self, from: data) {
                results = calls.map {
                    PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
                }
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
            if let data = cleanArgs.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                arguments = decoded
            } else {
                logger.warning("MistralXMLParser: Failed to decode hybrid JSON arguments: \(cleanArgs.prefix(100))")
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
                logger.warning("MistralXMLParser: Failed to decode fallback payload: \(payload.prefix(200))")
                return nil
            }
            return PendingToolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments)
        }
        return PendingToolCall(id: UUID().uuidString, name: call.name, arguments: call.arguments)
    }
}
