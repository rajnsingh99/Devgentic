//
//  CognitiveStrategies.swift
//  Devgentic
//
//  Created by Raj Singh on 16/02/26.
//

import Foundation
import OpenFoundationModels
import OpenFoundationModelsCore
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "CognitiveStrategies")

// MARK: - Protocol Definition

/// Defines a strategy for generating structured cognitive steps from an LLM.
/// Refactored to bypass `LanguageModelSession` to prevent internal library looping.
protocol CognitiveGenerator: Sendable {
    func generate(
        model: any LanguageModel,
        transcript: Transcript,
        iteration: Int
    ) async throws -> CognitiveStep
}

// MARK: - Strategy A: Native Structured Generation (OpenAI / Advanced)

/// Uses the library's `@Generable` macro mechanism to enforce schema at the API level.
/// Manually constructs the transcript entry to avoid `LanguageModelSession`'s internal loop.
struct NativeStructuredGenerator: CognitiveGenerator {
    func generate(model: any LanguageModel, transcript: Transcript, iteration: Int) async throws -> CognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logger.info("⚡️ [Native:\(reqId)] Start Generation - Iteration: \(iteration)")
        
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields with your reasoning and next action. DO NOT output the schema definition."
            : "Review OBSERVATION. Update State. Decide next step. You MUST generate a valid JSON object matching the `CognitiveStep` schema. Fill the fields. DO NOT output the schema definition."
        
        // 1. Construct the Prompt Entry with Schema Enforcement
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(
                id: UUID().uuidString,
                segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: promptTrigger))],
                options: GenerationOptions(), // Pass custom options if needed
                responseFormat: Transcript.ResponseFormat(type: CognitiveStep.self)
            )
        )
        
        // 2. Update Transcript (Value Type Copy)
        // FIX: Access entries via Collection conformance instead of direct property (which is package-private)
        var entries = Array(transcript)
        entries.append(promptEntry)
        let executionTranscript = Transcript(entries: entries)
        
        // 3. Direct Model Call (No Loop)
        logger.debug("📤 [Native:\(reqId)] Sending request to model...")
        let startTime = Date()
        
        let entry = try await model.generate(transcript: executionTranscript, options: nil)
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ [Native:\(reqId)] Response received in \(String(format: "%.2f", duration))s")
        
        // 4. Parse Result
        switch entry {
        case .response(let response):
            var generatedContent: GeneratedContent?
            
            for segment in response.segments {
                if case .structure(let structuredSegment) = segment {
                    logger.debug("📄 [Native:\(reqId)] Received Structured Segment.")
                    generatedContent = structuredSegment.content
                    break
                } else if case .text(let textSegment) = segment {
                    logger.warning("⚠️ [Native:\(reqId)] Received Text Segment (Fallback). Content: \(textSegment.content.prefix(100))...")
                    // Fallback: Try parsing text as JSON
                    generatedContent = try? GeneratedContent(json: textSegment.content)
                }
            }
            
            guard let content = generatedContent else {
                logger.error("❌ [Native:\(reqId)] No structured content found in response.")
                throw NSError(domain: "CognitiveStrategy", code: 422, userInfo: [NSLocalizedDescriptionKey: "Model returned response but no structured content found."])
            }
            
            do {
                let step = try CognitiveStep(content)
                logger.info("🎉 [Native:\(reqId)] Successfully decoded CognitiveStep. Action: \(step.action?.toolName ?? "None")")
                return step
            } catch {
                logger.error("❌ [Native:\(reqId)] Decoding Error: \(error.localizedDescription)")
                throw error
            }
            
        case .toolCalls(let toolCalls):
            // Crucial: We interpret tool calls as a failure in the 'Thinking' step,
            // or we could try to parse them if the model got confused.
            // For now, throw to trigger the ReAct retry logic.
            logger.error("❌ [Native:\(reqId)] Model returned direct ToolCalls (\(toolCalls.count)) instead of CognitiveStep structure.")
            throw NSError(domain: "CognitiveStrategy", code: 422, userInfo: [NSLocalizedDescriptionKey: "Model attempted to call a tool directly instead of returning a CognitiveStep structure."])
            
        default:
            logger.error("❌ [Native:\(reqId)] Unexpected model output type: \(String(describing: entry))")
            throw NSError(domain: "CognitiveStrategy", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unexpected model output type: \(entry)"])
        }
    }
}

