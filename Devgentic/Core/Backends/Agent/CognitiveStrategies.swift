//
//  CognitiveStrategies.swift
//  Devgentic
//
//  Created by Raj Singh on 16/02/26.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CognitiveStrategies")

// MARK: - Protocol Definition

/// Defines a strategy for generating structured cognitive steps from an LLM.
/// All strategies now operate on the standard messages format and parse JSON text.
protocol CognitiveGenerator: Sendable {
    func generate(
        model: any LLMProvider,
        messages: [[String: String]],
        iteration: Int
    ) async throws -> CognitiveStep
}

// MARK: - Strategy A: Native Structured Generation (OpenAI / Advanced)

/// Uses the provider's JSON Schema enforcement via `response_format` parameter.
/// The model returns a JSON string conforming to the CognitiveStep schema,
/// which is then decoded via standard JSONDecoder.
struct NativeStructuredGenerator: CognitiveGenerator {
    func generate(model: any LLMProvider, messages: [[String: String]], iteration: Int) async throws -> CognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logger.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration)")

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields with your reasoning and next action. DO NOT output the schema definition."
            : "Review OBSERVATION. Update State. Decide next step. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields. DO NOT output the schema definition."

        // 1. Append the trigger prompt to the messages
        var executionMessages = messages
        executionMessages.append(["role": "user", "content": promptTrigger])

        // 2. Direct Model Call with Schema Enforcement
        logger.debug("📤 [Native:\(reqId)] Sending request to model with schema enforcement...")
        let startTime = Date()

        let responseText = try await model.generate(
            messages: executionMessages,
            responseSchema: CognitiveStepSchema.jsonSchema
        )

        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.2f", duration))s")

        // 3. Parse the JSON response
        logger.debug("📄 [Native:\(reqId)] Raw Response: \(responseText.prefix(200))...")

        guard let data = responseText.data(using: .utf8) else {
            logger.error("❌ [Native:\(reqId)] Failed to convert response to data.")
            throw NSError(domain: "CognitiveStrategy", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert response text to data."])
        }

        do {
            let step = try JSONDecoder().decode(CognitiveStep.self, from: data)
            logger.info("🎉 [Native:\(reqId)] Successfully decoded CognitiveStep. Action: \(step.action?.toolName ?? "None")")
            return step
        } catch {
            // Fallback: Try the shadow schema parser (handles markdown wrapping, etc.)
            logger.warning("⚠️ [Native:\(reqId)] Direct decode failed, trying shadow parser: \(error.localizedDescription)")
            return try GeminiShadowSchema.parse(responseText)
        }
    }
}

// MARK: - Strategy B: Shadow Schema (Gemini / Compatibility Layers)

/// Uses a "Golden Prompt" with manual text parsing to bypass the "Schema Echoing" bug.
struct ShadowSchemaGenerator: CognitiveGenerator {

    func generate(model: any LLMProvider, messages: [[String: String]], iteration: Int) async throws -> CognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logger.info("⚡️ [Shadow:\(reqId)] Start Generation - Iteration: \(iteration)")

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a PURE JSON OBJECT."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a PURE JSON OBJECT."

        // Append the Golden Example to the prompt
        let manualPrompt = promptTrigger + "\n\n" + GeminiShadowSchema.goldenPrompt

        // 1. Append prompt to messages
        var executionMessages = messages
        executionMessages.append(["role": "user", "content": manualPrompt])

        // 2. Direct Call (no schema enforcement)
        logger.debug("📤 [Shadow:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ [Shadow:\(reqId)] Response received in \(String(format: "%.2f", duration))s")

        // 3. Parse Text
        logger.debug("📄 [Shadow:\(reqId)] Raw Text Response: \(responseText.prefix(200))...")

        guard !responseText.isEmpty else {
            logger.error("❌ [Shadow:\(reqId)] Empty response from model.")
            throw NSError(domain: "ShadowSchema", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from Shadow Schema model."])
        }

        return try GeminiShadowSchema.parse(responseText)
    }
}

// MARK: - Strategy C: JSON Mode (Ollama / Local / MLX)

/// Uses standard JSON mode (or text mode with prompt enforcement) for local models.
struct JsonModeGenerator: CognitiveGenerator {

