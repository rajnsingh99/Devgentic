//
//  MLXService.swift
//  Devgentic
//
//  Created by Raj Singh on 04/02/26.
//

import Foundation
import CoreImage
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import MLXVLM   // Vision-language models. Importing it also keeps `MLXVLM.TrampolineModelFactory`
               // in the binary so `loadModelContainer`'s registry auto-routes VLMs to the VLM
               // factory (the registry resolves it via NSClassFromString — dead-stripped otherwise).
import os

/// A thread-safe actor that manages the lifecycle and inference of local MLX models.
/// It wraps the `MLXLLM` framework functionality to provide a clean API for the rest of the app.
actor MLXService {
    
    // MARK: - Singleton
    static let shared = MLXService()
    
    private let logger = DGLogger(category: "MLXService")
    
    // MARK: - State
    
    /// The loaded model container (holds weights + tokenizer).
    /// If nil, no model is currently loaded in memory.
    private var modelContainer: ModelContainer?
    
    /// Tracks the directory of the currently loaded model to prevent reloading the same model.
    private var currentModelDirectory: URL?

    /// Preserves the last model directory across idle-timer unloads so
    /// `reloadCurrentModel()` can restore the model after HITL suspension.
    /// Only cleared on explicit model *switch* (loading a different model), never on idle unload.
    private var lastModelDirectory: URL?

    /// Task handle for the auto-unload timer.
    private var idleCleanupTask: Task<Void, Never>?
    
    /// The duration of inactivity before the model is automatically unloaded to save RAM.
    /// Default: 300 seconds (5 minutes).
    private let idleTimeoutNanoseconds: UInt64 = 2 * 60 * 1_000_000_000
    
    private init() {}
    
    // MARK: - Lifecycle Management
    
    /// Loads a model from the specified local directory into memory.
    /// - Parameter directory: The URL pointing to the folder containing `config.json` and `.safetensors`.
    func loadModel(from directory: URL) async throws {
        // Cancel any pending unload timer since we are about to use the model (or load a new one)
        cancelIdleTimer()
        
        // Optimization: Don't reload if it's already the active model
        if let current = currentModelDirectory, current == directory, modelContainer != nil {
            logger.info("Model already loaded: \(directory.lastPathComponent)")
            return
        }
        
        logger.notice("Loading MLX model from: \(directory.path)")
        
        // 1. Clean up previous model to free RAM
        _ = unloadModel()
        
        do {
            // mlx-swift-lm 3.x: `loadModelContainer(from:using:)` replaces the old
            // `loadModelContainer(configuration:)` API. The `using:` parameter is a
            // `TokenizerLoader` that knows how to build an `MLXLMCommon.Tokenizer`
            // from the model folder. We inject our own loader (backed by
            // swift-transformers' `AutoTokenizer`) via `TokenizerBridge`.
            let container = try await MLXLMCommon.loadModelContainer(
                from: directory,
                using: HuggingFaceTokenizerLoader()
            )

            self.modelContainer = container
            self.currentModelDirectory = directory
            self.lastModelDirectory = directory

            logger.notice("Successfully loaded MLX model: \(directory.lastPathComponent)")
            self.logMemoryStats(label: "Post-Load")

        } catch {
            logger.error("Failed to load MLX model: \(error.localizedDescription)")
            // Ensure state is clean on failure
            _ = unloadModel()
            throw error
        }
    }
    
    /// Unloads the current model from memory and forces a cache clear.
    /// - Returns: A dictionary containing memory stats (freed bytes, remaining active, remaining cache).
    @discardableResult
    func unloadModel() -> [String: Int] {
        cancelIdleTimer()
        
        // 1. VISUALIZATION STEP 1: Initial State
        let activeBefore = MLX.Memory.activeMemory
        let cacheBefore = MLX.Memory.cacheMemory
        let totalBefore = activeBefore + cacheBefore
        
        logger.notice("🔻 [Unload Start] Active: \(ByteCountFormatter.string(fromByteCount: Int64(activeBefore), countStyle: .memory)) | Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheBefore), countStyle: .memory))")
        
        if modelContainer != nil {
            // 2. Release Swift reference
            modelContainer = nil
            currentModelDirectory = nil
            
            // 3. VISUALIZATION STEP 2: Intermediate State (Swift Release)
            // At this point, Active should drop, but Cache should spike as buffers are recycled.
            let activeIntermediate = MLX.Memory.activeMemory
            let cacheIntermediate = MLX.Memory.cacheMemory
            logger.debug("🔸 [Ref Released] Active: \(ByteCountFormatter.string(fromByteCount: Int64(activeIntermediate), countStyle: .memory)) | Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheIntermediate), countStyle: .memory)) (Memory moved to cache)")
            
            // 4. FORCE MLX GPU CACHE CLEAR
            // This tells Metal to return the memory to the OS immediately.
            MLX.Memory.clearCache()
            
            // 5. VISUALIZATION STEP 3: Final State
            let activeAfter = MLX.Memory.activeMemory
            let cacheAfter = MLX.Memory.cacheMemory
            let totalAfter = activeAfter + cacheAfter
            
            let freedBytes = totalBefore - totalAfter
            
            logger.notice("✅ [Unload Done] Freed: \(ByteCountFormatter.string(fromByteCount: Int64(freedBytes), countStyle: .memory)) | Remaining Cache: \(ByteCountFormatter.string(fromByteCount: Int64(cacheAfter), countStyle: .memory))")
            
            return [
                "freedBytes": freedBytes,
                "activeMemory": activeAfter,
                "cacheMemory": cacheAfter
            ]
        } else {
            // Even if modelContainer was nil, force clear artifacts
            let cacheBeforeClear = MLX.Memory.cacheMemory
            MLX.Memory.clearCache()
            let cacheAfterClear = MLX.Memory.cacheMemory
            let freed = cacheBeforeClear - cacheAfterClear
            
            if freed > 0 {
                logger.notice("✅ [Cache Cleanup] Freed artifacts: \(ByteCountFormatter.string(fromByteCount: Int64(freed), countStyle: .memory))")
            }
            
            return [
                "freedBytes": freed,
                "activeMemory": MLX.Memory.activeMemory,
                "cacheMemory": cacheAfterClear
            ]
        }
    }

    // MARK: - Model Reload (HITL Recovery)

    /// Reloads the last active model if it was unloaded by the idle timer.
    /// Used by the ReAct executor to recover after HITL suspension caused an idle-timer unload.
    /// No-op if a model is already loaded.
    /// - Returns: `true` if reload succeeded (or model was already loaded), `false` if no model to reload.
    func reloadCurrentModel() async -> Bool {
        if modelContainer != nil { return true }

        guard let directory = lastModelDirectory else {
            logger.warning("Cannot reload: no previous model directory recorded.")
            return false
        }

        logger.notice("♻️ Reloading model from: \(directory.lastPathComponent) (idle-timer recovery)")
        do {
            try await loadModel(from: directory)
            return true
        } catch {
            logger.error("♻️ Reload failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Inference

    /// Streams a chat response from the loaded model.
    /// - Parameters:
    ///   - messages: An array of dictionaries, e.g., `[["role": "user", "content": "Hello"]]`.
    ///   - maxTokens: The maximum number of new tokens to generate.
    ///   - temperature: Controls randomness (0.0 = deterministic, 1.0 = creative).
    ///   - chatTemplateSource: Describes how to obtain the correct chat template for the model.
    ///     Used when the tokenizer lacks a built-in template. Defaults to `.embedded`.
    /// - Returns: An async stream of string tokens.
    func streamChat(
        messages: [[String: String]],
        tools: [[String: Any]]? = nil,
        maxTokens: Int = 2048,
        temperature: Float = 0.6,
        topP: Float = 1.0,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int = 20,
        chatTemplateSource: ChatTemplateSource = .embedded,
        stopSequences: [String] = []
    ) -> AsyncThrowingStream<String, Error> {

        // 1. Cancel any pending idle timer because we are active now.
        cancelIdleTimer()

        return AsyncThrowingStream { continuation in
            Task {
                guard let container = modelContainer else {
                    continuation.finish(throwing: NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No MLX model is currently loaded. Please load a model first."]))
                    return
                }

                do {
                    // Use container.perform to safely access the ModelContext (which contains model, processor, tokenizer).
                    let wrappedMessages = UnsafeSendable(messages)
                    let wrappedTools = UnsafeSendable(tools)

                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // A. Apply Chat Template & Tokenize
                        //
                        // mlx-swift-lm 3.x removed `hasChatTemplate` and the
                        // `applyChatTemplate(chatTemplate: .literal(...))` overload from its
                        // `Tokenizer` protocol. Primary path uses the embedded template;
                        // fallback drops to the bridge's upstream swift-transformers tokenizer
                        // which still has the richer API needed for literal-template override.
                        let sendableMessages = wrappedMessages.value.map { $0 as [String: any Sendable] }
                        let mlxTools: [[String: any Sendable]]? = wrappedTools.value?.map { dict in
                            dict.mapValues { Self.bridgeToSendable($0) }
                        }
                        let toolCount = mlxTools?.count ?? 0
                        if toolCount > 0 {
                            logger.info("🔧 [Tools] Injecting \(toolCount) tool schema(s) into chat template")
                        }

                        let promptTokens: [Int]
                        do {
                            promptTokens = try context.tokenizer.applyChatTemplate(
                                messages: sendableMessages,
                                tools: mlxTools
                            )
                            logger.info("🎯 [Template] embedded render OK — prompt tokens=\(promptTokens.count), tools=\(toolCount)")
                        } catch MLXLMCommon.TokenizerError.missingChatTemplate {
                            // Fallback: tokenizer has no embedded chat template. Drop down to the
                            // upstream swift-transformers API (exposed via TokenizerBridge.upstream)
                            // to render using our stored ChatTemplateSource:
                            //   Layer 1 (.extracted): Raw Jinja from tokenizer_config.json — author's own template.
                            //   Layer 2 (.familyFallback): Hardcoded template matched to the model's token family.
                            logger.warning("⚠️ [Template] No embedded chat_template — falling back to ChatTemplateSource")
                            guard let bridge = context.tokenizer as? TokenizerBridge else {
                                logger.error("❌ [Template] Tokenizer is not TokenizerBridge — cannot run fallback")
                                throw NSError(
                                    domain: "MLXService", code: 500,
                                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer fallback path requires TokenizerBridge; got \(type(of: context.tokenizer))."]
                                )
                            }
                            let fallback = Self.resolveFallbackTemplate(from: chatTemplateSource)
                            logger.info("📝 [Template] Using fallback source=\(String(describing: chatTemplateSource)) (\(fallback.count) chars)")
                            promptTokens = try bridge.upstream.applyChatTemplate(
                                messages: sendableMessages,
                                chatTemplate: .literal(fallback),
                                addGenerationPrompt: true,
                                truncation: false,
                                maxLength: nil,
                                tools: mlxTools
                            )
                            logger.info("✅ [Template] fallback render OK — prompt tokens=\(promptTokens.count), tools=\(toolCount)")
                        }
                        
                        // B. Create LMInput
                        let lmInput = LMInput(tokens: MLXArray(promptTokens))
                        
                        // C. Configure Generation
                        let parameters = GenerateParameters(
                            maxTokens: maxTokens,
                            temperature: temperature,
                            topP: topP,
                            repetitionPenalty: repetitionPenalty,
                            repetitionContextSize: repetitionContextSize
                        )
                        
                        // D. Run Inference
                        return try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                    }
                    
                    // --- Safety Layer 1: Stop Sequence Detection ---
                    // Accumulate a trailing window of generated text and check for
                    // any custom stop sequence suffix after each chunk.
                    // This catches multi-token stop sequences that span chunk boundaries.
                    let maxStopLen = stopSequences.map(\.count).max() ?? 0
                    var trailingWindow = ""
                    var stopDetected = false

                    // --- Safety Layer 2: Streaming Circuit Breaker ---
                    // Monitors for pathological repetition loops where the model
                    // generates the same block of text over and over. Trips after
                    // 3 consecutive repetitions of the same block.
                    var circuitBreaker = StreamingCircuitBreaker()

                    for await generation in stream {
                        switch generation {
                        case .chunk(let text):

                            // Circuit breaker: feed every chunk regardless of stop sequence mode
                            let breakerStatus = circuitBreaker.feed(text)
                            if case .tripped(let reason) = breakerStatus {
                                // Breaker tripped — yield the clean (non-repetitive) portion only
                                logger.warning("⚡ Generation terminated by circuit breaker: \(reason)")

                                // If we were accumulating a stop-sequence window, discard it —
                                // the trimmedOutput() already has the authoritative clean text.
                                // We don't yield here because the circuit breaker's accumulated
                                // text was never yielded in full yet (it was buffered in trailingWindow
                                // or yielded piecemeal). Instead, we'll handle cleanup after the loop.
                                stopDetected = true
                                break
                            }

                            // Stop sequence check
                            if !stopSequences.isEmpty {
                                trailingWindow += text

                                // Check if any stop sequence appears in the trailing window
                                if let matchedStop = stopSequences.first(where: { trailingWindow.contains($0) }) {
                                    // Yield only the text BEFORE the stop sequence
                                    if let range = trailingWindow.range(of: matchedStop) {
                                        let beforeStop = String(trailingWindow[trailingWindow.startIndex..<range.lowerBound])
                                        if !beforeStop.isEmpty {
                                            continuation.yield(beforeStop)
                                        }
                                    }
                                    logger.info("Stop sequence detected: \(matchedStop) — terminating generation")
                                    stopDetected = true
                                    break
                                }

                                // Yield text that can't possibly be part of a stop sequence
                                // Keep only the last `maxStopLen` characters as the trailing window
                                if trailingWindow.count > maxStopLen {
                                    let safeCount = trailingWindow.count - maxStopLen
                                    let safeIndex = trailingWindow.index(trailingWindow.startIndex, offsetBy: safeCount)
                                    let safeText = String(trailingWindow[trailingWindow.startIndex..<safeIndex])
                                    continuation.yield(safeText)
                                    trailingWindow = String(trailingWindow[safeIndex...])
                                }
                            } else {
                                // No stop sequences — pass through directly
                                continuation.yield(text)
                            }

                        case .toolCall(let toolCall):
                            // Flush any remaining trailing window before tool call
                            if !trailingWindow.isEmpty && !stopSequences.isEmpty {
                                continuation.yield(trailingWindow)
                                trailingWindow = ""
                            }

                            let argsDict: [String: Any] = toolCall.function.arguments.mapValues { $0.anyValue }
                            let syntheticStep: [String: Any] = [
                                "content": "Executing tool \(toolCall.function.name)...",
                                "tool_name": toolCall.function.name,
                                "arguments": argsDict
                            ]

                            if let syntheticData = try? JSONSerialization.data(withJSONObject: syntheticStep),
                               let syntheticString = String(data: syntheticData, encoding: .utf8) {
                                continuation.yield(syntheticString)
                            }
                        case .info:
                            break
                        }

                        if stopDetected { break }
                    }

                    // Post-loop cleanup
                    if circuitBreaker.hasTripped {
                        // Circuit breaker tripped — the downstream parser will receive
                        // whatever was already yielded (piecemeal). The repetitive tail
                        // was cut off by breaking out of the loop. No further yield needed.
                        logger.info("Circuit breaker terminated generation after \(circuitBreaker.accumulatedText.count) chars")
                    } else if !stopDetected && !trailingWindow.isEmpty {
                        // Normal completion with pending trailing window — flush it
                        continuation.yield(trailingWindow)
                    }

                    continuation.finish()
                    
                } catch {
                    logger.error("MLX Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
                
                // 2. Inference is complete (success or failure). Start the idle timer.
                self.startIdleTimer()
            }
        }
    }
    
    // MARK: - Vision Inference

    /// Streams a VISION chat response. Uses the SAME loaded `modelContainer` as
    /// `streamChat` (the registry already loaded it via the VLM factory for a vision
    /// `model_type`), but routes through the model's `UserInputProcessor` so attached
    /// images are encoded into the prompt — the processor inserts the per-family image
    /// tokens automatically, so we never hand-place placeholders.
    ///
    /// `imageData` are raw image bytes; `CIImage` is constructed inside `perform` (off
    /// the actor's Sendable path) and attached to the LAST user turn. Generation is a
    /// simple chunk stream — no tool-call / stop-sequence machinery (vision answers are
    /// plain prose).
    func streamVisionChat(
        messages: [[String: String]],
        imageData: [Data],
        maxTokens: Int = 2048,
        temperature: Float = 0.6,
        topP: Float = 1.0
    ) -> AsyncThrowingStream<String, Error> {
        cancelIdleTimer()

        return AsyncThrowingStream { continuation in
            Task {
                guard let container = modelContainer else {
                    continuation.finish(throwing: NSError(domain: "MLXService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No MLX model is currently loaded. Please load a model first."]))
                    return
                }

                do {
                    let wrappedMessages = UnsafeSendable(messages)
                    let wrappedData = UnsafeSendable(imageData)

                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // Decode raw bytes → CIImage → UserInput.Image inside the closure.
                        let images: [UserInput.Image] = wrappedData.value.compactMap { data in
                            CIImage(data: data).map { .ciImage($0) }
                        }

                        // Rebuild the chat, attaching the images to the final user turn.
                        let msgs = wrappedMessages.value
                        let lastUserIdx = msgs.lastIndex(where: { $0["role"] == "user" })
                        var chat: [Chat.Message] = []
                        for (i, m) in msgs.enumerated() {
                            let content = m["content"] ?? ""
                            let imgs = (i == lastUserIdx) ? images : []
                            switch m["role"] {
                            case "system":    chat.append(.system(content, images: imgs))
                            case "assistant": chat.append(.assistant(content, images: imgs))
                            default:          chat.append(.user(content, images: imgs))
                            }
                        }

                        let userInput = UserInput(chat: chat)
                        let lmInput = try await context.processor.prepare(input: userInput)

                        let parameters = GenerateParameters(
                            maxTokens: maxTokens,
                            temperature: temperature,
                            topP: topP,
                            repetitionPenalty: nil,
                            repetitionContextSize: 20
                        )

                        return try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                    }

                    for await generation in stream {
                        if case .chunk(let text) = generation {
                            continuation.yield(text)
                        }
                    }

                    continuation.finish()
                } catch {
                    logger.error("MLX Vision Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }

                self.startIdleTimer()
            }
        }
    }

    // MARK: - Sendable Bridge

    /// Recursively projects a JSON-compatible `Any` into a concrete `Sendable` type.
    /// Tool schemas only contain JSON primitives (String/Int/Double/Bool/Array/Dict),
    /// all of which are Sendable. Anything else is stringified as a defensive fallback.
    private nonisolated static func bridgeToSendable(_ value: Any) -> any Sendable {
        switch value {
        case let v as String: return v
        case let v as Bool: return v
        case let v as Int: return v
        case let v as Double: return v
        case let v as [Any]: return v.map { bridgeToSendable($0) }
        case let v as [String: Any]: return v.mapValues { bridgeToSendable($0) }
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }

    // MARK: - Fallback Chat Templates (Two-Layer Strategy)

    /// Resolves the correct fallback Jinja template from the stored `ChatTemplateSource`.
    ///
    /// - Layer 1 (`.extracted`): Returns the raw Jinja string read from `tokenizer_config.json`
    ///   during model analysis — the model author's own template, most accurate.
    /// - Layer 2 (`.familyFallback`): Returns a hardcoded template matched to the model's
    ///   token vocabulary family (ChatML, Llama 3, Mistral Tekken, etc.).
    /// - `.embedded`: Should never reach here (tokenizer handles it), but falls back to ChatML.
    private static func resolveFallbackTemplate(from source: ChatTemplateSource) -> String {
        switch source {
        case .extracted(let rawJinja):
            return rawJinja

        case .familyFallback(let family):
            return templateForFamily(family)

        case .embedded:
            // This case means the tokenizer reported hasChatTemplate=false despite us thinking
            // it was embedded. Fall back to the most common format.
            return templateForFamily(.chatML)
        }
    }

    /// Returns a hardcoded Jinja chat template for the given model family.
    /// These templates match the training format each model family expects,
    /// ensuring the model correctly understands the input tokenization.
    private static func templateForFamily(_ family: ChatTemplateFamily) -> String {
        switch family {

        case .chatML:
            // Used by: Qwen, Hermes, DeepSeek, Yi, and many community fine-tunes
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "system" %}\
            <|im_start|>system\n{{ message["content"] }}<|im_end|>\n\
            {%- elif message["role"] == "user" %}\
            <|im_start|>user\n{{ message["content"] }}<|im_end|>\n\
            {%- elif message["role"] == "assistant" %}\
            <|im_start|>assistant\n{{ message["content"] }}<|im_end|>\n\
            {%- endif %}\
            {%- endfor %}\
            <|im_start|>assistant\n
            """

        case .llama3:
            // Used by: Llama 3, 3.1, 3.2, 3.3
            return """
            {%- set loop_messages = messages %}\
            {%- for message in loop_messages %}\
            <|start_header_id|>{{ message["role"] }}<|end_header_id|>\n\n\
            {{ message["content"] }}<|eot_id|>\
            {%- endfor %}\
            <|start_header_id|>assistant<|end_header_id|>\n\n
            """

        case .mistralTekken:
            // Used by: Mistral v3/v7, Devstral, Pixtral, Ministral (Tekken tokenizer)
            return """
            {{ bos_token }}\
            {%- if messages[0]["role"] == "system" %}\
            {%- set system_message = messages[0]["content"] %}\
            {%- set loop_messages = messages[1:] %}\
            {%- else %}\
            {%- set loop_messages = messages %}\
            {%- set system_message = "" %}\
            {%- endif %}\
            {%- for message in loop_messages %}\
            {%- if message["role"] == "user" %}\
            [INST]{{ system_message + message["content"] }}[/INST]\
            {%- set system_message = "" %}\
            {%- elif message["role"] == "assistant" %}\
            {{ message["content"] }}{{ eos_token }}\
            {%- endif %}\
            {%- endfor %}
            """

        case .gemma:
            // Used by: Gemma, Gemma 2, CodeGemma
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "user" %}\
            <start_of_turn>user\n{{ message["content"] }}<end_of_turn>\n\
            {%- elif message["role"] == "model" or message["role"] == "assistant" %}\
            <start_of_turn>model\n{{ message["content"] }}<end_of_turn>\n\
            {%- elif message["role"] == "system" %}\
            <start_of_turn>user\n{{ message["content"] }}<end_of_turn>\n\
            {%- endif %}\
            {%- endfor %}\
            <start_of_turn>model\n
            """

        case .phi:
            // Used by: Phi-3, Phi-3.5, Phi-4
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "system" %}\
            <|system|>\n{{ message["content"] }}<|end|>\n\
            {%- elif message["role"] == "user" %}\
            <|user|>\n{{ message["content"] }}<|end|>\n\
            {%- elif message["role"] == "assistant" %}\
            <|assistant|>\n{{ message["content"] }}<|end|>\n\
            {%- endif %}\
            {%- endfor %}\
            <|assistant|>\n
            """

        case .commandR:
            // Used by: Cohere Command-R, Command-R+
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "system" %}\
            <|START_OF_TURN_TOKEN|><|SYSTEM_TOKEN|>{{ message["content"] }}<|END_OF_TURN_TOKEN|>\
            {%- elif message["role"] == "user" %}\
            <|START_OF_TURN_TOKEN|><|USER_TOKEN|>{{ message["content"] }}<|END_OF_TURN_TOKEN|>\
            {%- elif message["role"] == "assistant" %}\
            <|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>{{ message["content"] }}<|END_OF_TURN_TOKEN|>\
            {%- endif %}\
            {%- endfor %}\
            <|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>
            """

        case .zephyr:
            // Used by: Zephyr, Starling
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "system" %}\
            <|system|>\n{{ message["content"] }}</s>\n\
            {%- elif message["role"] == "user" %}\
            <|user|>\n{{ message["content"] }}</s>\n\
            {%- elif message["role"] == "assistant" %}\
            <|assistant|>\n{{ message["content"] }}</s>\n\
            {%- endif %}\
            {%- endfor %}\
            <|assistant|>\n
            """

        case .alpaca:
            // Used by: Alpaca, Vicuna, and legacy instruction-tuned models
            return """
            {%- for message in messages %}\
            {%- if message["role"] == "system" %}\
            {{ message["content"] }}\n\n\
            {%- elif message["role"] == "user" %}\
            ### Instruction:\n{{ message["content"] }}\n\n\
            {%- elif message["role"] == "assistant" %}\
            ### Response:\n{{ message["content"] }}\n\n\
            {%- endif %}\
            {%- endfor %}\
            ### Response:\n
            """
        }
    }

    // MARK: - Diagnostics
    
    private func logMemoryStats(label: String) {
        let active = ByteCountFormatter.string(fromByteCount: Int64(MLX.Memory.activeMemory), countStyle: .memory)
        let cache = ByteCountFormatter.string(fromByteCount: Int64(MLX.Memory.cacheMemory), countStyle: .memory)
        logger.debug("[\(label)] MLX Memory - Active: \(active), Cache: \(cache)")
    }
    
    // MARK: - Idle Management
    
    /// Starts a timer that will unload the model if no further requests are made.
    private func startIdleTimer() {
        cancelIdleTimer() // Ensure no duplicate timers
        
        logger.debug("Starting idle timer. Model will unload in 5 minutes if inactive.")
        
        idleCleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.idleTimeoutNanoseconds ?? 120_000_000_000)
                
                // If we reached here without cancellation, unload.
                guard let self = self else { return }
                
                // Check for cancellation one last time before acting
                if !Task.isCancelled {
                    await self.handleIdleTimeout()
                }
            } catch {
                // Task was cancelled (new request came in), do nothing.
            }
        }
    }
    
    /// Cancels the current idle timer.
    private func cancelIdleTimer() {
        if let task = idleCleanupTask {
            task.cancel()
            idleCleanupTask = nil
            logger.debug("Idle timer cancelled. Model remains active.")
        }
    }
    
    /// The action to perform when the timer fires.
    private func handleIdleTimeout() {
        logger.notice("MLX Service has been idle for 5 minutes. Releasing memory.")
        _ = unloadModel()
    }
}
