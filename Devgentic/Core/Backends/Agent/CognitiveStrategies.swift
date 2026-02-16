//
//  CognitiveStrategies.swift
//  Devgentic
//
//  Created by Raj Singh on 16/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore

// MARK: - Protocol Definition

/// Defines a strategy for generating structured cognitive steps from an LLM session.
/// This decouples the "How" (Provider Protocol) from the "What" (Agent Logic).
protocol CognitiveGenerator: Sendable {
    func generate(
        session: LanguageModelSession,
        iteration: Int
    ) async throws -> CognitiveStep
}

// MARK: - Strategy A: Native Structured Generation (OpenAI / Advanced)

/// Uses the library's `@Generable` macro mechanism to enforce schema at the API level.
/// Best for OpenAI GPT-4o, GPT-4-Turbo, and models with strict `json_schema` support.
struct NativeStructuredGenerator: CognitiveGenerator {
    func generate(session: LanguageModelSession, iteration: Int) async throws -> CognitiveStep {
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields with your reasoning and next action. DO NOT output the schema definition."
            : "Review OBSERVATION. Update State. Decide next step. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields. DO NOT output the schema definition."
        
        // This call uses the library's internal macro reflection to send `response_format: { type: "json_schema", ... }`
        let response = try await session.respond(to: promptTrigger, generating: CognitiveStep.self)
        return response.content
    }
}

// MARK: - Strategy B: Shadow Schema (Gemini / Compatibility Layers)

/// Uses a "Golden Prompt" with manual text parsing to bypass the "Schema Echoing" bug
/// present in Google's OpenAI-compatibility layer.
struct ShadowSchemaGenerator: CognitiveGenerator {
    
    func generate(session: LanguageModelSession, iteration: Int) async throws -> CognitiveStep {
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a PURE JSON OBJECT."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a PURE JSON OBJECT."
        
        // Append the Golden Example to the prompt
        let manualPrompt = promptTrigger + "\n\n" + GeminiShadowSchema.goldenPrompt
        
        // Call Text-only API (bypassing library schema injection)
        let response = try await session.respond(to: manualPrompt)
        
        // Manually Decode
        return try GeminiShadowSchema.parse(response.content)
    }
}

// MARK: - Strategy C: JSON Mode (Ollama / Local / MLX)

/// Uses standard JSON mode (or text mode with prompt enforcement) for local models.
/// Includes "fuzzy" parsing logic to handle preamble text often output by smaller models (Llama 3 8B).
struct JsonModeGenerator: CognitiveGenerator {
    
    func generate(session: LanguageModelSession, iteration: Int) async throws -> CognitiveStep {
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a valid JSON object."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a valid JSON object."
        
        // [FIXED] Updated prompt to be more explicit about REQUIRED fields to prevent missing key errors.
        // Added 'previousStepOutcome' to match struct definition.
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
        
        let response = try await session.respond(to: prompt)
        
        // Reuse the robust parser from Shadow Schema or implement specific fuzzy logic here
        return try GeminiShadowSchema.parse(response.content)
    }
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
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Response is not valid JSON."])
        }
        
        let jsonString = String(cleanText[firstBrace...lastBrace])
        
        // 3. Decode
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "JsonParser", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to convert string to data."])
        }
        
        return try JSONDecoder().decode(CognitiveStep.self, from: data)
    }
}
