//
//  PromptedJsonModeGenerator.swift
//  Devgentic
//
//  Created by Raj Singh on 26/02/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CognitiveStrategies")
private let logLLMOps = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "LLMOps")

// MARK: - Strategy B: Shadow Schema (Gemini / Compatibility Layers)

/// A cognitive strategy that uses a "Golden Prompt" and manual text parsing to bypass models that struggle with strict schema adherence.
struct ShadowSchemaGenerator: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    
    init(toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        return buildStandardMessages(context: context, dialectRules: GeminiShadowSchema.goldenPrompt)
    }

    func generate(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> LeanCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [Shadow:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a PURE JSON OBJECT."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a PURE JSON OBJECT."

        let manualPrompt = promptTrigger + "\n\n" + GeminiShadowSchema.goldenPrompt
        executionMessages.append(["role": "user", "content": manualPrompt])

        logLLMOps.debug("📤 [Shadow:\(reqId)] Sending request...")
        let startTime = Date()

        let nativeTools = toolAdapter.formatForNativeAPI(context.availableTools)
        let responseText = try await model.generate(messages: executionMessages, tools: nativeTools, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [Shadow:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [Shadow:\(reqId)] Raw LLM Response:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [Shadow:\(reqId)] Empty response from model.")
            throw NSError(domain: "ShadowSchema", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        return try GeminiShadowSchema.parse(responseText)
    }
}

// MARK: - Strategy C: Prompted JSON Mode (Ollama / Local / MLX)

/// A cognitive strategy tailored for local models using standard JSON mode or prompt-enforced text mode.
struct PromptedJsonModeStrategy: CognitiveGenerator {
    let toolAdapter: ToolSchemaAdapter
    
    init(toolAdapter: ToolSchemaAdapter = PromptedMarkdownAdapter()) {
        self.toolAdapter = toolAdapter
    }

    func compileMessages(from context: SemanticContext) -> [[String: String]] {
        let strictRules = """
        CRITICAL TERMINATION RULE:
        If you have fully answered the user's request OR cannot proceed, you MUST output:
        {
          "content": "I have found the information and am ready to respond.",
          "tool_name": null,
          "arguments": null
        }
        Do NOT output tool_name: null if you still need to execute an action.

        CRITICAL RULES:
        1. 'content' is a REQUIRED field. Do not omit it.
        2. Ensure STRICT JSON SYNTAX. Do not return conversational text outside the JSON object.
        3. Do NOT wrap the JSON in markdown fences. Output the raw {} object only.
        4. Always use double quotes for strings and keys.
        """
        
        var messages = buildStandardMessages(context: context, dialectRules: strictRules)
        messages.append(["role": "user", "content": "Reminder: Output ONLY valid JSON."])
        return messages
    }

    func generate(model: any LLMProvider, context: SemanticContext, iteration: Int) async throws -> LeanCognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logLLMOps.info("⚡️ [JsonMode:\(reqId)] Start Generation - Iteration: \(iteration)")

        var executionMessages = compileMessages(from: context)

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a valid JSON object."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a valid JSON object."

        let prompt = promptTrigger + "\n\n" + """
        Mandatory JSON Structure:
        {
          "content": "Thinking about the next step...",
          "tool_name": "ls",
          "arguments": { "path": "/" }
        }
        """

        executionMessages.append(["role": "user", "content": prompt])

        logLLMOps.debug("📤 [JsonMode:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, tools: nil, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logLLMOps.info("✅ [JsonMode:\(reqId)] Response received in \(String(format: "%.4f", duration))s")
        logLLMOps.debug("📄 [JsonMode:\(reqId)] Raw LLM Response:\n\(responseText)")

        guard !responseText.isEmpty else {
            logLLMOps.error("❌ [JsonMode:\(reqId)] Empty response from model.")
            throw NSError(domain: "JsonMode", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from model."])
        }

        return try GeminiShadowSchema.parse(responseText)
    }
}

// MARK: - Legacy Compatibility Mapping
typealias JsonModeGenerator = PromptedJsonModeStrategy

// MARK: - Shared Parsing Heuristics

/// A collection of robust JSON parsing heuristics and fallback mechanisms.
/// Designed to rescue structurally volatile responses from local or less capable models.
struct GeminiShadowSchema {

    static let goldenPrompt = """
    REQUIRED JSON STRUCTURE (EXAMPLE):
    {
      "content": "I need to list the files in the Documents directory to find the report.",
      "tool_name": "list_directory",
      "arguments": { "path": "/Users/username/Documents" }
    }

    CRITICAL TERMINATION RULE:
    If you have fully answered the user's request OR cannot proceed, you MUST output:
    {
      "content": "I have found the information and am ready to respond.",
      "tool_name": null,
      "arguments": null
    }
    Do NOT output tool_name: null if you still need to execute an action.

    CRITICAL CONSTRAINTS
    OUTPUT FORMAT: Raw JSON only. Do not wrap in markdown (json).
    VALIDITY: Ensure "tool_name" contains a valid tool from the TOOLS list when not null.
    CLARIFICATION: If you need info from the user, use "tool_name": "ask_user" with "arguments": {"question": "..."}.
    DO NOT invent tools like 'none', 'inform', or 'respond'. Use only tools from the TOOLS list or return null.
    QUOTING: All keys and string values must use double quotes.
    """

    /// Parses a raw string response into a LeanCognitiveStep using a tiered strategy.
    static func parse(_ text: String) throws -> LeanCognitiveStep {
        // --- 1. Markdown Sanitization ---
        var cleanText = text
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- 2. Outermost Object Extraction ---
        guard let jsonString = extractOutermostJSON(from: cleanText) else {
            logger.error("❌ [JSONParser] Failed to find valid JSON object. Raw text: \(text.prefix(500))")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Response is not valid JSON."])
        }

        // --- 3. Structural Defect Sanitization ---
        let sanitized = sanitizeJSON(jsonString)

        // --- 4. Standard Decoding Attempt ---
        guard let data = sanitized.data(using: .utf8) else {
            logger.error("❌ [JSONParser] Failed to convert string to data.")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data."])
        }

        do {
            return try JSONDecoder().decode(LeanCognitiveStep.self, from: data)
        } catch {
            // --- 5. Lenient Fallback Extraction ---
            logger.warning("⚠️ [JSONParser] Standard decode failed (\(error.localizedDescription)), attempting lenient extraction...")
            if let lenient = attemptLenientExtraction(from: sanitized) {
                logger.info("✅ [JSONParser] Lenient extraction succeeded.")
                return lenient
            }
            logger.error("❌ [JSONParser] All parsing strategies exhausted. JSON was: \(sanitized.prefix(500))")
            throw error
        }
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

    /// Sanitizes common structural defects in LLM-generated JSON (e.g., trailing commas, control characters).
    private static func sanitizeJSON(_ json: String) -> String {
        var result = json

        let trailingCommaPattern = #",\s*([}\]])"#
        if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        result = result.unicodeScalars.filter { scalar in
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.map { String($0) }.joined()

        return result
    }

    // MARK: - Lenient Field Extraction

    /// A fallback heuristic that attempts to extract required fields using regular expressions when standard JSON decoding fails.
    private static func attemptLenientExtraction(from json: String) -> LeanCognitiveStep? {
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

        var arguments: [String: AnyCodable]? = nil
        if let toolName = toolName {
            if let argsStart = json.range(of: "\"arguments\""),
               let extracted = extractOutermostJSON(from: String(json[argsStart.lowerBound...])) {
                if let argsData = extracted.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode([String: AnyCodable].self, from: argsData) {
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

        return LeanCognitiveStep(content: content, toolName: toolName, arguments: arguments)
    }

    // MARK: - Content-to-Arguments Rescue

    /// Rescues tool arguments that were mistakenly embedded within the content string by the LLM.
    private static func rescueArgumentsFromContent(toolName: String, content: String) -> [String: AnyCodable]? {
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
            return ["command": AnyCodable(command)]

        case "list_directory", "read_file", "create_folder", "delete_file", "fs_read_metadata",
             "fs_watch_folder":
            if let path = extractPathFromContent(trimmed) {
                return ["path": AnyCodable(path)]
            }

        case "fs_smart_search":
            return ["search_term": AnyCodable(trimmed)]

        case "run_applescript":
            return ["script": AnyCodable(trimmed)]

        case "open_application":
            let bundlePattern = #"(com\.[a-zA-Z0-9\-\.]+)"#
            if let regex = try? NSRegularExpression(pattern: bundlePattern),
               let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
               let range = Range(match.range(at: 1), in: trimmed) {
                return ["bundle_identifier": AnyCodable(String(trimmed[range]))]
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