    func generate(model: any LLMProvider, messages: [[String: String]], iteration: Int) async throws -> CognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logger.info("⚡️ [JsonMode:\(reqId)] Start Generation - Iteration: \(iteration)")

        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a valid JSON object."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a valid JSON object."

        let prompt = promptTrigger + "\n\n" + """
        Mandatory JSON Structure:
        {
          "previousStepOutcome": "Success",
          "internalMonologue": "Thinking about the next step...",
          "displayHeadline": "Reasoning...",
          "action": { "toolName": "ls", "parameters": { "path": "/" } },
          "memoryUpdate": null,
          "finalAnswer": null
        }

        CRITICAL RULES:
        1. 'internalMonologue' and 'displayHeadline' are REQUIRED fields. Do not omit them.
        2. Ensure strict JSON syntax. No markdown.
        """

        var executionMessages = messages
        executionMessages.append(["role": "user", "content": prompt])

        logger.debug("📤 [JsonMode:\(reqId)] Sending request...")
        let startTime = Date()

        let responseText = try await model.generate(messages: executionMessages, responseSchema: nil)

        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ [JsonMode:\(reqId)] Response received in \(String(format: "%.2f", duration))s")

        guard !responseText.isEmpty else {
            logger.error("❌ [JsonMode:\(reqId)] Empty response from model.")
            throw NSError(domain: "JsonMode", code: 422, userInfo: [NSLocalizedDescriptionKey: "Empty response from JSON Mode model."])
        }

        logger.debug("📄 [JsonMode:\(reqId)] Raw Text: \(responseText.prefix(200))...")
        return try GeminiShadowSchema.parse(responseText)
    }
}

// MARK: - CognitiveStep JSON Schema (for Native Strategy)

/// Static JSON Schema definition for CognitiveStep, used by providers that support
/// schema enforcement (OpenAI `response_format`, Ollama `format`).
enum CognitiveStepSchema {

    static let jsonSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "previousStepOutcome": [
                "type": ["string", "null"],
                "description": "Success or Failure of the previous step."
            ],
            "internalMonologue": [
                "type": "string",
                "description": "The agent's internal reasoning."
            ],
            "displayHeadline": [
                "type": "string",
                "description": "A short 3-5 word status for UI display."
            ],
            "action": [
                "type": ["object", "null"],
                "description": "The tool to execute, or null if no action needed.",
                "properties": [
                    "toolName": ["type": "string"],
                    "parameters": ["type": "object"]
                ] as [String: Any],
                "required": ["toolName", "parameters"]
            ],
            "memoryUpdate": [
                "type": ["object", "null"],
                "description": "State mutation for goal tracking.",
                "properties": [
                    "goalStatus": ["type": "string"],
                    "goalSummary": ["type": "string"],
                    "logEntry": ["type": "string"]
                ] as [String: Any],
                "required": ["goalStatus", "goalSummary", "logEntry"]
            ],
            "finalAnswer": [
                "type": ["string", "null"],
                "description": "The final response to the user, or null if task is not complete."
            ]
        ] as [String: Any],
        "required": ["internalMonologue", "displayHeadline"],
        "additionalProperties": false
    ]
}

// MARK: - Shared Helpers

/// Helper for Manual Strategies
struct GeminiShadowSchema {

    static let goldenPrompt = """
    INTERACTION PROTOCOL
    You must respond with a SINGLE JSON OBJECT.
    The object must parse into the following structure.

    REQUIRED JSON STRUCTURE (EXAMPLE)
    {
    "internalMonologue": "Analyzing the user request... I need to list files.",
    "displayHeadline": "Scanning Documents...",
    "action": {
    "toolName": "list_directory",
    "parameters": {
    "path": "/Users/username/Documents"
    }
    },
    "memoryUpdate": {
    "goalStatus": "ACTIVE",
    "goalSummary": "Listing files to find the report.",
    "logEntry": "User requested file search."
    }
    }

    CRITICAL CONSTRAINTS
    OUTPUT FORMAT: Raw JSON only. Do not wrap in markdown (json).
    VALIDITY: Ensure "action" contains a valid "toolName" from the TOOLS list.
    CLARIFICATION: If you need info from the user, use "toolName": "ask_user" with "parameters": {"question": "..."}.
    FINALITY: If the task is done, set "action" to null and provide "finalAnswer".
    DO NOT invent tools like 'none', 'inform', or 'respond'. Use only tools from the TOOLS list.
    QUOTING: All keys and string values must use double quotes.
    """

