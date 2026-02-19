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
    VALIDITY: Ensure "action" contains a valid "toolName" from the list above.
    FINALITY: If the task is done, set "action" to null and provide "finalAnswer".
    QUOTING: All keys and string values must use double quotes.
    """

    static func parse(_ text: String) throws -> CognitiveStep {
        // 1. Strip Markdown (```json ... ```)
        var cleanText = text
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
        }
        if cleanText.contains("```") {
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2. Validate it looks like JSON
        guard let firstBrace = cleanText.firstIndex(of: "{"),
              let lastBrace = cleanText.lastIndex(of: "}") else {
            logger.error("❌ [JSONParser] Failed to find valid JSON braces. Raw text: \(text)")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Response is not valid JSON."])
        }

        let jsonString = String(cleanText[firstBrace...lastBrace])

        // 3. Decode
        guard let data = jsonString.data(using: .utf8) else {
            logger.error("❌ [JSONParser] Failed to convert string to data.")
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data."])
        }

        do {
            return try JSONDecoder().decode(CognitiveStep.self, from: data)
        } catch {
            logger.error("❌ [JSONParser] Decoding failed: \(error.localizedDescription). JSON was: \(jsonString)")
            throw error
        }
    }
}