// MARK: - Strategy B: Shadow Schema (Gemini / Compatibility Layers)

/// Uses a "Golden Prompt" with manual text parsing to bypass the "Schema Echoing" bug.
struct ShadowSchemaGenerator: CognitiveGenerator {
    
    func generate(model: any LanguageModel, transcript: Transcript, iteration: Int) async throws -> CognitiveStep {
        let reqId = UUID().uuidString.prefix(8)
        logger.info("⚡️ [Shadow:\(reqId)] Start Generation - Iteration: \(iteration)")
        
        let promptTrigger = (iteration == 1)
            ? "Begin ReAct loop. Analyze Active Memory. Respond with a PURE JSON OBJECT."
            : "Review OBSERVATION. Update State. Decide next step. Respond with a PURE JSON OBJECT."
        
        // Append the Golden Example to the prompt
        let manualPrompt = promptTrigger + "\n\n" + GeminiShadowSchema.goldenPrompt
        
        // 1. Construct Simple Text Prompt
        let promptEntry = Transcript.Entry.prompt(
            Transcript.Prompt(
                id: UUID().uuidString,
                segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: manualPrompt))],
                options: GenerationOptions(),
                responseFormat: nil // Text Mode
            )
        )
        
        // FIX: Access entries via Collection conformance
        var entries = Array(transcript)
        entries.append(promptEntry)
        let executionTranscript = Transcript(entries: entries)
        
        // 2. Direct Call
        logger.debug("📤 [Shadow:\(reqId)] Sending request...")
        let startTime = Date()
        
        let entry = try await model.generate(transcript: executionTranscript, options: nil)
        
        let duration = Date().timeIntervalSince(startTime)
        logger.info("✅ [Shadow:\(reqId)] Response received in \(String(format: "%.2f", duration))s")
        
        // 3. Parse Text
        if case .response(let response) = entry,
           let textEntry = response.segments.first(where: {
               if case .text = $0 { return true }
               return false
           }) {
            if case .text(let segment) = textEntry {
                logger.debug("📄 [Shadow:\(reqId)] Raw Text Response: \(segment.content)")
                 return try GeminiShadowSchema.parse(segment.content)
            }
        }
        
        logger.error("❌ [Shadow:\(reqId)] Failed to extract text content.")
        throw NSError(domain: "ShadowSchema", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to extract text content from Shadow Schema response."])
    }
}

// MARK: - Strategy C: JSON Mode (Ollama / Local / MLX)

/// Uses standard JSON mode (or text mode with prompt enforcement) for local models.
struct JsonModeGenerator: CognitiveGenerator {
    
    func generate(model: any LanguageModel, transcript: Transcript, iteration: Int) async throws -> CognitiveStep {
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
        
        let promptEntry = Transcript.Entry.prompt(
             Transcript.Prompt(
                 id: UUID().uuidString,
                 segments: [.text(Transcript.TextSegment(id: UUID().uuidString, content: prompt))],
                 options: GenerationOptions(),
                 responseFormat: nil // Or .json if supported by local provider
             )
         )
         
         // FIX: Access entries via Collection conformance
         var entries = Array(transcript)
         entries.append(promptEntry)
         let executionTranscript = Transcript(entries: entries)
         
         logger.debug("📤 [JsonMode:\(reqId)] Sending request...")
         let startTime = Date()
        
         let entry = try await model.generate(transcript: executionTranscript, options: nil)
        
         let duration = Date().timeIntervalSince(startTime)
         logger.info("✅ [JsonMode:\(reqId)] Response received in \(String(format: "%.2f", duration))s")
         
         if case .response(let response) = entry {
             // Extract text from all segments
             let fullText = response.segments.compactMap { segment -> String? in
                 if case .text(let t) = segment { return t.content }
                 return nil
             }.joined()
             
             if !fullText.isEmpty {
                 logger.debug("📄 [JsonMode:\(reqId)] Raw Text: \(fullText.prefix(200))...")
                 return try GeminiShadowSchema.parse(fullText)
             }
         }
         
         logger.error("❌ [JsonMode:\(reqId)] Failed to extract text.")
         throw NSError(domain: "JsonMode", code: 422, userInfo: [NSLocalizedDescriptionKey: "Failed to extract text content from JSON Mode response."])
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