    static func parse(_ text: String) throws -> CognitiveStep {
        // 1. Strip Markdown fences (```json ... ```, ``` ... ```)
        var cleanText = text
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Extract the outermost JSON object using brace-depth matching
        //    This is more robust than firstIndex/lastIndex for mixed prose + JSON output
        guard let jsonString = extractOutermostJSON(from: cleanText) else {
            logger.error("❌ [JSONParser] Failed to find valid JSON object. Raw text: \(text.prefix(500))")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Response is not valid JSON."])
        }

        // 3. Sanitize common local-model JSON defects
        let sanitized = sanitizeJSON(jsonString)

        // 4. Decode
        guard let data = sanitized.data(using: .utf8) else {
            logger.error("❌ [JSONParser] Failed to convert string to data.")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data."])
        }

        do {
            return try JSONDecoder().decode(CognitiveStep.self, from: data)
        } catch {
            // 5. Last resort: attempt lenient field extraction
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

    /// Walks the string to find the first complete `{...}` block using brace-depth counting,
    /// correctly skipping braces inside string literals.
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

    /// Fixes common defects produced by local/small models:
    /// - Trailing commas before `}` or `]`
    /// - Single-quoted strings → double-quoted
    /// - Control characters inside string values
    private static func sanitizeJSON(_ json: String) -> String {
        var result = json

        // A. Remove trailing commas: `,` followed by optional whitespace then `}` or `]`
        let trailingCommaPattern = #",\s*([}\]])"#
        if let regex = try? NSRegularExpression(pattern: trailingCommaPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }

        // B. Strip control characters (except \n, \r, \t which are valid in JSON strings)
        result = result.unicodeScalars.filter { scalar in
            // Allow normal printable chars + whitespace
            scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.map { String($0) }.joined()

        return result
    }

    // MARK: - Lenient Field Extraction

    /// As a last resort, manually extract the two REQUIRED fields (`internalMonologue`, `displayHeadline`)
    /// using regex, and attempt to reconstruct a minimal valid CognitiveStep.
    /// This salvages partial/malformed JSON that has the critical data but fails strict decode.
    private static func attemptLenientExtraction(from json: String) -> CognitiveStep? {
        func extractStringValue(forKey key: String, in text: String) -> String? {
            // Match: "key" : "value" (handles escaped quotes in value)
            let pattern = #""\#(key)"\s*:\s*"((?:[^"\\]|\\.)*)""#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }

        // REQUIRED fields
        guard let monologue = extractStringValue(forKey: "internalMonologue", in: json),
              let headline = extractStringValue(forKey: "displayHeadline", in: json) else {
            return nil
        }

        // OPTIONAL fields
        let finalAnswer = extractStringValue(forKey: "finalAnswer", in: json)
        let previousOutcome = extractStringValue(forKey: "previousStepOutcome", in: json)

        // Attempt to extract action block
        var action: ToolAction? = nil
        let toolName = extractStringValue(forKey: "toolName", in: json)
        if let toolName = toolName, !toolName.isEmpty {
            // Try to decode just the action sub-object
            if let actionStart = json.range(of: "\"action\""),
               let extracted = extractOutermostJSON(from: String(json[actionStart.lowerBound...])) {
                if let actionData = extracted.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(ToolAction.self, from: actionData) {
                    action = decoded
                } else {
                    // Minimal action with empty params
                    action = ToolAction(toolName: toolName, parameters: [:])
                }
            } else {
                action = ToolAction(toolName: toolName, parameters: [:])
            }
        }

        // Attempt to extract memoryUpdate block
        var memoryUpdate: MemoryUpdate? = nil
        if let goalStatus = extractStringValue(forKey: "goalStatus", in: json),
           let goalSummary = extractStringValue(forKey: "goalSummary", in: json),
           let logEntry = extractStringValue(forKey: "logEntry", in: json) {
            memoryUpdate = MemoryUpdate(goalStatus: goalStatus, goalSummary: goalSummary, logEntry: logEntry)
        }

        return CognitiveStep(
            previousStepOutcome: previousOutcome,
            internalMonologue: monologue,
            displayHeadline: headline,
            action: action,
            memoryUpdate: memoryUpdate,
            finalAnswer: finalAnswer
        )
    }
}
