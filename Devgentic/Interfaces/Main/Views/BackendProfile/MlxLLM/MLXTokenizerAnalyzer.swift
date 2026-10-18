// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXTokenizerAnalyzer.swift
//  Devgentic
//
//  Created by Raj Singh.
//

import Foundation
import OSLog

private let logger = DGLogger(category: "MLXTokenizerAnalyzer")

/// A utility class to analyze MLX model tokenizer configurations to determine
/// its exact tool-calling capabilities and required generation strategy.
enum MLXTokenizerAnalyzer {

    // MARK: - Sidecar file memoisation

    /// Cached contents of a model's small JSON sidecars, keyed by path and modification date.
    /// One read per (path, mtime) avoids repeated blocking reads; an edited or re-downloaded model is still picked up.
    private static let sidecarLock = NSLock()
    nonisolated(unsafe) private static var sidecarCache: [String: Data?] = [:]

    /// Drop-in replacement for `try? Data(contentsOf:)` on these sidecars.
    static func cachedSidecarData(at url: URL) -> Data? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.standardizedFileURL.path)|\(mtime)"

        sidecarLock.lock()
        if let hit = sidecarCache[key] {
            sidecarLock.unlock()
            return hit
        }
        sidecarLock.unlock()

        let data = try? Data(contentsOf: url)

        sidecarLock.lock()
        // Bounded: a few small JSON files per installed model. Reset wholesale rather than
        // grow without limit if a pathological library ever blows past this.
        if sidecarCache.count > 512 { sidecarCache.removeAll(keepingCapacity: true) }
        sidecarCache[key] = data
        sidecarLock.unlock()
        return data
    }

    /// Invalidate everything — call when models are added or removed on disk.
    static func clearSidecarCache() {
        sidecarLock.lock()
        sidecarCache.removeAll(keepingCapacity: true)
        sidecarLock.unlock()
    }


    // MARK: - Full Profile Detection (Step 1.2)

    /// Evaluates model config files into a complete `CognitiveProfile` (capability tier and output dialect).
    /// - Parameters: `modelPath` is the model directory; `modelName` is the display name, a heuristic fallback.
    /// - Returns: a `CognitiveProfile` encoding both capability and dialect.
    static func detectCognitiveProfile(for modelPath: URL, modelName: String) -> CognitiveProfile {
        // A missing or unparseable config.json degrades to "text-only", indistinguishable from a chat-only model;
        // report it explicitly so a corrupt file does not silently look like a model limitation.
        let configURL = modelPath.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: configURL.path) {
            logger.error("[MLXSTORE] '\(modelName)' has no config.json at \(configURL.path). CONSEQUENCE: capability, dialect and context window are all unknown — it will be reported as text-only with no tool support, which looks identical to a genuine chat-only model.")
        } else if let data = cachedSidecarData(at: configURL),
                  (try? JSONSerialization.jsonObject(with: data)) == nil {
            logger.error("[MLXSTORE] '\(modelName)' has an UNPARSEABLE config.json at \(configURL.path) (\(data.count) bytes). CONSEQUENCE: same as missing — reported as text-only with no tool support; the model is likely a truncated or corrupt download.")
        }

        let (capability, dialect, metadata, templateSource) = detectCapabilityAndDialect(for: modelPath, modelName: modelName)
        let stopSequences = extractStopSequences(from: modelPath)
        let modalities = detectVisionModalities(for: modelPath)
        return CognitiveProfile(capability: capability, dialect: dialect, metadata: metadata, modalities: modalities, chatTemplateSource: templateSource, stopSequences: stopSequences)
    }

    // MARK: - Vision Detection

    // Why: absent by design: mllama, llava, phi3_v, minicpmv, internvl_chat cannot run in MLXVLM; they degrade to
    // text.
    /// VLM `model_type` identifiers the bundled MLXVLM runtime (`MLXVLM.VLMTypeRegistry.shared`) can actually run.
    /// Mirrored by hand because the registry's keys are private; re-sync when bumping mlx-swift-lm.
    /// Ambiguous text/vision types (`qwen3_5`, `qwen3_5_moe`) are excluded to fail closed.
    private static let visionModelTypes: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "idefics3", "gemma3", "gemma4", "smolvlm",
        "fastvlm", "llava_qwen2", "pixtral", "mistral3",
        "lfm2_vl", "lfm2-vl", "glm_ocr"
    ]

    /// Reads `config.json`'s top-level `model_type` (the authoritative VLM signal) and reports `.visionCapable` iff
    /// MLXVLM can run it. Text-only Gemma-3 ships as `gemma3_text`, not `gemma3`, so it correctly stays text-only.
    private static func detectVisionModalities(for modelPath: URL) -> SupportedModalities {
        let configURL = modelPath.appendingPathComponent("config.json")
        guard let data = cachedSidecarData(at: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = (json["model_type"] as? String)?.lowercased() else {
            return .textOnly
        }
        return visionModelTypes.contains(modelType) ? .visionCapable : .textOnly
    }

    // MARK: - Context Window Detection

    /// Reads the trained context length from `config.json` so the gauge and window-derived budgets use the real size
    /// instead of the conservative 8K fallback `EffectiveContextWindow` applies when metadata carries none.
    private static func detectContextWindow(for modelPath: URL) -> Int? {
        let configURL = modelPath.appendingPathComponent("config.json")
        guard let data = cachedSidecarData(at: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return contextWindow(fromConfig: json)
    }

    /// Pure extraction (testable without a model on disk): reads the standard HF/MLX context-length keys in priority
    /// order, unwrapping a nested `text_config`. `sliding_window` is excluded: it is an attention span, not the max
    /// position count.
    static func contextWindow(fromConfig json: [String: Any]) -> Int? {
        let keys = ["max_position_embeddings", "n_positions", "max_seq_len", "max_sequence_length", "seq_length", "n_ctx"]
        let nested = json["text_config"] as? [String: Any]
        for key in keys {
            if let value = positiveInt(json[key]) ?? nested.flatMap({ positiveInt($0[key]) }) {
                return value
            }
        }
        return nil
    }

    /// JSON numbers arrive as Int / Double / NSNumber / String — normalize to a positive
    /// Int, rejecting zero, negatives, and non-numeric values.
    private static func positiveInt(_ any: Any?) -> Int? {
        let value: Int?
        switch any {
        case let i as Int: value = i
        case let d as Double: value = Int(d)
        case let n as NSNumber: value = n.intValue
        case let s as String: value = Int(s)
        default: value = nil
        }
        guard let resolved = value, resolved > 0 else { return nil }
        return resolved
    }

    // MARK: - Legacy Capability-Only API (backward compat)

    /// Evaluates multiple model configuration files to determine structural capability.
    /// - Parameters: `modelPath` is the model directory; `modelName` is the display name, a heuristic fallback.
    /// - Returns: the model's `ModelCognitiveCapability` tier.
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
        if let data = cachedSidecarData(at: configURL),
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
        if let data = cachedSidecarData(at: specialTokensURL),
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
        if let data = cachedSidecarData(at: addedTokensURL),
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
        if let data = cachedSidecarData(at: tokenizerURL) {

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

        // Why: distilled reasoning models inherit tool tokens without tool calling; the family fallback would misrate
        // them.
        // Tier 0: reasoning-only fine-tunes force `.none` regardless of tokenizer signals. Both the display name and
        // `_name_or_path` from config.json are checked; either can preserve the reasoning-only identity.
        if ModelCapabilityHeuristics.isReasoningOnly(nameCandidates: modelName, originalModelName) {
            detectionReason = "Reasoning-only pattern matched — forcing .none"
            capability = .none
        }
        // Tier 1: Explicitly fine-tuned for parallel arrays
        else if hasSpecialToolTokens || hasParallelTemplate {
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

        // Dialect decision, in order: template fingerprint of the extracted Jinja (ground truth), special-token
        // heuristics, then a capability default (nativeJSON for parallel, heuristicJson otherwise).

        let dialect: ModelDialect

        if capability == .none {
            // Dialect is irrelevant for no-tool models; use prompted flat JSON as a safe default
            dialect = .heuristicJson
        } else if let template = extractedChatTemplate,
                  let fingerprinted = ChatTemplateFingerprinter.detect(chatTemplate: template) {
            // Layer 1: Jinja template fingerprinting is ground truth — overrides token heuristics.
            dialect = fingerprinted
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

        // Chat template source decision: use the raw Jinja template from tokenizer_config.json (the author's own) when
        // present; otherwise detect the template family from special tokens and use a hardcoded fallback.

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

        // Matches a parameter-count token like "24b" while rejecting false positives like "3b" inside "3bit".
        // It must follow a non-alphanumeric (or the start) and not be followed by "it", "yte" or a digit.
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

        let detectedContextWindow = detectContextWindow(for: modelPath)
        if let cw = detectedContextWindow {
            logger.info("MLX context window [\(modelName)]: \(cw) tokens (config.json) — gauge + memory/RAG/native-turn budgets now use the real window instead of the 8K fallback.")
        } else {
            logger.notice("MLX context window [\(modelName)]: not found in config.json — EffectiveContextWindow keeps the conservative 8K fallback. Add a key to MLXTokenizerAnalyzer.contextWindow(fromConfig:) if this model exposes one under a different name.")
        }
        let metadata = ModelMetadata(tier: modelTier, contextWindow: detectedContextWindow, quantization: quantization, family: originalModelName)

        return (capability, dialect, metadata, chatTemplateSource)
    }

    // MARK: - Template Family Detection (Layer 2)

    /// Detects the chat template family from the special tokens present across all tokenizer configuration files.
    /// Families with unique markers are checked first; the fallback is ChatML as the most widely adopted format.
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

    /// Extracts turn-boundary stop sequences (e.g. `<|im_end|>`, `[/INST]`) from the model's tokenizer files.
    /// Filters pure EOS/BOS tokens (handled by MLX), padding, and single-control-character or empty tokens.
    /// - Returns: the stop sequences, empty if none are extractable.
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
        if let data = cachedSidecarData(at: addedTokensURL),
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

        // Source 2: special_tokens_map.json provides named roles; extract the `additional_special_tokens` that match turn
        // boundaries.
        let specialTokensURL = modelPath.appendingPathComponent("special_tokens_map.json")
        if let data = cachedSidecarData(at: specialTokensURL),
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

        // Source 3: `extra_special_tokens` in tokenizer_config.json, where some models (Mistral/Devstral MLX conversions)
        // store turn-boundary markers as a flat string array instead of in added_tokens.json or special_tokens_map.json.
        let tokenizerConfigURL = modelPath.appendingPathComponent("tokenizer_config.json")
        if let data = cachedSidecarData(at: tokenizerConfigURL),
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
