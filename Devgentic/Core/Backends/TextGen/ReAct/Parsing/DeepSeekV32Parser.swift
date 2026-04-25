//
//  DeepSeekV32Parser.swift
//  Devgentic
//
//  Phase 5 — Native-tool dialect expansion (2026-04-22).
//  Primary parser for the `.deepseekV32Dsml` dialect (DeepSeek V3.2).
//
//  Canonical output — brand new `<｜DSML｜...>` XML namespace (full-width pipes preserved):
//
//    <｜DSML｜function_calls>
//    <｜DSML｜invoke name="get_weather">
//    <｜DSML｜parameter name="location" string="true">Seattle</｜DSML｜parameter>
//    <｜DSML｜parameter name="days" string="false">7</｜DSML｜parameter>
//    </｜DSML｜invoke>
//    </｜DSML｜function_calls>
//
//  Parameters carry a `string="true"|"false"` attribute that signals whether the body
//  should be treated as a literal string vs parsed JSON/number/bool.
//
//  Completely abandons V3/V3.1's begin/end/sep sentinels — this is a ground-up redesign.
//  Structurally similar to Claude's `<invoke>`/`<parameter>` tool use syntax.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "DeepSeekV32Parser")

struct DeepSeekV32Parser: CognitiveParserProtocol {

    // Full-width pipe U+FF5C retained in the DSML namespace.
    private static let FUNCTION_CALLS_OPEN = "<\u{FF5C}DSML\u{FF5C}function_calls>"
    private static let FUNCTION_CALLS_CLOSE = "</\u{FF5C}DSML\u{FF5C}function_calls>"

    func parse(rawResponse: String) -> ModernCognitiveStep {
        let calls = extractToolCalls(from: rawResponse)
        let reasoning = extractReasoning(from: rawResponse, extractedCount: calls.count)

        if !calls.isEmpty {
            logger.info("DeepSeekV32Parser: Extracted \(calls.count) tool call(s): \(calls.map { $0.name }.joined(separator: ", "))")
            return ModernCognitiveStep(reasoning: reasoning, toolCalls: calls)
        }

        logger.warning("DeepSeekV32Parser: No <｜DSML｜invoke> blocks found. Treating as conversational exit.")
        return ModernCognitiveStep(
            reasoning: rawResponse.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: []
        )
    }

    // MARK: - Extraction

    /// Finds each `<｜DSML｜invoke name="X">...</｜DSML｜invoke>` block.
    /// Full-width pipe `｜` (U+FF5C) is literal — we embed it via \u{FF5C} in patterns.
    private func extractToolCalls(from text: String) -> [PendingToolCall] {
        // Use string literal with explicit Unicode escapes in regex.
        // Regex to match: <｜DSML｜invoke name="NAME">(body)</｜DSML｜invoke>
        let pipe = "\u{FF5C}"
        let pattern = "<\(pipe)DSML\(pipe)invoke\\s+name=\"([^\"]+)\">([\\s\\S]*?)</\(pipe)DSML\(pipe)invoke>"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            logger.error("DeepSeekV32Parser: Regex compile failed.")
            return []
        }

        var results: [PendingToolCall] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                  let bodyRange = Range(match.range(at: 2), in: text) else { continue }

            let name = String(text[nameRange])
            let body = String(text[bodyRange])
            let arguments = extractParameters(from: body)

            results.append(PendingToolCall(
                id: UUID().uuidString,
                name: name,
                arguments: arguments
            ))
        }

        return results
    }

    /// Parses `<｜DSML｜parameter name="KEY" string="BOOL">value</｜DSML｜parameter>` pairs.
    /// Uses `string` attribute to decide JSON-parse (false) vs literal-string (true).
    private func extractParameters(from body: String) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        let pipe = "\u{FF5C}"
        // Param format: <｜DSML｜parameter name="..." string="true|false">value</｜DSML｜parameter>
        // `string` attribute is optional.
        let pattern = "<\(pipe)DSML\(pipe)parameter\\s+name=\"([^\"]+)\"(?:\\s+string=\"([^\"]+)\")?>([\\s\\S]*?)</\(pipe)DSML\(pipe)parameter>"

        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }

        let range = NSRange(body.startIndex..., in: body)
        for match in regex.matches(in: body, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: body),
                  let valueRange = Range(match.range(at: 3), in: body) else { continue }

            let key = String(body[keyRange])
            let isString: Bool = {
                guard match.range(at: 2).location != NSNotFound,
                      let stringAttrRange = Range(match.range(at: 2), in: body) else {
                    return true  // default to string if attribute absent
                }
                return String(body[stringAttrRange]).lowercased() == "true"
            }()
            let rawValue = String(body[valueRange])

            result[key] = parseParameterValue(rawValue, isString: isString)
        }
        return result
    }

    /// Converts a parameter value to a JSONValue using the `string` attribute hint.
    private func parseParameterValue(_ raw: String, isString: Bool) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if isString {
            // Keep as literal string (preserving internal whitespace).
            return .string(raw)
        }

        // string="false" → try to parse as JSON literal (number, bool, null, object, array).
        let lowered = trimmed.lowercased()
        if lowered == "null" || lowered == "none" { return .null }
        if lowered == "true" { return .bool(true) }
        if lowered == "false" { return .bool(false) }
        if let d = Double(trimmed) { return .number(d) }

        // Object / array
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
           (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if let data = trimmed.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return value
            }
        }

        // Fallback: string.
        return .string(raw)
    }

    private func extractReasoning(from text: String, extractedCount: Int) -> String {
        guard extractedCount > 0 else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = text.range(of: Self.FUNCTION_CALLS_OPEN) {
            let before = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return before.isEmpty ? "Executing tool calls..." : before
        }
        return "Executing tool calls..."
    }
}
