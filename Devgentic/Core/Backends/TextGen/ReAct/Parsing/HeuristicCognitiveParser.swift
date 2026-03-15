//
//  HeuristicCognitiveParser.swift
//  Devgentic
//
//  Created by Raj Singh on 05/03/26.
//


import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "HeuristicCognitiveParser")


// MARK: - Shared Parsing Heuristics

/// A collection of robust JSON parsing heuristics and fallback mechanisms.
/// Designed to rescue structurally volatile responses from local or less capable models.
struct HeuristicCognitiveParser {

    /// Parses a raw string response into a LeanCognitiveStep using a tiered strategy.
    private struct LegacyArraySchema: Decodable {
        let content: String
        let tool_calls: [LegacyToolCall]
        
        struct LegacyToolCall: Decodable {
            let name: String
            let arguments: [String: JSONValue]
        }
    }

    private struct LegacySingleSchema: Decodable {
        let content: String
        let tool_name: String?
        let arguments: [String: JSONValue]?
    }

    /// Bare tool call object: `{"name": "tool", "arguments": {...}}`
    /// No `content` wrapper — the model emitted just the raw call.
    /// Handles both "arguments" and "parameters" keys for flexibility.
    private struct BareToolCallSchema: Decodable {
        let name: String
        let arguments: [String: JSONValue]?
        let parameters: [String: JSONValue]?
    }

