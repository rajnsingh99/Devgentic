//
//  YAMLInXMLParser.swift
//  Devgentic
//
//  Fallback parser for YAML-in-XML format where tool calls are wrapped
//  in <tool_calls> tags but the body uses YAML list syntax instead of JSON.
//  Expected format:
//    <tool_calls>
//    - name: tool_name
//      arguments:
//        key1: value1
//        key2: value2
//    </tool_calls>
//
//  Created by Raj Singh on 10/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "YAMLInXMLParser")

/// Parses YAML-in-XML hybrid format — XML wrapper tags with YAML list bodies.
struct YAMLInXMLParser: CognitiveParserProtocol {

    func parse(rawResponse: String) -> ModernCognitiveStep {
        var reasoning = ""
        var toolCalls: [PendingToolCall] = []

        // Extract reasoning: text before <tool_calls>
        if let tagStart = rawResponse.range(of: "<tool_calls>", options: .caseInsensitive) {
            reasoning = String(rawResponse[..<tagStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract YAML body between <tool_calls>...</tool_calls>
        guard let regex = try? NSRegularExpression(
            pattern: #"<tool_calls>([\s\S]*?)</tool_calls>"#,
            options: .caseInsensitive
        ),
              let match = regex.firstMatch(
                in: rawResponse,
                range: NSRange(rawResponse.startIndex..., in: rawResponse)
              ),
              let bodyRange = Range(match.range(at: 1), in: rawResponse) else {
            logger.warning("YAMLInXMLParser: Could not extract <tool_calls> body.")
            return ModernCognitiveStep(reasoning: rawResponse, toolCalls: [])
        }

        let yamlBody = String(rawResponse[bodyRange])

        // Split on "- name:" entries (each starts a new tool call)
        let entries = yamlBody.components(separatedBy: "- name:").dropFirst()

        for entry in entries {
            let lines = entry.components(separatedBy: "\n")
            guard let firstLine = lines.first else { continue }

            let toolName = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !toolName.isEmpty else { continue }

            var arguments: [String: JSONValue] = [:]
            var inArguments = false

            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.hasPrefix("arguments:") {
                    // Check for inline JSON after "arguments:"
                    let afterColon = String(trimmed.dropFirst("arguments:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if afterColon.hasPrefix("{"),
                       let data = afterColon.data(using: .utf8),
                       let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
                        arguments = decoded
                        break
                    }
                    inArguments = true
                    continue
                }

                if inArguments {
                    // Stop if we hit a non-indented, non-empty line (next entry or end)
                    if !line.hasPrefix("  ") && !line.hasPrefix("\t") && !trimmed.isEmpty {
                        break
                    }
                    // Parse "key: value" pairs
                    if let colonIdx = trimmed.range(of: ":") {
                        let key = String(trimmed[..<colonIdx.lowerBound])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let val = String(trimmed[colonIdx.upperBound...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !key.isEmpty {
                            arguments[key] = JSONValue.string(val)
                        }
                    }
                }
            }

            toolCalls.append(PendingToolCall(
                id: UUID().uuidString,
                name: toolName,
                arguments: arguments
            ))
        }

        if toolCalls.isEmpty {
            logger.warning("YAMLInXMLParser: Found <tool_calls> but extracted zero entries.")
        } else {
            logger.info("YAMLInXMLParser: Extracted \(toolCalls.count) tool call(s).")
        }

        return ModernCognitiveStep(
            reasoning: ReasoningQualityFilter.filter(reasoning),
            toolCalls: toolCalls
        )
    }
}
