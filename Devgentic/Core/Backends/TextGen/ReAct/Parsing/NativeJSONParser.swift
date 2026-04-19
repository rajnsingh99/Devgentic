//
//  NativeJSONParser.swift
//  Devgentic
//
//  Step 3.1: Fast-path parser for the .nativeJSON dialect.
//  Target: Strict JSON arrays natively output by capable models.
//  Uses JSONDecoder to map the raw response directly into a ModernCognitiveStep.
//
//  Created by Raj Singh on 06/03/26.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "NativeJSONParser")

/// Parses responses where the model emits a well-formed JSON object
/// containing a `content` field and a `tool_calls` array (OpenAI-compatible format).
/// Falls back to `HeuristicCognitiveParser` for structural variance.
struct NativeJSONParser: CognitiveParserProtocol {

    private struct NativeArraySchema: Decodable {
        let content: String
        let tool_calls: [NativeToolCall]

        struct NativeToolCall: Decodable {
            let name: String
            let arguments: [String: JSONValue]
        }
    }

    func parse(rawResponse: String) -> ModernCognitiveStep {
        // Strip markdown fences if the model wrapped its output
        var cleanText = rawResponse
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanText.data(using: .utf8) else {
            logger.error("NativeJSONParser: Failed to encode text as UTF-8.")
            return ModernCognitiveStep(reasoning: rawResponse, toolCalls: [])
        }

        // Fast path: direct decode of the native array schema
        if let decoded = try? JSONDecoder().decode(NativeArraySchema.self, from: data) {
            let pending = decoded.tool_calls.map {
                PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
            }
            logger.info("NativeJSONParser: Fast-path succeeded. \(pending.count) tool call(s).")
            return ModernCognitiveStep(reasoning: decoded.content, toolCalls: pending)
        }

        // Fallback: delegate to heuristic parser for structural variance
        logger.warning("NativeJSONParser: Fast-path failed. Raw Response: \(rawResponse). Delegating to HeuristicCognitiveParser.")
        return HeuristicCognitiveParser.parseLegacyResponse(rawResponse)
    }
}