    /// Parses a raw string response into a ModernCognitiveStep using a tiered legacy shield strategy.
    static func parseLegacyResponse(_ rawText: String) -> ModernCognitiveStep {
        // --- 1. Markdown Sanitization ---
        var cleanText = rawText
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- 2. Outermost Object Extraction ---
        guard let jsonString = extractOutermostJSON(from: cleanText) else {
            logger.error("❌ [JSONParser] Failed to find valid JSON object. Raw text: \(rawText.prefix(500))")
            return ModernCognitiveStep(reasoning: rawText, toolCalls: [])
        }

        // --- 3. Structural Defect Sanitization ---
        let sanitized = sanitizeJSON(jsonString)

        // --- 4. Standard Decoding Attempt ---
        guard let data = sanitized.data(using: .utf8) else {
            logger.error("❌ [JSONParser] Failed to convert string to data.")
            return ModernCognitiveStep(reasoning: rawText, toolCalls: [])
        }

        let decoder = JSONDecoder()

        // Attempt 1: The model successfully output an array (Smart Model)
        if let arrayDecoded = try? decoder.decode(LegacyArraySchema.self, from: data) {
            let pending = arrayDecoded.tool_calls.map {
                PendingToolCall(id: UUID().uuidString, name: $0.name, arguments: $0.arguments)
            }
            return ModernCognitiveStep(reasoning: arrayDecoded.content, toolCalls: pending)
        }
        
        // Attempt 2: Graceful Degradation (Dumb Model used old format)
        if let singleDecoded = try? decoder.decode(LegacySingleSchema.self, from: data) {
            var pending: [PendingToolCall] = []
            if let toolName = singleDecoded.tool_name, toolName != "null", !toolName.isEmpty {
                let args = singleDecoded.arguments ?? [:]
                pending.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: args))
            }
            return ModernCognitiveStep(reasoning: singleDecoded.content.isEmpty ? "Executing..." : singleDecoded.content, toolCalls: pending)
        }

        // Attempt 3: Bare Tool Call (model emitted just {"name": "...", "arguments": {...}})
        if let bareDecoded = try? decoder.decode(BareToolCallSchema.self, from: data) {
            let args = bareDecoded.arguments ?? bareDecoded.parameters ?? [:]
            let pending = [PendingToolCall(id: UUID().uuidString, name: bareDecoded.name, arguments: args)]
            logger.info("✅ [JSONParser] Bare tool call schema matched for tool: \(bareDecoded.name)")
            return ModernCognitiveStep(reasoning: "Executing...", toolCalls: pending)
        }

        // Attempt 4: Lenient Extraction
        logger.warning("⚠️ [JSONParser] Standard decode failed, attempting lenient extraction...")
        if let lenient = attemptLenientExtraction(from: sanitized) {
            logger.info("✅ [JSONParser] Lenient extraction succeeded.")
            return lenient
        }
        
        logger.error("❌ [JSONParser] All parsing strategies exhausted. JSON was: \(sanitized.prefix(500))")
        // Fallback: If JSON is totally broken, treat it as a conversational exit
        return ModernCognitiveStep(reasoning: rawText, toolCalls: [])
    }

    // MARK: - Brace-Depth JSON Extraction

    /// Extracts the outermost JSON object from a string by tracking brace depth.
    private static func extractOutermostJSON(from text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var inString = false
        var prevChar: Character = "\0"

        for (index, char) in zip(text.indices, text) {
            if char == "\"" && prevChar != "\\" {
                inString.toggle()
            }

            if !inString {
                if char == "{" {
                    if depth == 0 { startIndex = index }
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0, let start = startIndex {
                        return String(text[start...index])
                    }
                }
            }
            prevChar = char
        }
        return nil
    }

    // MARK: - JSON Sanitization

    /// Sanitizes common structural defects in LLM-generated JSON (e.g., trailing commas, control characters, Python-style literals).
    private static func sanitizeJSON(_ json: String) -> String {
        var result = json

        // 1. Trailing comma removal: {key: "val",} → {key: "val"}
        let trailingCommaPattern = #",\s*([}\]])"#
        if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // 2. Python-style literal normalization.
        //    Models (especially Llama 3.1) emit Python literals instead of JSON:
        //      NULL / None → null,  True → true,  False → false,  NaN → null
        //    Safe here because sanitizeJSON() only runs on extracted JSON objects
        //    (after brace-depth extraction), not on free-text reasoning.
        //    Word-boundary anchors (\b) prevent corrupting keys like "nullable".
        result = normalizePythonLiterals(result)

        // 3. Strip control characters (below 0x20) except standard whitespace.
        result = result.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.map { String($0) }.joined()

        return result
    }

    /// Replaces Python-style literals with their JSON equivalents.
    /// Uses word-boundary matching to avoid corrupting embedded strings
    /// (e.g., a key named "nullable" won't be mangled).
    private static func normalizePythonLiterals(_ json: String) -> String {
        var result = json

        // Order matters: longest tokens first to avoid partial matches.
        let replacements: [(pattern: String, replacement: String)] = [
            (#"\bFalse\b"#,  "false"),   // Python bool
            (#"\bTrue\b"#,   "true"),    // Python bool
            (#"\bNone\b"#,   "null"),    // Python null
            (#"\bNULL\b"#,   "null"),    // Uppercase null (MySQL / C-style leak)
            (#"\bNaN\b"#,    "null"),    // Python float NaN → safest as null
        ]

        for (pattern, replacement) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement
            )
        }

        return result
    }

    // MARK: - Lenient Field Extraction

    /// A fallback heuristic that attempts to extract required fields using regular expressions when standard JSON decoding fails.
    private static func attemptLenientExtraction(from json: String) -> ModernCognitiveStep? {
        func extractStringOrNull(forKey key: String, in text: String) -> String? {
            let stringPattern = #"\"\#(key)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""#
            if let regex = try? NSRegularExpression(pattern: stringPattern, options: .dotMatchesLineSeparators),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
            
            let nullPattern = #"\"\#(key)\"\s*:\s*null"#
            if let regex = try? NSRegularExpression(pattern: nullPattern, options: []),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return "null"
            }
            return nil
        }

        guard let content = extractStringOrNull(forKey: "content", in: json), content != "null" else {
            return nil
        }

        let extractedTool = extractStringOrNull(forKey: "tool_name", in: json)
        let toolName: String? = (extractedTool == "null" || extractedTool?.isEmpty == true) ? nil : extractedTool

        var arguments: [String: JSONValue]? = nil
        if let toolName = toolName {
            if let argsStart = json.range(of: "\"arguments\""),
               let extracted = extractOutermostJSON(from: String(json[argsStart.lowerBound...])) {
                if let argsData = extracted.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: argsData) {
                    arguments = decoded
                } else {
                    arguments = [:]
                }
            } else {
                arguments = [:]
            }

            if arguments?.isEmpty == true, !content.isEmpty {
                if let rescued = rescueArgumentsFromContent(toolName: toolName, content: content) {
                    logger.info("🔧 [JSONParser] Rescued arguments from content for tool '\(toolName)'.")
                    arguments = rescued
                }
            }
        }

        var pending: [PendingToolCall] = []
        if let toolName = toolName {
            pending.append(PendingToolCall(id: UUID().uuidString, name: toolName, arguments: arguments ?? [:]))
        }

        return ModernCognitiveStep(reasoning: content, toolCalls: pending)
    }

    // MARK: - Content-to-Arguments Rescue

    /// Rescues tool arguments that were mistakenly embedded within the content string by the LLM.
    private static func rescueArgumentsFromContent(toolName: String, content: String) -> [String: JSONValue]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch toolName {
        case "execute_shell":
            var command = trimmed
            if command.hasPrefix("$") { command = String(command.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let prosePrefixes = ["Running:", "Executing:", "Command:", "Execute:"]
            for prefix in prosePrefixes {
                if command.hasPrefix(prefix) {
                    command = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !command.isEmpty else { return nil }
            return ["command": JSONValue.string(command)]

        case "list_directory", "read_file", "create_folder", "delete_file", "fs_read_metadata",
             "fs_watch_folder":
            if let path = extractPathFromContent(trimmed) {
                return ["path": JSONValue.string(path)]
            }

        case "fs_smart_search":
            return ["search_term": JSONValue.string(trimmed)]

        case "run_applescript":
            return ["script": JSONValue.string(trimmed)]

        case "open_application":
            let bundlePattern = #"(com\.[a-zA-Z0-9\-\.]+)"#
            if let regex = try? NSRegularExpression(pattern: bundlePattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return ["bundle_identifier": JSONValue.string(String(trimmed[range]))]
            }

        default:
            break
        }

        return nil
    }

    /// Extracts a valid file system path from free-text using pattern matching.
    private static func extractPathFromContent(_ content: String) -> String? {
        let pathPattern = #"(~?/[^\s\"'<>|]+)"#
        if let regex = try? NSRegularExpression(pattern: pathPattern),
           let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
           let range = Range(match.range(at: 1), in: content) {
            return String(content[range]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
