//
//  MLXTokenizerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh on 04/03/26.
//  Updated: Tiered Capability Detection for MLX Models
//

import Foundation
import OSLog

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.devgentic.app", category: "MLXTokenizerAnalyzer")

/// A utility class to analyze MLX model tokenizer configurations to determine
/// its exact tool-calling capabilities and required generation strategy.
enum MLXTokenizerAnalyzer {

    // MARK: - Full Profile Detection (Step 1.2)

    /// Evaluates model config files and returns a complete `CognitiveProfile` including
    /// the detected capability tier AND the correct output dialect.
    ///
    /// - Parameters:
    ///   - modelPath: The local directory path containing the downloaded MLX model weights and configs.
    ///   - modelName: The display name of the model (used as a heuristic fallback).
    /// - Returns: A `CognitiveProfile` encoding both capability and dialect.
    static func detectCognitiveProfile(for modelPath: URL, modelName: String) -> CognitiveProfile {
        let (capability, dialect, metadata) = detectCapabilityAndDialect(for: modelPath, modelName: modelName)
        return CognitiveProfile(capability: capability, dialect: dialect, metadata: metadata)
    }

    // MARK: - Legacy Capability-Only API (backward compat)

    /// Evaluates multiple model configuration files to accurately determine structural capability.
    ///
    /// - Parameters:
    ///   - modelPath: The local directory path containing the downloaded MLX model weights and configs.
    ///   - modelName: The display name of the model (used as a heuristic fallback).
    /// - Returns: The `ModelCognitiveCapability` tier of the model.
    static func detectCapability(for modelPath: URL, modelName: String) -> ModelCognitiveCapability {
        return detectCapabilityAndDialect(for: modelPath, modelName: modelName).0
    }

    // MARK: - Core Detection Logic

    private static func detectCapabilityAndDialect(
        for modelPath: URL,
        modelName: String
    ) -> (ModelCognitiveCapability, ModelDialect, ModelMetadata) {

        var hasToolTemplate = false
        var hasParallelTemplate = false
        var originalModelName = modelName.lowercased()
        var hasSpecialToolTokens = false
        var quantization: String? = nil

        // Track dialect signals from the Jinja template
        var hasMistralXMLSignal = false
        var hasReActSignal = false

        // 1. Check config.json for the true model origin
        let configURL = modelPath.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let trueName = json["_name_or_path"] as? String {
            originalModelName = trueName.lowercased()
        }

        // 2. Check special_tokens_map.json for explicit tool tokens (HIGH SIGNAL)
        let specialTokensURL = modelPath.appendingPathComponent("special_tokens_map.json")
        if let data = try? Data(contentsOf: specialTokensURL),
           let jsonString = String(data: data, encoding: .utf8) {
            let toolTokens = ["<tool_call>", "[TOOL_CALLS]", "<|eom_id|>", "tool_calls"]
            hasSpecialToolTokens = toolTokens.contains(where: { jsonString.contains($0) })
            // [TOOL_CALLS] token is Mistral's XML-style call marker
            if jsonString.contains("[TOOL_CALLS]") || jsonString.contains("<tool_call>") {
                hasMistralXMLSignal = true
            }
        }

        // 3. Check tokenizer_config.json (Jinja Template) for capability + dialect signals
        let tokenizerURL = modelPath.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: tokenizerURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let chatTemplate = json["chat_template"] as? String {

            // Basic tool mapping support
            hasToolTemplate = chatTemplate.contains("tools") && (chatTemplate.contains("{%") || chatTemplate.contains("{{"))

            // Advanced parallel array mapping support
            hasParallelTemplate = chatTemplate.contains("message.tool_calls") ||
                                  chatTemplate.contains("[TOOL_CALLS]") ||
                                  chatTemplate.contains("<tool_call>")

            // Dialect-specific signals from the Jinja template
            hasMistralXMLSignal = hasMistralXMLSignal ||
                chatTemplate.contains("[TOOL_CALLS]") ||
                chatTemplate.contains("<tool_call>")

            hasReActSignal = chatTemplate.contains("Action Input:") ||
                             chatTemplate.contains("Action:") && chatTemplate.contains("Thought:")
        }

        // --- CAPABILITY DECISION ---

        let capability: ModelCognitiveCapability

        // Tier 1: Explicitly fine-tuned for parallel arrays
        if hasSpecialToolTokens || hasParallelTemplate {
            logger.info("Tokenizer Analysis [\(modelName)]: Detected parallel tool signatures. Tier: Parallel Actions")
            capability = .parallelActions
        }
        // Tier 2: Known capable architectures by family name
        else {
            let knownParallelFamilies = ["llama-3.1", "llama-3.2", "qwen2.5", "hermes-3", "tool-use", "function-calling"]
            if knownParallelFamilies.contains(where: { originalModelName.contains($0) }) {
                logger.info("Tokenizer Analysis [\(modelName)]: Model family known to support parallel arrays. Tier: Parallel Actions")
                capability = .parallelActions
            }
            // Tier 3: Basic Jinja loop for tools, no proof of array support
            else if hasToolTemplate {
                logger.info("Tokenizer Analysis [\(modelName)]: Basic tool support detected. Defaulting to Tier: Single Action")
                capability = .singleAction
            }
            // Tier 4: No tool support detected
            else {
                logger.warning("Tokenizer Analysis [\(modelName)]: No tool logic found. Defaulting to Tier: None")
                capability = .none
            }
        }

        // --- DIALECT DECISION ---

        let dialect: ModelDialect

        if capability == .none {
            // Dialect is irrelevant for no-tool models; use prompted flat JSON as a safe default
            dialect = .promptedFlatJSON
        } else if hasMistralXMLSignal {
            // Model uses <tool_call>...</tool_call> XML wrapping
            dialect = .mistralXML
            logger.info("Tokenizer Analysis [\(modelName)]: Dialect detected — Mistral XML")
        } else if hasReActSignal {
            // Model uses classic Thought/Action/Action Input format
            dialect = .reactMarkdown
            logger.info("Tokenizer Analysis [\(modelName)]: Dialect detected — ReAct Markdown")
        } else if capability == .parallelActions {
            // Modern native JSON array format (OpenAI-compatible)
            dialect = .nativeJSON
            logger.info("Tokenizer Analysis [\(modelName)]: Dialect detected — Native JSON")
        } else {
            // Single-action capability without specific dialect signal: use prompted flat JSON
            dialect = .promptedFlatJSON
            logger.info("Tokenizer Analysis [\(modelName)]: Dialect detected — Prompted Flat JSON (default)")
        }

        // --- METADATA/TIER DETECTION ---
        var modelTier: ModelTier = .small
        let lowerName = modelName.lowercased()
        
        // Simple heuristic for MLX models which often follow HuggingFace naming conventions
        if lowerName.contains("1.5b") || lowerName.contains("3b") || lowerName.contains("1b") || lowerName.contains("tiny") {
             modelTier = .tiny
        } else if lowerName.contains("7b") || lowerName.contains("8b") || lowerName.contains("14b") {
             modelTier = .small
        } else if lowerName.contains("30b") || lowerName.contains("34b") || lowerName.contains("40b") {
             modelTier = .medium
        } else if lowerName.contains("70b") || lowerName.contains("80b") {
             modelTier = .large
        } else if lowerName.contains("100b") || lowerName.contains("405b") {
             modelTier = .ultra
        }
        
        let metadata = ModelMetadata(tier: modelTier, family: originalModelName)

        return (capability, dialect, metadata)
    }
}
