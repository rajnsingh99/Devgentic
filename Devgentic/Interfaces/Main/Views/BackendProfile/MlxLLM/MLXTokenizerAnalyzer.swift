//
//  MLXTokenizerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh on 04/03/26.
//  Updated: Enhanced Tiered Capability Detection for MLX Models
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
        let (capability, dialect, metadata, templateSource) = detectCapabilityAndDialect(for: modelPath, modelName: modelName)
        let stopSequences = extractStopSequences(from: modelPath)
        return CognitiveProfile(capability: capability, dialect: dialect, metadata: metadata, chatTemplateSource: templateSource, stopSequences: stopSequences)
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
    ) -> (ModelCognitiveCapability, ModelDialect, ModelMetadata, ChatTemplateSource) {

        var hasToolTemplate = false
        var hasParallelTemplate = false
        var originalModelName = modelName.lowercased()
        var hasSpecialToolTokens = false
        var quantization: String? = nil

        // Track dialect signals from the Jinja template and token maps
        var hasMistralXMLSignal = false
        var hasReActSignal = false

        // Chat template detection state
        var extractedChatTemplate: String? = nil
        var hasChatTemplateInConfig = false

        // Collect all special tokens across files for template family detection
        var allSpecialTokensRaw: String = ""

        let toolTokensToDetect = ["<tool_call>", "[TOOL_CALLS]", "<|eom_id|>", "tool_calls", "[AVAILABLE_TOOLS]", "<function_call>"]

        // 1. Check config.json for the true model origin and quantization info
        let configURL = modelPath.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let trueName = json["_name_or_path"] as? String {
                originalModelName = trueName.lowercased()
            }
            // Extract quantization bits from "quantization" or "quantization_config" dict
            let quantDict = json["quantization"] as? [String: Any] ?? json["quantization_config"] as? [String: Any]
            if let bits = quantDict?["bits"] as? Int {
                quantization = "\(bits)bit"
            }
        }

        // 2. Check special_tokens_map.json for explicit tool tokens (HIGH SIGNAL)
        let specialTokensURL = modelPath.appendingPathComponent("special_tokens_map.json")
        if let data = try? Data(contentsOf: specialTokensURL),
           let jsonString = String(data: data, encoding: .utf8) {

            allSpecialTokensRaw += jsonString
            hasSpecialToolTokens = toolTokensToDetect.contains(where: { jsonString.contains($0) })

            // Mistral XML-style call markers
            if jsonString.contains("[TOOL_CALLS]") || jsonString.contains("<tool_call>") || jsonString.contains("[AVAILABLE_TOOLS]") || jsonString.contains("<function_call>") {
                hasMistralXMLSignal = true
            }
        }

        // 2.5 Check added_tokens.json (Fallback HIGH SIGNAL for some architectures)
        let addedTokensURL = modelPath.appendingPathComponent("added_tokens.json")
        if let data = try? Data(contentsOf: addedTokensURL),
           let jsonString = String(data: data, encoding: .utf8) {

            allSpecialTokensRaw += jsonString
            if toolTokensToDetect.contains(where: { jsonString.contains($0) }) {
                hasSpecialToolTokens = true
            }
            if jsonString.contains("[TOOL_CALLS]") || jsonString.contains("<tool_call>") || jsonString.contains("[AVAILABLE_TOOLS]") || jsonString.contains("<function_call>") {
                hasMistralXMLSignal = true
            }
        }

        // 3. Check tokenizer_config.json for capability + dialect signals
        let tokenizerURL = modelPath.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: tokenizerURL) {

            // ENHANCED CHECK: Aggressively search the raw JSON string.
            // Many Mistral/Pixtral models stash tokens in "extra_special_tokens" instead of dedicated maps.
            if let configStr = String(data: data, encoding: .utf8) {
                allSpecialTokensRaw += configStr
                if toolTokensToDetect.contains(where: { configStr.contains($0) }) {
                    hasSpecialToolTokens = true
                }

                if configStr.contains("[TOOL_CALLS]") || configStr.contains("<tool_call>") || configStr.contains("[AVAILABLE_TOOLS]") || configStr.contains("<function_call>") {
                    hasMistralXMLSignal = true
                }
            }

            // Standard Template Parsing
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let chatTemplate = json["chat_template"] as? String {

                // Layer 1: Extract the raw Jinja template for fallback use
                hasChatTemplateInConfig = true
                extractedChatTemplate = chatTemplate

                // Basic tool mapping support
                hasToolTemplate = chatTemplate.contains("tools") && (chatTemplate.contains("{%") || chatTemplate.contains("{{"))

                // Advanced parallel array mapping support
                hasParallelTemplate = chatTemplate.contains("message.tool_calls") ||
                                      chatTemplate.contains("[TOOL_CALLS]") ||
                                      chatTemplate.contains("<tool_call>") ||
                                      chatTemplate.contains("[AVAILABLE_TOOLS]")

                // Dialect-specific signals from the Jinja template
                hasMistralXMLSignal = hasMistralXMLSignal ||
                    chatTemplate.contains("[TOOL_CALLS]") ||
                    chatTemplate.contains("<tool_call>") ||
                    chatTemplate.contains("[AVAILABLE_TOOLS]")

                hasReActSignal = chatTemplate.contains("Action Input:") ||
                                 (chatTemplate.contains("Action:") && chatTemplate.contains("Thought:"))
            }
        }

        // --- CAPABILITY DECISION ---

        let capability: ModelCognitiveCapability
        let detectionReason: String

        // Tier 1: Explicitly fine-tuned for parallel arrays
        if hasSpecialToolTokens || hasParallelTemplate {
            detectionReason = "Detected parallel tool signatures in tokenizer"
            capability = .parallelActions
        }
        // Tier 2: Known capable architectures by family name
        else {
            let knownParallelFamilies = ["llama-3.1", "llama-3.2", "qwen2.5", "hermes-3", "tool-use", "function-calling", "mistral", "pixtral", "ministral", "devstral"]
            if let matchedFamily = knownParallelFamilies.first(where: { originalModelName.contains($0) }) {
                detectionReason = "Model family (\(matchedFamily)) known to support parallel arrays"
                capability = .parallelActions
            }
            // Tier 3: Basic Jinja loop for tools, no proof of array support
            else if hasToolTemplate {
                detectionReason = "Basic tool support detected in chat template"
                capability = .singleAction
            }
            // Tier 4: No tool support detected
            else {
                detectionReason = "No tool logic found in config, tokens, or template"
                capability = .none
            }
        }

        // --- DIALECT DECISION ---

        let dialect: ModelDialect

        if capability == .none {
            // Dialect is irrelevant for no-tool models; use prompted flat JSON as a safe default
            dialect = .heuristicJson
        } else if hasMistralXMLSignal {
            // Model uses <tool_call>...</tool_call> or [AVAILABLE_TOOLS] XML wrapping
            dialect = .mistralXML
        } else if hasReActSignal {
            // Model uses classic Thought/Action/Action Input format
            dialect = .reactMarkdown
        } else if capability == .parallelActions {
            // Modern native JSON array format (OpenAI-compatible)
            dialect = .nativeJSON
        } else {
            // Single-action capability without specific dialect signal: use prompted flat JSON
            dialect = .heuristicJson
        }

        // --- CHAT TEMPLATE SOURCE DECISION ---
        // Two-Layer Strategy:
        //   Layer 1: Use the raw Jinja template extracted from tokenizer_config.json (author's own template)
        //   Layer 2: Detect the template family from special tokens and use a hardcoded fallback

        let chatTemplateSource: ChatTemplateSource

        if hasChatTemplateInConfig, let rawTemplate = extractedChatTemplate {
            // Layer 1: The config has a chat_template — even if the tokenizer object fails to load it
            // at runtime, we can pass it manually. This is the most accurate path.
            chatTemplateSource = .extracted(rawTemplate)
            logger.info("Chat Template Source: Extracted raw Jinja from tokenizer_config.json (\(rawTemplate.count) chars)")
        } else {
            // Layer 2: No chat_template in config — detect family from special tokens
            let family = Self.detectTemplateFamily(from: allSpecialTokensRaw, modelName: originalModelName)
            chatTemplateSource = .familyFallback(family)
            logger.info("Chat Template Source: Family fallback → \(family.rawValue) (no chat_template in config)")
        }

        // --- CONSOLIDATED LOGGING ---
        logger.info("MLX Analysis [\(modelName)]: Tier: \(capability.rawValue), Dialect: \(dialect.rawValue), Template: \(chatTemplateSource) (\(detectionReason))")

        // --- METADATA/TIER DETECTION ---
        var modelTier: ModelTier = .small
        let lowerName = modelName.lowercased()

        // Matches a parameter-count token like "24b" while rejecting false positives
        // like "3b" inside "3bit". A match requires the token to NOT be followed by
        // "it" (which would form "3bit"), "yte" ("3byte"), or another digit.
        // The token must be preceded by a non-alphanumeric character or start-of-string.
        func matchesParamSize(_ pattern: String) -> Bool {
            let regex = "(^|[^a-z0-9])\(pattern)($|[^a-z0-9i])"
            return lowerName.range(of: regex, options: .regularExpression) != nil
        }

        // Check from largest to smallest to prefer the most specific match.
        // E.g. "Devstral-24B-3bit" should match "24b" (medium), not "3b" (tiny).
        if lowerName.contains("deepseek-v3") || matchesParamSize("405b") || matchesParamSize("100b") {
            modelTier = .ultra
        } else if matchesParamSize("70b") || matchesParamSize("72b") || matchesParamSize("80b") || matchesParamSize("104b") {
            modelTier = .large
        } else if matchesParamSize("22b") || matchesParamSize("24b") || matchesParamSize("27b") || matchesParamSize("30b") || matchesParamSize("32b") || matchesParamSize("34b") || matchesParamSize("40b") {
            modelTier = .medium
        } else if matchesParamSize("7b") || matchesParamSize("8b") || matchesParamSize("9b") || matchesParamSize("12b") || matchesParamSize("14b") {
            modelTier = .small
        } else if matchesParamSize("1\\.5b") || matchesParamSize("3b") || matchesParamSize("1b") || lowerName.contains("tiny") {
            modelTier = .tiny
        }

        let metadata = ModelMetadata(tier: modelTier, quantization: quantization, family: originalModelName)

        return (capability, dialect, metadata, chatTemplateSource)
    }

    // MARK: - Template Family Detection (Layer 2)

    /// Detects the chat template family from the combined special tokens present
    /// across all tokenizer configuration files.
    ///
    /// Priority order reflects specificity: families with unique, unambiguous markers
    /// are checked first. The fallback is ChatML as the most widely adopted format.
    private static func detectTemplateFamily(from allTokensRaw: String, modelName: String) -> ChatTemplateFamily {

        // Llama 3 — unique header tokens unmistakable across all other families
        if allTokensRaw.contains("<|start_header_id|>") || allTokensRaw.contains("<|eot_id|>") {
            return .llama3
        }

        // Mistral Tekken — [INST] is shared with Llama 2 but Tekken has tool markers
        if allTokensRaw.contains("[AVAILABLE_TOOLS]") || allTokensRaw.contains("[TOOL_CALLS]") ||
           (allTokensRaw.contains("[INST]") && (modelName.contains("mistral") || modelName.contains("devstral") || modelName.contains("pixtral") || modelName.contains("ministral"))) {
            return .mistralTekken
        }

        // Gemma — unique turn markers
        if allTokensRaw.contains("<start_of_turn>") || allTokensRaw.contains("<end_of_turn>") {
            return .gemma
        }

        // Command-R — unique turn tokens from Cohere
        if allTokensRaw.contains("<|START_OF_TURN_TOKEN|>") || allTokensRaw.contains("<|USER_TOKEN|>") || allTokensRaw.contains("<|CHATBOT_TOKEN|>") {
            return .commandR
        }

        // ChatML — must check before Phi/Zephyr since `<|im_start|>` is definitive
        if allTokensRaw.contains("<|im_start|>") || allTokensRaw.contains("<|im_end|>") {
            return .chatML
        }

        // Phi — `<|end|>` is unique to Phi (Zephyr uses `</s>` instead)
        if allTokensRaw.contains("<|user|>") && allTokensRaw.contains("<|end|>") {
            return .phi
        }

        // Zephyr — `<|user|>` + `<|assistant|>` without Phi's `<|end|>`
        if allTokensRaw.contains("<|user|>") && allTokensRaw.contains("<|assistant|>") {
            return .zephyr
        }

        // Alpaca/Vicuna — detected by model name since these have no unique special tokens
        if modelName.contains("alpaca") || modelName.contains("vicuna") {
            return .alpaca
        }

        // Ultimate fallback: ChatML is the most widely adopted format across the ecosystem
        logger.info("No template family detected from tokens — defaulting to ChatML")
        return .chatML
    }

    // MARK: - Stop Sequence Extraction

    /// Extracts custom stop sequences from the model's tokenizer files.
    ///
    /// Scans `added_tokens.json` for tokens marked as `"special": true` and collects
    /// their string content. These are turn-boundary markers (e.g. `<|im_end|>`,
    /// `<|eot_id|>`, `[/INST]`, `<end_of_turn>`) that the model should never generate
    /// mid-response. If emitted during generation, it signals the model has crossed
    /// a turn boundary and generation should stop immediately.
    ///
    /// Filters out:
    /// - Pure EOS/BOS tokens (already handled by the MLX framework's built-in EOS detection)
    /// - Padding tokens
    /// - Tokens that are single control characters or empty
    ///
    /// - Parameter modelPath: Path to the model directory containing tokenizer files.
    /// - Returns: An array of stop sequence strings. Empty if none are extractable.
    private static func extractStopSequences(from modelPath: URL) -> [String] {

        // Tokens handled by the MLX framework natively — no need to duplicate at app level
        let frameworkHandledTokens: Set<String> = [
            "<s>", "</s>",                          // Generic BOS/EOS
            "<eos>", "<bos>",
            "<|endoftext|>", "<|end_of_text|>",     // GPT-2 / Llama style EOS
            "<|begin_of_text|>",                    // Llama 3 BOS
            "<pad>", "<|padding|>", "<|pad|>",      // Padding
            "<unk>",                                // Unknown token
        ]

        // Turn-boundary markers we specifically WANT as stop sequences
        // (even if the framework might also catch some of these as EOS)
        let turnBoundaryPatterns: Set<String> = [
            "<|im_end|>", "<|im_start|>",                   // ChatML
            "<|eot_id|>", "<|start_header_id|>",            // Llama 3
            "<|end_header_id|>",
            "[INST]", "[/INST]",                             // Mistral
            "[AVAILABLE_TOOLS]", "[/AVAILABLE_TOOLS]",
            "[TOOL_RESULTS]", "[/TOOL_RESULTS]",
            "[TOOL_CALLS]",
            "<start_of_turn>", "<end_of_turn>",             // Gemma
            "<|user|>", "<|assistant|>", "<|system|>",      // Phi / Zephyr
            "<|end|>",                                       // Phi
            "<|START_OF_TURN_TOKEN|>", "<|END_OF_TURN_TOKEN|>", // Command-R
            "<|USER_TOKEN|>", "<|CHATBOT_TOKEN|>",
            "<|SYSTEM_TOKEN|>",
        ]

        var stopSequences: [String] = []

        // --- Source 1: added_tokens.json ---
        // This file contains a list of token objects with {"content": "...", "special": true/false}
        let addedTokensURL = modelPath.appendingPathComponent("added_tokens.json")
        if let data = try? Data(contentsOf: addedTokensURL),
           let tokens = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {

            for token in tokens {
                guard let content = token["content"] as? String,
                      let isSpecial = token["special"] as? Bool,
                      isSpecial else { continue }

                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count > 1 else { continue }

                // Skip tokens the framework already handles
                if frameworkHandledTokens.contains(trimmed) { continue }

                // Include if it's a known turn-boundary marker
                if turnBoundaryPatterns.contains(trimmed) {
                    stopSequences.append(trimmed)
                }
            }
        }

        // --- Source 2: special_tokens_map.json ---
        // Provides named roles (eos_token, bos_token, additional_special_tokens)
        // We specifically extract additional_special_tokens that match turn boundaries
        let specialTokensURL = modelPath.appendingPathComponent("special_tokens_map.json")
        if let data = try? Data(contentsOf: specialTokensURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Extract additional_special_tokens array
            let additionalTokens: [String]
            if let arr = json["additional_special_tokens"] as? [String] {
                additionalTokens = arr
            } else if let arr = json["additional_special_tokens"] as? [[String: Any]] {
                additionalTokens = arr.compactMap { $0["content"] as? String }
            } else {
                additionalTokens = []
            }

            for content in additionalTokens {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count > 1 else { continue }
                if frameworkHandledTokens.contains(trimmed) { continue }

                if turnBoundaryPatterns.contains(trimmed) && !stopSequences.contains(trimmed) {
                    stopSequences.append(trimmed)
                }
            }
        }

        // --- Source 3: tokenizer_config.json → extra_special_tokens ---
        // Some models (e.g., Mistral/Devstral MLX conversions) store turn-boundary
        // markers as a flat string array in "extra_special_tokens" instead of in
        // added_tokens.json or special_tokens_map.json.
        let tokenizerConfigURL = modelPath.appendingPathComponent("tokenizer_config.json")
        if let data = try? Data(contentsOf: tokenizerConfigURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let extraTokens = json["extra_special_tokens"] as? [String] {

            for content in extraTokens {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed.count > 1 else { continue }
                if frameworkHandledTokens.contains(trimmed) { continue }

                if turnBoundaryPatterns.contains(trimmed) && !stopSequences.contains(trimmed) {
                    stopSequences.append(trimmed)
                }
            }
        }

        // Deduplicate while preserving order
        let unique = NSOrderedSet(array: stopSequences).array as? [String] ?? stopSequences

        if !unique.isEmpty {
            logger.info("Extracted \(unique.count) stop sequence(s): \(unique.joined(separator: ", "))")
        } else {
            logger.info("No custom stop sequences extracted — relying on framework EOS detection only")
        }

        return unique
    }
}
