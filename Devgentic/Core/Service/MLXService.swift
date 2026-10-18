// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
//
//  MLXService.swift
//  Devgentic
//
//  Created by Raj Singh.
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

    /// Instance-stable bridged tool schemas — see `BridgedToolsStore` for the measured rationale.
    private var bridgedToolsStore = BridgedToolsStore()
    
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

    /// Errors this actor throws to its callers.
    enum ServiceError: LocalizedError {
        /// The resident container is not the model the request asked for, and reloading the
        /// requested one did not resolve it (a concurrent load won the race).
        case modelIdentityMismatch(expected: String, actual: String)
        case noModelLoaded

        var errorDescription: String? {
            switch self {
            case .modelIdentityMismatch(let expected, let actual):
                return "Expected the '\(expected)' model but '\(actual)' is loaded. The request was refused rather than answered by the wrong model."
            case .noModelLoaded:
                return "No MLX model is currently loaded. Please load a model first."
            }
        }
    }

    // Why: `hasContainer` is separate: `loadModel` clears the container first, so the right path alone is not residency.
    /// Returns whether a request expecting `expected` can be served: a container is loaded and came from that directory.
    /// Paths are compared standardized, since `/a/b`, `/a/b/` and `/a/c/../b` name the same model.
    nonisolated static func isResident(expected: URL, resident: URL?, hasContainer: Bool) -> Bool {
        guard hasContainer, let resident else { return false }
        return samePath(resident, expected)
    }

    /// Returns whether two model directories are the same location, compared lexically.
    /// Lexical on purpose: it runs per request, and model directories derive from the service's own `modelsDirectory`.
    nonisolated static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.sameLocationLexically(as: rhs)
    }

    private func container(expecting directory: URL?) async throws -> ModelContainer {
        guard let directory else {
            // No expected identity was supplied; keeps the lazy reload but logs it, since the wrong model could answer.
            if modelContainer == nil, lastModelDirectory != nil {
                logger.warning("[MLX-LOAD] Lazy reload with NO expected model identity — restoring '\(self.lastModelDirectory?.lastPathComponent ?? "?")', whichever model that happens to be. CONSEQUENCE: if another caller loaded a different model, this generation is answered by it.")
                _ = await reloadCurrentModel()
            }
            guard let container = modelContainer else { throw ServiceError.noModelLoaded }
            return container
        }

        let target = directory.standardizedFileURL

        // Up to two attempts, so a concurrent load emptying the slot between our load and the check settles instead of failing.
        for attempt in 1...2 {
            if Self.isResident(expected: directory, resident: currentModelDirectory,
                               hasContainer: modelContainer != nil) { break }
            if let current = currentModelDirectory, !Self.samePath(current, directory) {
                logger.notice("[MLX-LOAD] Model identity mismatch (attempt \(attempt) of 2): request expects '\(directory.lastPathComponent)', container holds '\(current.lastPathComponent)' — loading the expected model instead of generating from the resident one.")
            } else if attempt > 1 {
                logger.notice("[MLX-LOAD] '\(directory.lastPathComponent)' loaded but the container slot was emptied by a concurrent load before this request could take it — retrying once rather than failing the request.")
            }
            try await loadModel(from: directory)
        }

        // No suspension is allowed between this check and the return.
        guard let container = modelContainer,
              Self.isResident(expected: directory, resident: currentModelDirectory,
                              hasContainer: true) else {
            let actual = currentModelDirectory?.lastPathComponent ?? "<none>"
            logger.error("[MLX-LOAD] REFUSING to generate: expected '\(directory.lastPathComponent)' but '\(actual)' is resident after a load attempt — a concurrent load won the race. CONSEQUENCE: this request throws instead of returning an answer produced by the wrong model.")
            throw ServiceError.modelIdentityMismatch(expected: directory.lastPathComponent, actual: actual)
        }
        return container
    }

    /// Whether `directory` is the resident model or the one a lazy `reloadCurrentModel()` would restore.
    /// `MLXModelService.deleteModel` consults this before removing files.
    func isModelLoaded(at directory: URL) -> Bool {
        // Path comparison — see `samePath`. A false negative here lets `deleteModel` remove
        // files underneath a resident model.
        if let current = currentModelDirectory, Self.samePath(current, directory) { return true }
        if let last = lastModelDirectory, Self.samePath(last, directory) { return true }
        return false
    }

    /// Forgets a model directory after its files have been removed, so the lazy reload path
    /// cannot try to restore it.
    func forgetModel(at directory: URL) {
        if let last = lastModelDirectory, Self.samePath(last, directory) {
            logger.notice("Clearing lastModelDirectory for deleted model \(directory.lastPathComponent) — reload recovery would otherwise target a path that no longer exists.")
            lastModelDirectory = nil
        }
        if let current = currentModelDirectory, Self.samePath(current, directory) {
            currentModelDirectory = nil
        }
    }

    /// True while at least one generation is streaming. Callers that mutate model state on
    /// disk must not do so underneath a running generation.
    var hasActiveGenerations: Bool { activeGenerations > 0 }

    /// Task handle for the auto-unload timer.
    private var idleCleanupTask: Task<Void, Never>?

    /// The inactivity duration before the model is automatically unloaded to save RAM.
    private let idleTimeoutNanoseconds: UInt64 = 2 * 60 * 1_000_000_000

    /// Human-readable form of the idle timeout for log messages.
    private var idleTimeoutDescription: String {
        "\(idleTimeoutNanoseconds / 60_000_000_000) minute(s)"
    }

    // Why: the idle timer can fire during actor-reentrancy windows mid-stream and would unload an active model.
    /// Count of in-flight generations (stream tasks between start and finish).
    /// Both `handleIdleTimeout` and `unloadModel` refuse while this is non-zero.
    private var activeGenerations = 0

    /// In-flight model load, published so concurrent `loadModel` calls (actor
    /// reentrancy across the container-load await) coalesce onto one load
    /// instead of double-loading the full model.
    private var loadInFlight: Task<Void, Error>?

    /// The agent's KV cache between iterations — see `MLXPromptCache`. One slot: the current
    /// model's, keyed by conversation. Checked out exclusively by one generation at a time.
    private var promptCacheSlot: MLXPromptCacheSlot?
    private var promptCacheSlotInUse = false
    /// Bumped on every unload. A slot checked out before an unload belongs to a model instance
    /// that is gone, so it is never checked back in.
    private var promptCacheEpoch = 0
    
    private init() {
        MLXMemoryPolicy.configure()
    }
    
    // MARK: - Lifecycle Management
    
    /// Loads a model from the specified local directory into memory.
    /// - Parameter directory: The URL pointing to the folder containing `config.json` and `.safetensors`.
    func loadModel(from directory: URL) async throws {
        // Cancel any pending unload timer since we are about to use the model (or load a new one)
        cancelIdleTimer()

        // Coalesces concurrent loads: the actor is reentrant across the awaits, so two lazy reloads would double-load the model.
        if let inflight = loadInFlight {
            _ = try? await inflight.value
        }

        // Optimization: Don't reload if it's already the active model
        if let current = currentModelDirectory, current == directory, modelContainer != nil {
            logger.info("Model already loaded: \(directory.lastPathComponent)")
            return
        }

        // Logs pre-load headroom before the allocation; descriptive only, nothing here refuses a load.
        let onDiskBytes = MLXModelService.directorySize(at: directory)
        let hardware = SystemHardwareProfiler.shared.profile
        let fit = ModelFitAdvisor.assess(
            metadata: nil,
            diskSizeBytes: onDiskBytes > 0 ? onDiskBytes : nil,
            modelName: directory.lastPathComponent
        )
        logger.notice("[MLX-LOAD] Loading '\(directory.lastPathComponent)' — on disk \(ByteCountFormatter.string(fromByteCount: onDiskBytes, countStyle: .file)), est. runtime \(fit.formattedEstimatedRAM), budget \(hardware.formattedEffectiveBudget), verdict \(fit.verdict.rawValue). \(fit.verdict == .risky || fit.verdict == .incompatible ? "CONSEQUENCE: this exceeds the safe threshold — expect memory pressure and swapping, especially if an Intelligence Core model is also resident." : "")")

        logger.notice("Loading MLX model from: \(directory.path)")

        // Forced unload of the previous model; a swap is safe mid-generation since in-flight work holds its own container.
        _ = performUnload()
        
        // Publish the in-flight load so concurrent callers await it instead of
        // starting a duplicate load (see coalescing check above).
        let load = Task { () throws -> Void in
            // Loads the container through `TokenizerBridge`, which backs the framework's `TokenizerLoader` with swift-transformers.
            let container = try await MLXLMCommon.loadModelContainer(
                from: directory,
                using: HuggingFaceTokenizerLoader()
            )

            self.modelContainer = container
            self.currentModelDirectory = directory
            self.lastModelDirectory = directory

            self.logger.notice("Successfully loaded MLX model: \(directory.lastPathComponent)")
            self.logMemoryStats(label: "Post-Load")
        }
        loadInFlight = load
        // Clears only our own `loadInFlight` handle; clearing another caller's handle would allow a duplicate model load.
        defer { if loadInFlight == load { loadInFlight = nil } }

        do {
            try await load.value
        } catch {
            logger.error("Failed to load MLX model: \(error.localizedDescription)")
            // Ensure state is clean on failure
            _ = performUnload()
            throw error
        }
    }
    
    /// Unloads the current model from memory and forces a cache clear.
    /// Refuses while a generation is in flight; `loadModel` swaps containers through `performUnload()` directly.
    /// - Returns: A dictionary containing memory stats (freed bytes, remaining active, remaining cache).
    @discardableResult
    func unloadModel() -> [String: Int] {
        guard activeGenerations == 0 else {
            logger.warning("[MLX-LOAD] Refusing model unload — \(self.activeGenerations) generation(s) still in flight for \(self.currentModelDirectory?.lastPathComponent ?? "<none>"). CONSEQUENCE: the model stays resident until they finish or the 2-minute idle timer fires; a cancelled consumer should have cancelled its producer, so a persistent count here means a stream leaked.")
            return [:]
        }
        return performUnload()
    }

    /// Unloads the resident model unless it is one of `keep`; refuses while a generation is in flight.
    /// - Returns: whether a model was unloaded.
    /// - Parameter reason: who asked, named in the log.
    @discardableResult
    func unloadModel(unlessResidentIn keep: [URL], reason: String) -> Bool {
        guard let current = currentModelDirectory, modelContainer != nil else {
            logger.debug("[MLX-LOAD] Residency step (\(reason)): no MLX model resident — nothing to unload.")
            return false
        }
        if keep.contains(where: { Self.samePath($0, current) }) {
            logger.debug("[MLX-LOAD] Residency step (\(reason)): keeping '\(current.lastPathComponent)' — the new holder uses it.")
            return false
        }
        // `unloadModel()` logs its own refusal while a generation is in flight; this line must not
        // claim an unload that then does not happen.
        guard activeGenerations == 0 else { return !unloadModel().isEmpty }
        logger.notice("[MLX-LOAD] Unloading '\(current.lastPathComponent)' — \(reason) and does not use it\(keep.isEmpty ? "" : " (it needs \(keep.map(\.lastPathComponent).joined(separator: ", ")))").")
        return !unloadModel().isEmpty
    }

    // MARK: - Prompt cache slot

    #if DEBUG
    /// Test seam: installs an in-memory container the way `loadModel` would, so the generation path
    /// runs against a tiny random-weight model with nothing on disk.
    func installContainerForTesting(_ container: ModelContainer, directory: URL) {
        _ = performUnload()
        modelContainer = container
        currentModelDirectory = directory
        lastModelDirectory = directory
    }

    /// The conversation the cache holds and how many prompt tokens it represents.
    var promptCacheLedgerForTesting: (key: String, tokens: Int)? {
        promptCacheSlot.map { ($0.key, $0.tokens.count) }
    }

    /// Prompt tokens each text generation took from the cache, in call order (0 = read in full).
    private(set) var promptCacheReuseForTesting: [Int] = []

    /// Tokens each keyed generation had written past its prompt when it ended, before the trim.
    private(set) var generatedTokensAtSettleForTesting: [Int] = []
    #endif

    /// Hands the cache slot for `key` to one generation. Nil (run without a cache, exactly as
    /// before) when another generation holds it; that generation keeps it, nothing is evicted.
    private func checkOutPromptCache(key: String) -> MLXPromptCacheSlot? {
        guard !promptCacheSlotInUse else {
            logger.notice("[MLX-CACHE] The cache is in use by another generation; this call for \(key.prefix(8)) runs without one. CONSEQUENCE: it reads its whole prompt; the other run's cache is untouched.")
            return nil
        }
        promptCacheSlotInUse = true
        if let slot = promptCacheSlot, slot.key == key, slot.modelDirectory == currentModelDirectory,
           slot.epoch == promptCacheEpoch {
            promptCacheSlot = nil
            return slot
        }
        if let previous = promptCacheSlot {
            logger.info("[MLX-CACHE] Conversation \(key.prefix(8)) takes the cache from \(previous.key.prefix(8)) (\(previous.tokens.count) tokens dropped). CONSEQUENCE: \(previous.key.prefix(8)) reads its whole prompt next time.")
        }
        promptCacheSlot = nil
        return MLXPromptCacheSlot(key: key, modelDirectory: currentModelDirectory, epoch: promptCacheEpoch)
    }

    /// Returns the slot. Dropped instead when the model it was built for has been unloaded or
    /// swapped meanwhile, or when it holds nothing reusable.
    private func checkInPromptCache(_ slot: MLXPromptCacheSlot) {
        promptCacheSlotInUse = false
        guard slot.epoch == promptCacheEpoch, slot.modelDirectory == currentModelDirectory,
              slot.cache != nil, !slot.tokens.isEmpty else { return }
        promptCacheSlot = slot
    }

    /// The actual unload, no in-flight guard. Safe during a container swap: an
    /// in-flight generation holds its own container reference (kept alive as
    /// active memory), and clearing the recycle cache never touches buffers in use.
    @discardableResult
    private func performUnload() -> [String: Int] {
        cancelIdleTimer()

        // The KV cache belongs to this model instance and is often hundreds of MB (36 KB/token on
        // Qwen2.5-3B). Dropped here, before the buffer clear below, so its memory is returned too.
        if let slot = promptCacheSlot {
            logger.info("[MLX-CACHE] Dropping the cached prompt (\(slot.tokens.count) tokens) with the model. CONSEQUENCE: the next agent iteration reads its whole prompt.")
        }
        promptCacheSlot = nil
        promptCacheEpoch += 1

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
            MLXMemoryPolicy.clearBufferCache(caller: "MLXService unload")
            
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
            MLXMemoryPolicy.clearBufferCache(caller: "MLXService unload (no model)")
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

    /// Reloads the last active model if the idle timer unloaded it, e.g. after a HITL suspension.
    /// No-op if a model is already loaded.
    /// - Returns: `true` if reload succeeded (or a model was already loaded), `false` if there is no model to reload.
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
    /// With `expectedModelDirectory` the generation is served by that model or throws; `nil` logs a warning.
    /// `messages` are role/content dictionaries, `maxTokens` caps new tokens, `chatTemplateSource` supplies the template.
    func streamChat(
        expectedModelDirectory: URL? = nil,
        messages: [[String: String]],
        tools: [[String: Any]]? = nil,
        maxTokens: Int = 2048,
        temperature: Float = 0.6,
        topP: Float = 1.0,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int = 20,
        chatTemplateSource: ChatTemplateSource = .embedded,
        stopSequences: [String] = [],
        // Invoked once with EXACT provider token counts (mlx-swift-lm's terminal
        // completion event) so MLX can report real usage instead of a chars/4 estimate.
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {

        // 1. Cancel any pending idle timer because we are active now.
        cancelIdleTimer()

        // Read in the CALLER's task: only an agent iteration's or a Bot message's call carries a key.
        let promptCacheKey = MLXPromptCache.isEnabled ? MLXPromptCacheScope.key : nil

        return AsyncThrowingStream { continuation in
            // The producer handle is captured and cancelled on termination so Stop halts decoding and releases `activeGenerations`.
            let producer = Task {
                activeGenerations += 1
                defer { activeGenerations -= 1 }

                // Lazy reload: an idle-timer unload between iterations recovers inline, identity-checked by `container(expecting:)`.
                let container: ModelContainer
                do {
                    container = try await self.container(expecting: expectedModelDirectory)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                // Taken after the container, so the slot is checked against the model that will
                // actually serve this call. Always checked back in, success or failure.
                let promptCacheSlot = promptCacheKey.flatMap { self.checkOutPromptCache(key: $0) }
                let wrappedSlot = UnsafeSendable(promptCacheSlot)
                var generationSucceeded = false
                defer {
                    if let promptCacheSlot {
                        #if DEBUG
                        if let offset = promptCacheSlot.cache?.first?.offset {
                            self.generatedTokensAtSettleForTesting.append(offset - promptCacheSlot.pendingPromptTokens.count)
                        }
                        #endif
                        let settlement = MLXPromptCache.settle(slot: promptCacheSlot, succeeded: generationSucceeded)
                        if case .invalidated(let why) = settlement {
                            self.logger.notice("[MLX-CACHE] Cache for \(promptCacheSlot.key.prefix(8)) discarded: \(why). CONSEQUENCE: the next iteration reads its whole prompt.")
                        }
                        self.checkInPromptCache(promptCacheSlot)
                    }
                }

                do {
                    // Use container.perform to safely access the ModelContext (which contains model, processor, tokenizer).
                    let wrappedMessages = UnsafeSendable(messages)
                    // Bridged on the actor so equal tool content reuses the same dictionary instances and the `<tools>` bytes stay stable.
                    let wrappedTools = UnsafeSendable(tools.map { self.bridgedToolsStore.stableInstances(for: $0) })

                    // Converts MLX C++ fatal errors into a Swift throw via a task-local `withError` handler.
                    // Must wrap both the perform and the consume, since the generation task inherits the handler.
                    try await withError {
                    let generation = try await container.perform { context -> (AsyncStream<Generation>, Task<Void, Never>, Int) in
                        // Applies the chat template and tokenizes: embedded template first, then the bridge's swift-transformers tokenizer.
                        let sendableMessages = wrappedMessages.value.map { $0 as [String: any Sendable] }
                        let mlxTools: [[String: any Sendable]]? = wrappedTools.value
                        let toolCount = mlxTools?.count ?? 0
                        if toolCount > 0 {
                            logger.info("🔧 [Tools] Injecting \(toolCount) tool schema(s) into chat template")
                        }

                        let promptTokens: [Int]

                        // Known-corrupt templates are repaired before the embedded render; healthy templates take the embedded path unchanged.
                        let templateRepair: ChatTemplateRepair.Result? = {
                            guard case .extracted(let raw) = chatTemplateSource else { return nil }
                            let result = ChatTemplateRepair.repair(raw)
                            return result.applied.isEmpty ? nil : result
                        }()

                        if let repair = templateRepair, let bridge = context.tokenizer as? TokenizerBridge {
                            for fix in repair.applied {
                                logger.warning("[TEMPLATE-REPAIR] Shipped chat template is corrupt — repaired: \(fix). CONSEQUENCE: rendering with the repaired template via the literal-template bridge instead of the tokenizer's embedded copy; the model now sees a well-formed formatting example. The on-disk artifact is untouched (re-downloads would clobber an edit) — report it upstream.")
                            }
                            promptTokens = try bridge.upstream.applyChatTemplate(
                                messages: sendableMessages,
                                chatTemplate: .literal(repair.template),
                                addGenerationPrompt: true,
                                truncation: false,
                                maxLength: nil,
                                tools: mlxTools
                            )
                            logger.info("🎯 [Template] repaired-literal render OK — prompt tokens=\(promptTokens.count), tools=\(toolCount)")
                        } else {
                        if templateRepair != nil {
                            // Repair matched but the tokenizer is not the bridge type; proceeds with the embedded template and logs it loudly.
                            logger.error("[TEMPLATE-REPAIR] Repair matched but tokenizer is \(type(of: context.tokenizer)), not TokenizerBridge — CANNOT apply. CONSEQUENCE: rendering the CORRUPT embedded template; expect the doubled-brace tool-call discard on this model.")
                        }
                        do {
                            promptTokens = try context.tokenizer.applyChatTemplate(
                                messages: sendableMessages,
                                tools: mlxTools
                            )
                            logger.info("🎯 [Template] embedded render OK — prompt tokens=\(promptTokens.count), tools=\(toolCount)")
                        } catch MLXLMCommon.TokenizerError.missingChatTemplate {
                            // No embedded chat template: renders through swift-transformers using the stored `ChatTemplateSource`.
                            // Layer 1 is the extracted Jinja template; layer 2 is a family fallback.
                            logger.warning("⚠️ [Template] No embedded chat_template — falling back to ChatTemplateSource")
                            guard let bridge = context.tokenizer as? TokenizerBridge else {
                                logger.error("❌ [Template] Tokenizer is not TokenizerBridge — cannot run fallback")
                                throw NSError(
                                    domain: "MLXService", code: 500,
                                    userInfo: [NSLocalizedDescriptionKey: "Tokenizer fallback path requires TokenizerBridge; got \(type(of: context.tokenizer))."]
                                )
                            }
                            // The fallback template goes through the same repair register as the primary path.
                            let fallbackRepair = ChatTemplateRepair.repair(Self.resolveFallbackTemplate(from: chatTemplateSource))
                            for fix in fallbackRepair.applied {
                                logger.warning("[TEMPLATE-REPAIR] Fallback template repaired: \(fix)")
                            }
                            let fallback = fallbackRepair.template
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
                        }
                        
                        // Dumps the final chat-template output, the model's actual input including tool scaffolding and turn markers.
                        // `skipSpecialTokens: false` is required so the turn markers stay visible.
                        if DGLogger.contentDumpsEnabled {
                            // Explicit `String` annotations — see the GRDB `SQL` note at the
                            // matching dump in CognitiveGeneratorProtocol.swift.
                            let renderedTitle: String = "final chat-template output — \(promptTokens.count) tokens, \(toolCount) tool schema(s)"
                            let renderedBody: String = context.tokenizer.decode(tokenIds: promptTokens, skipSpecialTokens: false)
                            logger.dumpBlock("[PROMPT-RENDERED]", title: renderedTitle, body: renderedBody)
                        }

                        // B. Configure Generation
                        let parameters = GenerateParameters(
                            maxTokens: maxTokens,
                            temperature: temperature,
                            topP: topP,
                            repetitionPenalty: repetitionPenalty,
                            repetitionContextSize: repetitionContextSize
                        )

                        // Without a cache slot: spells out `generate` inside to keep the task handle, so an early stop can cancel decoding.
                        guard let slot = wrappedSlot.value else {
                            let input = LMInput(tokens: MLXArray(promptTokens))
                            let iterator = try TokenIterator(
                                input: input, model: context.model, cache: nil,
                                parameters: parameters)
                            let (stream, task) = generateTask(
                                promptTokenCount: input.text.tokens.size,
                                modelConfiguration: context.configuration,
                                tokenizer: context.tokenizer,
                                iterator: iterator,
                                toolCallPolicy: parameters.toolCallPolicy)
                            return (stream, task, 0)
                        }

                        // With a cache slot: feeds only uncached tokens, keeping the task handle so the cache is rewound after the task ends.
                        let preparation = try MLXPromptCache.prepare(
                            slot: slot,
                            promptTokens: promptTokens,
                            model: context.model,
                            parameters: parameters,
                            minimumSuffix: MLXPromptCache.minimumSuffix(
                                repetitionPenalty: repetitionPenalty,
                                repetitionContextSize: repetitionContextSize)
                        )
                        MLXPromptCache.log(preparation, key: slot.key, tokenizer: context.tokenizer)
                        let iterator = try TokenIterator(
                            input: LMInput(tokens: MLXArray(preparation.inputTokens)),
                            model: context.model, cache: slot.cache,
                            parameters: parameters)
                        let (stream, task) = generateTask(
                            promptTokenCount: preparation.inputTokens.count,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator,
                            toolCallPolicy: parameters.toolCallPolicy)
                        return (stream, task, preparation.plan.reusedTokens)
                    }
                    let (stream, generationTask, reusedTokens) = generation
                    #if DEBUG
                    self.promptCacheReuseForTesting.append(reusedTokens)
                    #endif

                    await self.consumeGenerationStream(stream, into: continuation, stopSequences: stopSequences, reportsDiscardedToolCalls: tools?.isEmpty == false, reusedPromptTokens: reusedTokens, onUsage: onUsage)
                    // The consumer may stop early; unread streams keep decoding, so cancel the task and wait before settling the cache.
                    generationTask.cancel()
                    await generationTask.value
                    generationSucceeded = true
                    }
                    continuation.finish()

                } catch {
                    logger.error("MLX Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
                
                // 2. Inference is complete (success or failure). Start the idle timer.
                self.startIdleTimer()
            }

            // Mirrors the 14 existing `onTermination` sites in this codebase.
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }
    
    // MARK: - Shared Generation Consumer

    /// Consumes an MLX generation stream into `continuation` with stop sequences and a `StreamingCircuitBreaker`.
    /// Forwards native `.toolCall` events in the app's envelope and rejected calls as text; does not finish the continuation.
    /// Shared by `streamChat` and `streamVisionChat`; internal so tests can drive it.
    func consumeGenerationStream(
        _ stream: AsyncStream<Generation>,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        stopSequences: [String],
        // True only where the consumer is the agent parse pipeline (tools were offered). Bot,
        // synthesis and planning calls offer none and must never receive the marker as text.
        reportsDiscardedToolCalls: Bool = false,
        // Prompt tokens served from the KV cache instead of being fed. The framework's counts
        // cover only what was FED, so usage and the prefill log add these back.
        reusedPromptTokens: Int = 0,
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil
    ) async {
        // --- Safety Layer 1: Stop Sequence Detection ---
        let maxStopLen = stopSequences.map(\.count).max() ?? 0
        var trailingWindow = ""
        var stopDetected = false

        // --- Safety Layer 2: Streaming Circuit Breaker ---
        var circuitBreaker = StreamingCircuitBreaker()
        /// Set when a repeated tool call stopped generation, for the post-loop logs.
        var repeatedCallStop: String?

        var chunkCount = 0
        // Counted so an empty result can be explained rather than merely reported.
        var yieldedChars = 0
        var toolCallCount = 0
        var rejectedCallCount = 0
        // Counted by event kind: `chunkCount` includes the completion event, so it cannot distinguish empty text from no output.
        var textChunkCount = 0
        var infoEventCount = 0
        // Keeps the completion event: its token counts distinguish an empty model output from one the framework discarded.
        var lastInfo: GenerateCompletionInfo?

        for await generation in stream {
            // Consumer-side stop: the evaluator checks cancellation only between token batches, so release the container here.
            if Task.isCancelled {
                logger.notice("[MLX-LOAD] Generation cancelled by consumer after \(chunkCount) chunk(s) — releasing the container instead of decoding to EOS.")
                break
            }
            chunkCount += 1

            switch generation {
            case .chunk(let text):
                textChunkCount += 1

                // Circuit breaker: feed every chunk regardless of stop sequence mode
                let breakerStatus = circuitBreaker.feed(text)
                if case .tripped(let reason) = breakerStatus {
                    logger.warning("⚡ Generation terminated by circuit breaker: \(reason)")
                    stopDetected = true
                    break
                }

                // Stop sequence check
                if !stopSequences.isEmpty {
                    trailingWindow += text

                    if let matchedStop = stopSequences.first(where: { trailingWindow.contains($0) }) {
                        if let range = trailingWindow.range(of: matchedStop) {
                            let beforeStop = String(trailingWindow[trailingWindow.startIndex..<range.lowerBound])
                            if !beforeStop.isEmpty {
                                continuation.yield(beforeStop)
                                yieldedChars += beforeStop.count
                            }
                        }
                        logger.info("Stop sequence detected: \(matchedStop) — terminating generation")
                        stopDetected = true
                        break
                    }

                    // Yield text that can't possibly be part of a stop sequence
                    if trailingWindow.count > maxStopLen {
                        let safeCount = trailingWindow.count - maxStopLen
                        let safeIndex = trailingWindow.index(trailingWindow.startIndex, offsetBy: safeCount)
                        let safeText = String(trailingWindow[trailingWindow.startIndex..<safeIndex])
                        continuation.yield(safeText)
                        yieldedChars += safeText.count
                        trailingWindow = String(trailingWindow[safeIndex...])
                    }
                } else {
                    continuation.yield(text)
                    yieldedChars += text.count
                }

            case .toolCall(let toolCall):
                if !trailingWindow.isEmpty && !stopSequences.isEmpty {
                    continuation.yield(trailingWindow)
                    yieldedChars += trailingWindow.count
                    trailingWindow = ""
                }

                // The framework already decoded this call; it is forwarded in `FrameworkToolCallEnvelope` for `CognitiveParsePipeline`.
                let argsDict: [String: Any] = toolCall.function.arguments.mapValues { $0.anyValue }
                if let envelope = FrameworkToolCallEnvelope.encode(name: toolCall.function.name, arguments: argsDict) {
                    // The envelope is sorted-keys JSON, so identical calls are identical strings.
                    if case .tripped(let reason) = circuitBreaker.feedToolCall(envelope, name: toolCall.function.name) {
                        repeatedCallStop = reason
                        stopDetected = true
                        break
                    }
                    continuation.yield(envelope)
                    yieldedChars += envelope.count
                    toolCallCount += 1
                } else {
                    logger.error("[MLX-TOOLCALL] The framework decoded a call to '\(toolCall.function.name)' whose arguments are not JSON-serializable. CONSEQUENCE: the call is dropped — the model is not told, and the turn continues with the remaining output.")
                }

            case .rejectedToolCall(let rejection):
                if !trailingWindow.isEmpty && !stopSequences.isEmpty {
                    continuation.yield(trailingWindow)
                    yieldedChars += trailingWindow.count
                    trailingWindow = ""
                }

                // Forwards a rejected call's raw text as ordinary output so the app's parsers can repair it or report what was wrong.
                // The preview is bounded (head and tail) and the raw text is not logged, since it can carry sensitive argument values.
                let raw = rejection.rawTextPreview
                let shape = "reason=\(rejection.reason.rawValue), format=\(rejection.format), "
                    + "tool=\(rejection.toolName ?? "unrecovered"), \(rejection.rawTextByteCount) bytes"
                    + (rejection.isPreviewTruncated ? " (preview truncated)" : "")
                if raw.isEmpty {
                    logger.error("[MLX-TOOLCALL] The framework rejected a tool call with no raw text (\(shape)). CONSEQUENCE: nothing to hand the parse pipeline; if no other output arrives this turn it is reported as a discarded call.")
                } else {
                    // A broken call repeated in a loop is still a loop.
                    if case .tripped(let reason) = circuitBreaker.feedToolCall(raw, name: rejection.toolName ?? "an unparseable call") {
                        repeatedCallStop = reason
                        stopDetected = true
                        break
                    }
                    continuation.yield(raw)
                    yieldedChars += raw.count
                    rejectedCallCount += 1
                    logger.warning("[MLX-TOOLCALL] The framework rejected a tool call (\(shape)). CONSEQUENCE: its raw text goes to the app's parse pipeline, which repairs it or tells the model what was wrong.")
                }
            case .info(let info):
                infoEventCount += 1
                lastInfo = info
                // Terminal completion event: exact token counts; early stops skip it and callers fall back to the estimate.
                onUsage?(TokenUsage(inputTokens: info.promptTokenCount + reusedPromptTokens, outputTokens: info.generationTokenCount, isEstimated: false))
            }

            if stopDetected { break }
        }

        // Post-loop cleanup
        if let repeatedCallStop {
            // The model is not told: the withheld copies would have been collapsed by the executor anyway.
            logger.warning("[MLX-GEN] Generation stopped: \(repeatedCallStop). CONSEQUENCE: that copy and everything after it are dropped; the \(toolCallCount) call(s) and \(rejectedCallCount) rejected call(s) already forwarded go to the parse pipeline as usual, and the turn is not told it was cut. Token counts for this call are estimated (the framework's completion event never arrives after an early stop).")
        } else if circuitBreaker.hasTripped {
            logger.info("Circuit breaker terminated generation after \(circuitBreaker.accumulatedText.count) chars")
        } else if !stopDetected && !trailingWindow.isEmpty {
            continuation.yield(trailingWindow)
            yieldedChars += trailingWindow.count
        }

        // Makes an empty response explicable: reports framework-reported token counts, since yielded chars alone cannot say why.
        let generated = lastInfo?.generationTokenCount
        let stopReason = lastInfo.map { String(describing: $0.stopReason) } ?? "unknown"
        let timing = lastInfo.map {
            String(format: "prefill %.2fs/%d tok%@, decode %.2fs/%d tok",
                   $0.promptTime, $0.promptTokenCount,
                   reusedPromptTokens > 0 ? " (+\(reusedPromptTokens) cached)" : "",
                   $0.generateTime, $0.generationTokenCount)
        } ?? "timings unavailable"

        if yieldedChars == 0 {
            // Branches on the framework's `generationTokenCount`, not on event counts, to tell an empty output from a swallowed one.
            // `ToolCallProcessor` buffers from `<tool_call>` onward and drops the text if the call fails to decode, logging nothing.
            let verdict: String
            switch generated {
            case .none:
                verdict = "UNKNOWN — no completion event arrived, so the framework's token counts "
                        + "are unavailable. The loop exited early (cancellation, stop sequence, or "
                        + "circuit breaker); check those three before anything else"
            case .some(0):
                verdict = "the model generated NOTHING (immediate EOS — 0 tokens decoded, confirmed "
                        + "by the framework, not inferred). Look at sampling config (a repetition "
                        + "penalty applied over a small repetition-context window can make the "
                        + "end-of-turn token the argmax at low temperature) or the chat template's "
                        + "tool-result turn. NOT the parser"
            case .some(let n):
                verdict = "the model generated \(n) token(s) and NONE of them reached the caller — "
                        + "output was produced and then DISCARDED downstream, so sampling config is "
                        + "NOT the cause. The framework reported no rejected tool call (rejected=\(rejectedCallCount)), "
                        + "so check the stop sequences and the circuit breaker first, then "
                        + "MLXLMCommon's ToolCallProcessor (before 3.32 it dropped unparseable calls "
                        + "without a trace; a regression there would look exactly like this)"
            }
            let reportedAsDiscardedCall = reportsDiscardedToolCalls && (generated ?? 0) > 0 && !stopDetected && !circuitBreaker.hasTripped
            if reportedAsDiscardedCall, let n = generated {
                continuation.yield(FrameworkToolCallEnvelope.discardedMarker(generatedTokens: n))
                logger.warning("[MLX-TOOLCALL] \(n) generated token(s) were discarded by the framework's tool-call parser. CONSEQUENCE: reported to the parse pipeline as a call that failed to decode, so the model is told and retries — not a blind retry of the same prompt, which reproduced the discard 3 of 3 times (2026-10-06).")
            }
            logger.error("[MLX-GEN] Generation produced NO output — generatedTokens=\(generated.map(String.init) ?? "unknown") stopReason=\(stopReason), \(timing) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount) rejectedCalls=\(rejectedCallCount) infoEvents=\(infoEventCount) (total events \(chunkCount)), stopSequenceHit=\(stopDetected), circuitBreaker=\(circuitBreaker.hasTripped), trailingWindow=\(trailingWindow.count) chars. DIAGNOSIS: \(verdict). CONSEQUENCE: \(reportedAsDiscardedCall ? "reported to the parse pipeline as a call that failed to decode (see [MLX-TOOLCALL])" : "the caller throws GenerationError.emptyResponse, which aborts the run after 3 attempts without charging the parse budget").")
        } else if infoEventCount == 0, stopDetected {
            // Stopped on purpose (stop sequence, text loop or repeated tool call), so no completion
            // event is expected. Not the cancellation/fault case below.
            logger.notice("[MLX-GEN] Generation stopped early by \(repeatedCallStop != nil ? "the repeated-call guard" : circuitBreaker.hasTripped ? "the text-repetition breaker" : "a stop sequence") — \(yieldedChars) chars yielded | textChunks=\(textChunkCount) toolCalls=\(toolCallCount) rejectedCalls=\(rejectedCallCount). CONSEQUENCE: token counts and timings for this call are unavailable, so usage is estimated.")
        } else if infoEventCount == 0 {
            // Text was yielded but no completion event arrived: the consumer was cancelled mid-generation and the text is partial.
            logger.notice("[MLX-GEN] Generation ended WITHOUT a completion event — \(yieldedChars) chars yielded then the stream stopped (Task.isCancelled=\(Task.isCancelled)) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount), stopSequenceHit=\(stopDetected). CONSEQUENCE: token counts and timings are unavailable and the yielded text is PARTIAL — cancelled mid-generation (Stop / node timeout / per-node skip) if isCancelled is true, otherwise a framework fault worth reporting.")
        } else {
            logger.debug("[MLX-GEN] Generation complete — \(yieldedChars) chars yielded, generatedTokens=\(generated.map(String.init) ?? "unknown") stopReason=\(stopReason), \(timing) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount) rejectedCalls=\(rejectedCallCount) infoEvents=\(infoEventCount), stopSequenceHit=\(stopDetected).")
        }
    }

    // MARK: - Vision Inference

    /// Streams a vision chat response through the model's `UserInputProcessor`, attaching `imageData` to the last user turn.
    /// Uses the same container and safety consumer as `streamChat`; the processor owns templating.
    /// `expectedModelDirectory` behaves as in `streamChat`.
    func streamVisionChat(
        expectedModelDirectory: URL? = nil,
        messages: [[String: String]],
        imageData: [Data],
        maxTokens: Int = 2048,
        temperature: Float = 0.6,
        topP: Float = 1.0,
        repetitionPenalty: Float? = nil,
        repetitionContextSize: Int = 20,
        stopSequences: [String] = [],
        // Exact provider token counts (terminal completion event) — see `streamChat`.
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil
    ) -> AsyncThrowingStream<String, Error> {
        cancelIdleTimer()

        return AsyncThrowingStream { continuation in
            // The producer handle is captured and cancelled on termination so Stop halts decoding and releases `activeGenerations`.
            let producer = Task {
                activeGenerations += 1
                defer { activeGenerations -= 1 }

                // Lazy reload: an idle-timer unload between iterations recovers inline, identity-checked by `container(expecting:)`.
                let container: ModelContainer
                do {
                    container = try await self.container(expecting: expectedModelDirectory)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                logger.info("[VISION] streamVisionChat generating: \(imageData.count) image(s), \(messages.count) message(s), maxTokens=\(maxTokens), stops=\(stopSequences.count), repPenalty=\(repetitionPenalty.map { String($0) } ?? "none")")

                do {
                    let wrappedMessages = UnsafeSendable(messages)
                    let wrappedData = UnsafeSendable(imageData)

                    // Converts MLX C++ fatal errors into a Swift throw via a task-local `withError` handler.
                    // Must wrap both the perform and the consume, since the generation task inherits the handler.
                    try await withError {
                    let (stream, generationTask) = try await container.perform { context -> (AsyncStream<Generation>, Task<Void, Never>) in
                        // Decodes raw bytes to a CGImage-backed `UserInput.Image` so the VLM gets a concrete pixel extent.
                        // An undecodable slot is logged as dropped.
                        let images: [UserInput.Image] = wrappedData.value.enumerated().compactMap { (idx, data) in
                            Self.decodeVisionImage(data, index: idx, logger: self.logger)
                        }
                        if images.count != wrappedData.value.count {
                            self.logger.error("[VISION] decoded \(images.count)/\(wrappedData.value.count) image(s); \(wrappedData.value.count - images.count) DROPPED — prompt placeholders will outnumber vision features downstream")
                        }

                        // Rebuilds the chat with the images on the final user turn, or on the last message when there is no user turn.
                        let msgs = wrappedMessages.value
                        let userIdx = msgs.lastIndex(where: { $0["role"] == "user" })
                        if userIdx == nil, !images.isEmpty {
                            self.logger.warning("[VISION] no user turn in a \(msgs.count)-message array — attaching \(images.count) image(s) to the last turn so they aren't silently dropped")
                        }
                        let targetIdx = userIdx ?? (msgs.isEmpty ? -1 : msgs.count - 1)
                        var chat: [Chat.Message] = []
                        for (i, m) in msgs.enumerated() {
                            let content = m["content"] ?? ""
                            let imgs = (i == targetIdx) ? images : []
                            switch m["role"] {
                            case "system":    chat.append(.system(content, images: imgs))
                            case "assistant": chat.append(.assistant(content, images: imgs))
                            default:          chat.append(.user(content, images: imgs))
                            }
                        }

                        let userInput = UserInput(chat: chat)

                        // Logs memory and shape around the crash-prone processor hop so a hard crash can be localized.
                        let activeBefore = MLX.Memory.activeMemory
                        let cacheBefore = MLX.Memory.cacheMemory
                        self.logger.info("[VISION] prepare PRE — images=\(images.count), MLX active=\(ByteCountFormatter.string(fromByteCount: Int64(activeBefore), countStyle: .memory)), cache=\(ByteCountFormatter.string(fromByteCount: Int64(cacheBefore), countStyle: .memory))")
                        let lmInput = try await context.processor.prepare(input: userInput)
                        let pixShape = lmInput.image?.pixels.shape ?? []
                        let promptLen = lmInput.text.tokens.shape.last ?? 0
                        let activeAfter = MLX.Memory.activeMemory
                        self.logger.info("[VISION] prepare POST — promptTokens=\(promptLen), visionFeatures(pixels)=\(pixShape), MLX active=\(ByteCountFormatter.string(fromByteCount: Int64(activeAfter), countStyle: .memory)) (Δ=\(ByteCountFormatter.string(fromByteCount: Int64(activeAfter) - Int64(activeBefore), countStyle: .memory)))")

                        // Drops the library repetition penalty on the vision path: its ring buffer mis-sizes on 2-D token arrays and crashes.
                        // Runaway repetition is still bounded by the circuit breaker and stop sequences in `consumeGenerationStream`.
                        if let rp = repetitionPenalty, rp != 0 {
                            self.logger.warning("[VISION] dropping repetitionPenalty=\(rp) on the MLX vision path — mlx-swift-lm 3.31.3 RepetitionContext broadcast-crashes on 2-D VLM prompts; circuit breaker + stop sequences still bound repetition")
                        }
                        let parameters = GenerateParameters(
                            maxTokens: maxTokens,
                            temperature: temperature,
                            topP: topP,
                            repetitionPenalty: nil,
                            repetitionContextSize: repetitionContextSize
                        )

                        self.logger.info("[VISION] prepare complete — starting first forward/eval (repetitionPenalty disabled on vision path); a crash before any token output localizes to the vision forward pass, not prepare")
                        // `generate` spelled out to keep the task handle; see `streamChat`.
                        let iterator = try TokenIterator(
                            input: lmInput, model: context.model, cache: nil,
                            parameters: parameters)
                        return generateTask(
                            promptTokenCount: lmInput.text.tokens.size,
                            modelConfiguration: context.configuration,
                            tokenizer: context.tokenizer,
                            iterator: iterator,
                            toolCallPolicy: parameters.toolCallPolicy)
                    }

                    await self.consumeGenerationStream(stream, into: continuation, stopSequences: stopSequences, onUsage: onUsage)
                    // An early stop must stop the generation too, not just the reading.
                    generationTask.cancel()
                    await generationTask.value
                    }
                    continuation.finish()
                } catch {
                    logger.error("MLX Vision Generation Error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }

                self.startIdleTimer()
            }

            // Mirrors the 14 existing `onTermination` sites in this codebase.
            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    // MARK: - Vision Image Decoding

    /// Shared CoreImage context reused across image decodes (allocating a
    /// `CIContext` per image is expensive). `nonisolated` so the `@Sendable`
    /// `container.perform` closure can reach it without hopping the actor.
    private nonisolated static let visionDecodeContext = CIContext(options: nil)

    /// Decodes raw image bytes into a `UserInput.Image` for the VLM processor, rendered through a CGImage.
    /// Falls back to `CIImage(data:)` if no CGImage can be made; returns `nil` (and logs) when the bytes cannot be decoded.
    private nonisolated static func decodeVisionImage(
        _ data: Data, index: Int, logger: DGLogger
    ) -> UserInput.Image? {
        guard let raw = CIImage(data: data) else {
            logger.error("[VISION] image[\(index)] UNDECODABLE (\(data.count) bytes) — DROPPED; the model will receive one fewer image than the prompt has placeholders")
            return nil
        }
        let extent = raw.extent
        let cs = (raw.colorSpace?.name as String?) ?? "unknown"
        guard !extent.isInfinite, !extent.isNull, extent.width >= 1, extent.height >= 1 else {
            logger.warning("[VISION] image[\(index)] non-concrete extent \(extent) — retaining bare CIImage; asMLXArray may mis-shape the image tensor")
            return .ciImage(raw)
        }
        if let cg = visionDecodeContext.createCGImage(raw, from: extent) {
            logger.info("[VISION] image[\(index)] \(Int(extent.width))x\(Int(extent.height)) cs=\(cs) bytes=\(data.count) → CGImage-backed")
            return .ciImage(CIImage(cgImage: cg))
        }
        logger.warning("[VISION] image[\(index)] createCGImage failed (extent \(extent)) — falling back to bare CIImage(data:)")
        return .ciImage(raw)
    }

    // MARK: - Sendable Bridge

    // MARK: - Fallback Chat Templates (Two-Layer Strategy)

    /// Resolves the fallback Jinja template from the stored `ChatTemplateSource`.
    /// `.extracted` returns the model author's template, `.familyFallback` a template for the token family,
    /// and `.embedded` should not reach here but falls back to ChatML.
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
        
        logger.debug("Starting idle timer. Model will unload in \(self.idleTimeoutDescription) if inactive.")
        
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
    private func handleIdleTimeout() async {
        // Never unload under an in-flight generation; the timer can fire during an actor-reentrancy window mid-stream.
        guard activeGenerations == 0 else {
            logger.notice("Idle timeout while \(self.activeGenerations) generation(s) in flight — keeping model, re-arming timer.")
            startIdleTimer()
            return
        }

        // A parked HITL run wants the unload to free memory; the check only selects the log message.
        if await ExecutionSuspensionService.shared.hasPendingSuspensions() {
            logger.notice("MLX idle timeout during a parked HITL request — releasing memory; the model lazy-reloads when the run resumes.")
        } else {
            logger.notice("MLX Service has been idle for \(self.idleTimeoutDescription). Releasing memory.")
        }
        _ = unloadModel()
    }
}
