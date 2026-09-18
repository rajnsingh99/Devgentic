// SPDX-License-Identifier: AGPL-3.0-only
// Copyright © 2025-2026 Raj Singh
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

    /// Resolves the container for a specific model, loading it if necessary.
    ///
    /// ⚠️ The identity check and the container capture MUST stay in the same synchronous
    /// region — no `await` between them. This actor is reentrant across every suspension, so
    /// a check-then-await-then-use would let a concurrent `loadModel` swap `modelContainer`
    /// after the check passed. Capturing the container into a local first means the caller
    /// holds a strong reference to the model it validated, even if the actor's slot changes
    /// underneath it a moment later.
    ///
    /// Why this exists: `streamChat` took no model identifier, and `lastModelDirectory` is a
    /// single global slot holding whatever model ANY caller loaded most recently.
    /// `WorkflowExecutor` runs profile nodes in parallel — branch A (model X) pausing between
    /// ReAct iterations while branch B loaded model Y meant A's lazy reload restored Y and
    /// **answered from the classifier's model**, logging only "♻️ Reloading model from: Y".
    /// The A14 identity rule, as a pure function so it is directly testable.
    ///
    /// A request may only be served when a container is loaded AND the directory it was loaded
    /// from is the one the request expects. ⚠️ `hasContainer` is a separate input on purpose:
    /// `loadModel` nulls the container BEFORE loading, so "the right path with no container" is
    /// a real state and it must NOT be treated as resident. Paths are standardized because the
    /// two sides arrive from different places — a profile's stored URL and the service's own
    /// record — and `/a/b` vs `/a/b/` vs `/a/c/../b` are the same model.
    nonisolated static func isResident(expected: URL, resident: URL?, hasContainer: Bool) -> Bool {
        guard hasContainer, let resident else { return false }
        return samePath(resident, expected)
    }

    /// Compare two model directories. See `URL.sameLocationLexically` for the rule and why
    /// `URL` equality is wrong for this.
    ///
    /// Deliberately the LEXICAL variant: this is on the generation hot path
    /// (`container(expecting:)` runs per request) and every model directory is derived from the
    /// service's own `modelsDirectory`, so there is no symlink divergence to resolve.
    nonisolated static func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.sameLocationLexically(as: rhs)
    }

    private func container(expecting directory: URL?) async throws -> ModelContainer {
        guard let directory else {
            // No identity supplied (legacy caller). Preserve the old lazy-reload behaviour,
            // but say so — an unidentified generation is exactly the case that could be
            // served by the wrong model.
            if modelContainer == nil, lastModelDirectory != nil {
                logger.warning("[MLX-LOAD] Lazy reload with NO expected model identity — restoring '\(self.lastModelDirectory?.lastPathComponent ?? "?")', whichever model that happens to be. CONSEQUENCE: if another caller loaded a different model, this generation is answered by it.")
                _ = await reloadCurrentModel()
            }
            guard let container = modelContainer else { throw ServiceError.noModelLoaded }
            return container
        }

        let target = directory.standardizedFileURL

        // Up to two attempts. ⚠️ A single attempt conflated two very different situations:
        // "another model is resident" (a real wrong-model hazard, must refuse) and "the slot
        // was emptied underneath us" (a transient interleave). `loadModel` calls
        // `performUnload()` BEFORE loading, so a concurrent load for a different model nulls
        // `modelContainer` in the window between our load completing and the check below —
        // and we threw `modelIdentityMismatch(expected: X, actual: <none>)` for a model that
        // had just loaded perfectly. `WorkflowExecutor` runs profile nodes in parallel, so
        // that interleave is routine there, and a hard node failure is the worst possible
        // response to it. Retrying once lets the transient case settle; sustained contention
        // still refuses, which is correct.
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

        // ⚠️ No suspension permitted between here and the return.
        guard let container = modelContainer,
              Self.isResident(expected: directory, resident: currentModelDirectory,
                              hasContainer: true) else {
            let actual = currentModelDirectory?.lastPathComponent ?? "<none>"
            logger.error("[MLX-LOAD] REFUSING to generate: expected '\(directory.lastPathComponent)' but '\(actual)' is resident after a load attempt — a concurrent load won the race. CONSEQUENCE: this request throws instead of returning an answer produced by the wrong model.")
            throw ServiceError.modelIdentityMismatch(expected: directory.lastPathComponent, actual: actual)
        }
        return container
    }

    /// Whether `directory` is the model currently resident in memory, or the one a lazy
    /// `reloadCurrentModel()` would restore. `MLXModelService.deleteModel` consults this
    /// before removing files: deleting a resident model leaves in-flight generations reading
    /// a path that no longer exists, and deleting the `lastModelDirectory` target makes the
    /// idle-timer recovery resurrect a deleted path and fail with a raw framework error.
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

    /// The duration of inactivity before the model is automatically unloaded to save RAM.
    /// NOTE: this is 2 minutes — earlier comments/log strings claimed 5 minutes while
    /// the constant said 2; the text now derives from the constant so it can't lie.
    private let idleTimeoutNanoseconds: UInt64 = 2 * 60 * 1_000_000_000

    /// Human-readable form of the idle timeout for log messages.
    private var idleTimeoutDescription: String {
        "\(idleTimeoutNanoseconds / 60_000_000_000) minute(s)"
    }

    /// Count of in-flight generations (stream tasks between start and finish).
    /// The idle timer can fire during actor-reentrancy windows mid-stream (the
    /// lost-cancel race seen in run logs: "idle … Releasing memory" printed, then
    /// "Idle timer cancelled" from the incoming request, unload proceeded anyway).
    /// Both `handleIdleTimeout` and `unloadModel` refuse while this is non-zero.
    private var activeGenerations = 0

    /// In-flight model load, published so concurrent `loadModel` calls (actor
    /// reentrancy across the container-load await) coalesce onto one load
    /// instead of double-loading the full model.
    private var loadInFlight: Task<Void, Error>?
    
    private init() {}
    
    // MARK: - Lifecycle Management
    
    /// Loads a model from the specified local directory into memory.
    /// - Parameter directory: The URL pointing to the folder containing `config.json` and `.safetensors`.
    func loadModel(from directory: URL) async throws {
        // Cancel any pending unload timer since we are about to use the model (or load a new one)
        cancelIdleTimer()

        // Coalesce concurrent loads: this actor is reentrant across the awaits
        // below, so two streams lazy-reloading simultaneously would otherwise
        // both observe `modelContainer == nil` and double-load the full model
        // (transient 2× RAM + doubled latency). Await any in-flight load first,
        // then re-check.
        if let inflight = loadInFlight {
            _ = try? await inflight.value
        }

        // Optimization: Don't reload if it's already the active model
        if let current = currentModelDirectory, current == directory, modelContainer != nil {
            logger.info("Model already loaded: \(directory.lastPathComponent)")
            return
        }

        // Pre-load headroom, logged BEFORE the allocation. Per the standing directive this
        // is purely descriptive — nothing here refuses a load; the user's configured model
        // always loads. But the only prior memory line was a `.debug` "Post-Load" pair
        // emitted AFTER the allocation, so a field report of "the app hangs my Mac" had no
        // evidence at all. The agent model and the Intelligence Core hold independent
        // containers with independent idle timers and no shared budget, so both can be
        // resident at once during a single turn.
        let onDiskBytes = MLXModelService.directorySize(at: directory)
        let hardware = SystemHardwareProfiler.shared.profile
        let fit = ModelFitAdvisor.assess(
            metadata: nil,
            diskSizeBytes: onDiskBytes > 0 ? onDiskBytes : nil,
            modelName: directory.lastPathComponent
        )
        logger.notice("[MLX-LOAD] Loading '\(directory.lastPathComponent)' — on disk \(ByteCountFormatter.string(fromByteCount: onDiskBytes, countStyle: .file)), est. runtime \(fit.formattedEstimatedRAM), budget \(hardware.formattedEffectiveBudget), verdict \(fit.verdict.rawValue). \(fit.verdict == .risky || fit.verdict == .incompatible ? "CONSEQUENCE: this exceeds the safe threshold — expect memory pressure and swapping, especially if an Intelligence Core model is also resident." : "")")

        logger.notice("Loading MLX model from: \(directory.path)")

        // 1. Clean up previous model to free RAM. FORCED variant: the public
        // unloadModel() refuses while a generation is in flight, but a container
        // SWAP here is safe — an in-flight generation holds its own container
        // reference (stays alive as active memory), and clearing the recycle
        // cache doesn't touch buffers in use. Using the guarded version logged a
        // spurious "Refusing model unload" on every lazy reload and skipped the
        // cache clear on mid-generation model switches (multi-GB retention).
        _ = performUnload()
        
        // Publish the in-flight load so concurrent callers await it instead of
        // starting a duplicate load (see coalescing check above).
        let load = Task { () throws -> Void in
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

            self.logger.notice("Successfully loaded MLX model: \(directory.lastPathComponent)")
            self.logMemoryStats(label: "Post-Load")
        }
        loadInFlight = load
        // ⚠️ Clear only our OWN handle. Both this caller and one coalesced behind it resume
        // when the previous load finishes; if the other runs first it installs its own
        // `loadInFlight` before we get here, and an unconditional nil then wiped a live
        // load's handle — the next caller saw nil, skipped the coalescing check, and started
        // a duplicate full-model load. That is exactly the transient 2× RAM this handle
        // exists to prevent. (`Task` is a struct but `Hashable` on task identity, so `==`.)
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
    /// Refuses while a generation is in flight — external callers (idle timer,
    /// conversation switch, settings) must not yank the container mid-stream.
    /// Internal container swaps during `loadModel` use `performUnload()` directly.
    /// - Returns: A dictionary containing memory stats (freed bytes, remaining active, remaining cache).
    @discardableResult
    func unloadModel() -> [String: Int] {
        guard activeGenerations == 0 else {
            logger.warning("[MLX-LOAD] Refusing model unload — \(self.activeGenerations) generation(s) still in flight for \(self.currentModelDirectory?.lastPathComponent ?? "<none>"). CONSEQUENCE: the model stays resident until they finish or the 2-minute idle timer fires; a cancelled consumer should have cancelled its producer, so a persistent count here means a stream leaked.")
            return [:]
        }
        return performUnload()
    }

    /// The actual unload, no in-flight guard. Safe during a container swap: an
    /// in-flight generation holds its own container reference (kept alive as
    /// active memory), and clearing the recycle cache never touches buffers in use.
    @discardableResult
    private func performUnload() -> [String: Int] {
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
    /// - Parameter expectedModelDirectory: the model this request was configured for. When
    ///   supplied, the generation is served by THAT model or it throws — it is never answered
    ///   by whichever model happens to be resident. Nil preserves the legacy behaviour and
    ///   logs a warning; see `container(expecting:)`.
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

        return AsyncThrowingStream { continuation in
            // ⚠️ The producer handle MUST be captured and cancelled on termination.
            // Without this, pressing Stop unwound the consumer while the model kept
            // decoding on the GPU until EOS / a stop sequence / maxTokens — discarding
            // every token, holding `activeGenerations > 0` so `unloadModel()` refused,
            // and making the user's NEXT message decode concurrently with the orphan on
            // the same GPU at roughly half token rate. The vendored evaluator already
            // breaks on `Task.isCancelled`; nothing was ever cancelling it.
            let producer = Task {
                activeGenerations += 1
                defer { activeGenerations -= 1 }

                // Lazy reload: an idle-timer unload between iterations (HITL park,
                // long tool run) recovers inline instead of failing the request into
                // the retry classifier — no wasted generation attempt, no error card.
                // Now identity-checked: see `container(expecting:)`.
                let container: ModelContainer
                do {
                    container = try await self.container(expecting: expectedModelDirectory)
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                do {
                    // Use container.perform to safely access the ModelContext (which contains model, processor, tokenizer).
                    let wrappedMessages = UnsafeSendable(messages)
                    // ⚠️ Bridged ON THE ACTOR, before the perform closure, because the stability
                    // cache is actor state: equal content must hand the template the SAME
                    // dictionary instances every render, or the `<tools>` bytes shuffle per call
                    // (Swift dictionaries iterate in per-INSTANCE order — see BridgedToolsStore).
                    let wrappedTools = UnsafeSendable(tools.map { self.bridgedToolsStore.stableInstances(for: $0) })

                    // Convert MLX C++ fatal errors (e.g. a VLM shape/broadcast mismatch)
                    // into a Swift throw instead of `fatalError` crashing the whole app.
                    // `withError` installs a TASK-LOCAL handler; the internal generation
                    // `Task` that `MLXLMCommon.generate` spawns is created inside this scope
                    // and inherits it, so an error raised in the forward pass is recorded and
                    // rethrown here rather than aborting the process. MUST wrap BOTH the
                    // perform (where the Task is created) and the consume (where it runs).
                    try await withError {
                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // A. Apply Chat Template & Tokenize
                        //
                        // mlx-swift-lm 3.x removed `hasChatTemplate` and the
                        // `applyChatTemplate(chatTemplate: .literal(...))` overload from its
                        // `Tokenizer` protocol. Primary path uses the embedded template;
                        // fallback drops to the bridge's upstream swift-transformers tokenizer
                        // which still has the richer API needed for literal-template override.
                        let sendableMessages = wrappedMessages.value.map { $0 as [String: any Sendable] }
                        let mlxTools: [[String: any Sendable]]? = wrappedTools.value
                        let toolCount = mlxTools?.count ?? 0
                        if toolCount > 0 {
                            logger.info("🔧 [Tools] Injecting \(toolCount) tool schema(s) into chat template")
                        }

                        let promptTokens: [Int]

                        // ⚠️ KNOWN-CORRUPT TEMPLATE OVERRIDE — checked BEFORE the embedded render,
                        // because the embedded path reads the template straight out of the
                        // tokenizer, where the app cannot rewrite it. When the analyzer's extracted
                        // copy (same bytes, same tokenizer_config.json) carries a corruption the
                        // register can prove and fix, render via the bridge with the REPAIRED
                        // template instead. Healthy templates take the embedded path unchanged —
                        // zero behaviour change unless a repair actually applies.
                        //
                        // Why this exists: Qwen2.5-3B-4bit ships a tool-call example with doubled
                        // braces, and the model dutifully copies it into invalid JSON that the
                        // framework then silently discards (see ChatTemplateRepair.swift).
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
                            // The repair matched but the tokenizer is not the bridge type, so the
                            // literal-template API is unreachable. Proceeding with the corrupt
                            // embedded template is still better than failing the run — but it must
                            // never be silent, because the discard it causes looks like a model
                            // fault downstream.
                            logger.error("[TEMPLATE-REPAIR] Repair matched but tokenizer is \(type(of: context.tokenizer)), not TokenizerBridge — CANNOT apply. CONSEQUENCE: rendering the CORRUPT embedded template; expect the doubled-brace tool-call discard on this model.")
                        }
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
                            // The fallback template is repaired through the same register — an
                            // extracted template reaching this path carries the same bytes the
                            // primary path would have repaired.
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
                        
                        // ⚠️ THE ONLY PLACE THE MODEL'S ACTUAL INPUT EXISTS. Everything logged
                        // upstream is the app's message ARRAY — what we handed to the chat
                        // template. This is what came OUT of it, and the two are not the same
                        // document: the template injects the dialect's entire tool scaffolding
                        // (for Qwen, a `<tools>` block of JSON schemas plus the instructions
                        // telling the model to answer in `<tool_call>` tags), wraps every turn in
                        // `<|im_start|>` / `<|im_end|>`, and appends the generation prompt. None
                        // of that is visible anywhere else, in any log, at any level — yet it is
                        // the majority of the 861 tokens and it is what the model is actually
                        // reading when it decides how to format a tool call.
                        //
                        // `skipSpecialTokens: false` is load-bearing: the turn markers ARE the
                        // structure. Decoding without them would show the text while hiding the
                        // conversation shape, which is the half most likely to be wrong.
                        if DGLogger.contentDumpsEnabled {
                            // Explicit `String` annotations — see the GRDB `SQL` note at the
                            // matching dump in CognitiveGeneratorProtocol.swift.
                            let renderedTitle: String = "final chat-template output — \(promptTokens.count) tokens, \(toolCount) tool schema(s)"
                            let renderedBody: String = context.tokenizer.decode(tokenIds: promptTokens, skipSpecialTokens: false)
                            logger.dumpBlock("[PROMPT-RENDERED]", title: renderedTitle, body: renderedBody)
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
                    
                    await self.consumeGenerationStream(stream, into: continuation, stopSequences: stopSequences, onUsage: onUsage)
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

    /// Consumes an MLX generation stream into `continuation`, applying the two safety
    /// layers a ReAct loop depends on. Shared by `streamChat` and `streamVisionChat`
    /// so an agent gets IDENTICAL protection whether or not its turn carries an image
    /// — previously the vision path had neither, and a small quantized VLM would run a
    /// repetition loop straight to `maxTokens` with no circuit breaker to stop it.
    ///
    ///   Layer 1 — custom stop sequences (multi-token, chunk-boundary safe).
    ///   Layer 2 — `StreamingCircuitBreaker` (kills pathological repetition).
    ///
    /// Also forwards native `.toolCall` events as synthetic JSON. On the vision path
    /// these are rare (tools are prompted as text there), but forwarding them removes
    /// a silent drop rather than swallowing a real tool call.
    ///
    /// Does NOT finish the continuation — the caller owns success/error termination.
    private func consumeGenerationStream(
        _ stream: AsyncStream<Generation>,
        into continuation: AsyncThrowingStream<String, Error>.Continuation,
        stopSequences: [String],
        onUsage: (@Sendable (TokenUsage) -> Void)? = nil
    ) async {
        // --- Safety Layer 1: Stop Sequence Detection ---
        let maxStopLen = stopSequences.map(\.count).max() ?? 0
        var trailingWindow = ""
        var stopDetected = false

        // --- Safety Layer 2: Streaming Circuit Breaker ---
        var circuitBreaker = StreamingCircuitBreaker()

        var chunkCount = 0
        // Counted so an empty result can be explained rather than merely reported.
        var yieldedChars = 0
        var toolCallCount = 0
        // ⚠️ SPLIT BY EVENT KIND. `chunkCount` counts every event the stream yields — text, tool
        // calls AND the terminal `.info` completion — so "1 chunk consumed" could mean an empty
        // text chunk OR just the completion event with no generation at all. Those are different
        // diagnoses (swallowed output vs the model emitting immediate EOS), and the first field
        // report needed exactly that distinction.
        var textChunkCount = 0
        var infoEventCount = 0
        // ⚠️ THE DISCRIMINATOR. Event counts ALONE cannot tell "the model emitted nothing" from
        // "the model emitted plenty and the framework threw it away" — both arrive here as
        // textChunks=0, toolCalls=0, infoEvents=1. The completion event carries the framework's own
        // token counts, which settle it outright, and this method used to read that event for usage
        // and then discard it. Keeping it is what stops the empty-output log from GUESSING.
        var lastInfo: GenerateCompletionInfo?

        for await generation in stream {
            // The vendored evaluator's own `Task.isCancelled` check only fires between
            // token batches; this is the consumer-side stop, so an abandoned generation
            // releases the container promptly instead of running to EOS.
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

                let argsDict: [String: Any] = toolCall.function.arguments.mapValues { $0.anyValue }
                let syntheticStep: [String: Any] = [
                    "content": "Executing tool \(toolCall.function.name)...",
                    "tool_name": toolCall.function.name,
                    "arguments": argsDict
                ]

                // `.sortedKeys` so the synthetic payload is byte-stable across iterations — the
                // scratchpad, the identical-output loop detector, and the log Raw lines all
                // compare these strings, and a shuffled key order makes "identical" calls look
                // different to every one of them.
                if let syntheticData = try? JSONSerialization.data(withJSONObject: syntheticStep, options: [.sortedKeys]),
                   let syntheticString = String(data: syntheticData, encoding: .utf8) {
                    continuation.yield(syntheticString)
                    yieldedChars += syntheticString.count
                    toolCallCount += 1
                }
            case .info(let info):
                infoEventCount += 1
                lastInfo = info
                // Terminal completion event: EXACT prompt/generation token counts from
                // mlx-swift-lm. Surfaced so MLX reports real usage instead of the chars/4
                // estimate. Fires only on natural completion — an early stop-sequence or
                // circuit-breaker exit breaks the loop before this event, and callers then
                // fall back to the estimate (documented at the `onUsage` call sites).
                onUsage?(TokenUsage(inputTokens: info.promptTokenCount, outputTokens: info.generationTokenCount, isEstimated: false))
            }

            if stopDetected { break }
        }

        // Post-loop cleanup
        if circuitBreaker.hasTripped {
            logger.info("Circuit breaker terminated generation after \(circuitBreaker.accumulatedText.count) chars")
        } else if !stopDetected && !trailingWindow.isEmpty {
            continuation.yield(trailingWindow)
            yieldedChars += trailingWindow.count
        }

        // ⚠️ MAKE "EMPTY RESPONSE" EXPLICABLE. The generators throw "Empty response from model" when
        // nothing was yielded, and that error says nothing about WHY — the log could not
        // distinguish "the model emitted zero tokens" from "tokens were produced and swallowed"
        // (by a stop sequence at position 0, the circuit breaker, or a tool call the framework
        // parsed and dropped). A field report showed five of these in a row with 2.4-9.4s of
        // generation each, which is not the signature of a model emitting nothing, and there was
        // no way to tell from the log which it was. Yielded-chars is the discriminator.
        // Framework-reported facts, when the completion event arrived. `generated` is the ONLY
        // thing that separates the two very different failures below.
        let generated = lastInfo?.generationTokenCount
        let stopReason = lastInfo.map { String(describing: $0.stopReason) } ?? "unknown"
        let timing = lastInfo.map {
            String(format: "prefill %.2fs/%d tok, decode %.2fs/%d tok",
                   $0.promptTime, $0.promptTokenCount, $0.generateTime, $0.generationTokenCount)
        } ?? "timings unavailable"

        if yieldedChars == 0 {
            // ⚠️ DO NOT INFER THE VERDICT FROM EVENT COUNTS. An earlier version of this log declared
            // "the model generated NOTHING (immediate EOS)" purely because textChunks==0 &&
            // toolCalls==0, and sent the operator to the sampling settings on that basis. Those
            // counters are ALSO what a swallowed generation looks like:
            //
            //   MLXLMCommon.ToolCallProcessor buffers every chunk from `<tool_call>` onward and
            //   returns nil while collecting. If the closing `</tool_call>` never arrives, or the
            //   JSON between the tags fails to decode as ToolCall.Function (which requires exactly
            //   `name` + `arguments` — a model writing `parameters` fails it), then `processEOS()`
            //   parses the buffer, finds no tool call, and `onGenerationEnd` emits ONLY tool calls.
            //   The buffered TEXT is dropped on the floor. Nothing is logged by the framework.
            //
            // The completion event's generationTokenCount tells the two apart with certainty, so
            // this branches on evidence instead of asserting the more convenient explanation.
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
                        + "NOT the cause. The prime suspect is MLXLMCommon's ToolCallProcessor: it "
                        + "buffers from `<tool_call>` onward and silently drops the buffer when the "
                        + "JSON inside fails to decode as ToolCall.Function (`name` + `arguments`, "
                        + "both required — `parameters` instead of `arguments` fails it). Also check "
                        + "the stop sequences and the circuit breaker"
            }
            logger.error("[MLX-GEN] Generation produced NO output — generatedTokens=\(generated.map(String.init) ?? "unknown") stopReason=\(stopReason), \(timing) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount) infoEvents=\(infoEventCount) (total events \(chunkCount)), stopSequenceHit=\(stopDetected), circuitBreaker=\(circuitBreaker.hasTripped), trailingWindow=\(trailingWindow.count) chars. DIAGNOSIS: \(verdict). CONSEQUENCE: the caller throws GenerationError.emptyResponse, which aborts the run after 3 attempts without charging the parse budget.")
        } else if infoEventCount == 0 {
            // Text WAS yielded but the framework's terminal `.info` event never arrived — the
            // stream ended before completing. On-device this is the teardown shape: the consumer
            // was cancelled mid-generation (Stop, node timeout, or per-node skip) and the yielded
            // text is a PARTIAL that goes nowhere. Logging it as a plain "complete" with
            // "unknown" counts read as a diagnostic dead-end (observed 2026-08-22).
            logger.notice("[MLX-GEN] Generation ended WITHOUT a completion event — \(yieldedChars) chars yielded then the stream stopped (Task.isCancelled=\(Task.isCancelled)) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount), stopSequenceHit=\(stopDetected). CONSEQUENCE: token counts and timings are unavailable and the yielded text is PARTIAL — cancelled mid-generation (Stop / node timeout / per-node skip) if isCancelled is true, otherwise a framework fault worth reporting.")
        } else {
            logger.debug("[MLX-GEN] Generation complete — \(yieldedChars) chars yielded, generatedTokens=\(generated.map(String.init) ?? "unknown") stopReason=\(stopReason), \(timing) | textChunks=\(textChunkCount) toolCalls=\(toolCallCount) infoEvents=\(infoEventCount), stopSequenceHit=\(stopDetected).")
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
    /// the actor's Sendable path) and attached to the LAST user turn.
    ///
    /// Generation runs through the SAME safety consumer as `streamChat` — stop
    /// sequences + circuit breaker + repetition penalty — because an image-bearing
    /// turn on the AGENT path still runs a full ReAct loop over a small quantized VLM,
    /// exactly the population those layers protect. (The one text-path layer that does
    /// NOT apply here is the `applyChatTemplate` two-tier fallback: the VLM's own
    /// `UserInputProcessor` owns templating on this path, so there is no
    /// `ChatTemplateSource` to fall back through.)
    /// - Parameter expectedModelDirectory: the model this request was configured for. When
    ///   supplied, the generation is served by THAT model or it throws — it is never answered
    ///   by whichever model happens to be resident. Nil preserves the legacy behaviour and
    ///   logs a warning; see `container(expecting:)`.
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
            // ⚠️ The producer handle MUST be captured and cancelled on termination.
            // Without this, pressing Stop unwound the consumer while the model kept
            // decoding on the GPU until EOS / a stop sequence / maxTokens — discarding
            // every token, holding `activeGenerations > 0` so `unloadModel()` refused,
            // and making the user's NEXT message decode concurrently with the orphan on
            // the same GPU at roughly half token rate. The vendored evaluator already
            // breaks on `Task.isCancelled`; nothing was ever cancelling it.
            let producer = Task {
                activeGenerations += 1
                defer { activeGenerations -= 1 }

                // Lazy reload: an idle-timer unload between iterations (HITL park,
                // long tool run) recovers inline instead of failing the request into
                // the retry classifier — no wasted generation attempt, no error card.
                // Now identity-checked: see `container(expecting:)`.
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

                    // Convert MLX C++ fatal errors (e.g. a VLM shape/broadcast mismatch)
                    // into a Swift throw instead of `fatalError` crashing the whole app.
                    // `withError` installs a TASK-LOCAL handler; the internal generation
                    // `Task` that `MLXLMCommon.generate` spawns is created inside this scope
                    // and inherits it, so an error raised in the forward pass is recorded and
                    // rethrown here rather than aborting the process. MUST wrap BOTH the
                    // perform (where the Task is created) and the consume (where it runs).
                    try await withError {
                    let stream = try await container.perform { context -> AsyncStream<Generation> in
                        // Decode raw bytes → CIImage → UserInput.Image inside the closure.
                        // Mirror the reference mlx-swift-lm apps: hand the VLM a CGImage-backed
                        // image (materialized pixel buffer + finite [0,0,w,h] extent) rather than a
                        // bare CIImage(data:), so the shared MLXVLM.asMLXArray derives its array
                        // shape from a concrete extent. Each image is logged with extent/bytes/
                        // colorspace; an undecodable slot is logged as DROPPED so a later
                        // placeholder/feature-count divergence is traceable to a lost image.
                        let images: [UserInput.Image] = wrappedData.value.enumerated().compactMap { (idx, data) in
                            Self.decodeVisionImage(data, index: idx, logger: self.logger)
                        }
                        if images.count != wrappedData.value.count {
                            self.logger.error("[VISION] decoded \(images.count)/\(wrappedData.value.count) image(s); \(wrappedData.value.count - images.count) DROPPED — prompt placeholders will outnumber vision features downstream")
                        }

                        // Rebuild the chat, attaching the images to the final user turn.
                        // Fall back to the last message when NO user turn exists — the
                        // previous `i == lastUserIdx` with an `Int?` compared every index
                        // to nil, which is always false, so a malformed (system-only /
                        // assistant-terminated) array dropped every image silently.
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

                        // [VISION] Instrumentation around the crash-prone hop. The MLX vision
                        // runtime does NOT reproduce this crash from an isolated harness (verified:
                        // every image size/format/multi-image case either succeeds or throws
                        // catchably), so the app must self-report enough to pin the trigger on a
                        // real crash. A hard crash BETWEEN the PRE and POST lines localizes the
                        // fault to `processor.prepare`; a crash after "starting forward" with no
                        // token output localizes it to the first `generate` eval. `visionFeatures`
                        // (the pixel-tensor leading dim) vs `promptTokens` lets us spot a
                        // placeholder↔feature count divergence — the documented VLM failure family.
                        let activeBefore = MLX.Memory.activeMemory
                        let cacheBefore = MLX.Memory.cacheMemory
                        self.logger.info("[VISION] prepare PRE — images=\(images.count), MLX active=\(ByteCountFormatter.string(fromByteCount: Int64(activeBefore), countStyle: .memory)), cache=\(ByteCountFormatter.string(fromByteCount: Int64(cacheBefore), countStyle: .memory))")
                        let lmInput = try await context.processor.prepare(input: userInput)
                        let pixShape = lmInput.image?.pixels.shape ?? []
                        let promptLen = lmInput.text.tokens.shape.last ?? 0
                        let activeAfter = MLX.Memory.activeMemory
                        self.logger.info("[VISION] prepare POST — promptTokens=\(promptLen), visionFeatures(pixels)=\(pixShape), MLX active=\(ByteCountFormatter.string(fromByteCount: Int64(activeAfter), countStyle: .memory)) (Δ=\(ByteCountFormatter.string(fromByteCount: Int64(activeAfter) - Int64(activeBefore), countStyle: .memory)))")

                        // ⚠️ ROOT-CAUSE FIX (reproduced on-device 2026-07-22): drop the library
                        // repetition penalty on the VISION path. mlx-swift-lm 3.31.3's
                        // `RepetitionContext.TokenRing.loadPrompt` reads `prompt.dim(0)`, but every
                        // VLM `UserInputProcessor` builds `LMInput.text.tokens` as 2-D `[1, seqLen]`
                        // (`MLXArray(promptTokens).expandedDimensions(axis: 0)`). So `dim(0)` is the
                        // BATCH dim (1), not `seqLen`; the guard `n <= capacity` mis-fires and the
                        // ring buffer is built as `[seqLen + repCtx - 1]` instead of `[repCtx]`. The
                        // first `didSample → append` then evaluates
                        // `MLX.where(positions[repCtx], token, buffer[seqLen+repCtx-1])` →
                        // `Fatal error: [broadcast_shapes] Shapes (repCtx) and (seqLen+repCtx-1)` —
                        // the exact reported crash (repCtx=25 → the "(25)"; the other number is
                        // promptTokens+24). Under MLX lazy eval the corrupted shape can instead
                        // surface downstream as an uncatchable `Index out of range` 0-dim slice
                        // (MLXArray+Indexing.swift:551) — hence "crashed two ways across runs". The
                        // TEXT path passes 1-D tokens so `dim(0) == seqLen` and is unaffected.
                        // We can't durably patch the vendored checkout (lost on SPM re-resolve), so
                        // we disable the penalty here. Runaway repetition on this small-quantized-VLM
                        // population is still bounded by the StreamingCircuitBreaker + stop sequences
                        // in `consumeGenerationStream` (added for exactly this reason).
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
                        return try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                    }

                    await self.consumeGenerationStream(stream, into: continuation, stopSequences: stopSequences, onUsage: onUsage)
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

    /// Decodes raw image bytes into a `UserInput.Image` for the VLM processor.
    ///
    /// The reference mlx-swift-lm apps feed a VLM a file URL (decoded via
    /// `CIImage(contentsOf:)`) or a CGImage-backed image — never a bare
    /// `CIImage(data:)`. We mirror that: rendering the decoded image through a
    /// CGImage guarantees the `CIImage` handed to the shared
    /// `MLXVLM.MediaProcessing` pipeline carries a materialized pixel buffer and a
    /// concrete, finite `[0,0,w,h]` extent — the value `asMLXArray` reads to derive
    /// the array shape. Falls back to the raw `CIImage(data:)` when a CGImage can't
    /// be produced, and returns `nil` (logging the consequence) when the bytes can't
    /// be decoded at all — a dropped image the caller must account for.
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

    // Tool-schema bridging + the instance-stability cache live in `BridgedToolsStore` —
    // including the measured proof of WHY it must be an instance cache and not key sorting.

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
        // Never unload under an in-flight generation. The timer can fire during
        // an actor-reentrancy window mid-stream — run-1 logs showed the unload
        // proceeding even though the incoming request's cancel had arrived.
        guard activeGenerations == 0 else {
            logger.notice("Idle timeout while \(self.activeGenerations) generation(s) in flight — keeping model, re-arming timer.")
            startIdleTimer()
            return
        }

        // Parked-HITL runs: unloading is DESIRED (frees 4-6GB while the user
        // decides at the banner); the lazy reload at generation entry recovers
        // on resume without a failed attempt. The check only selects the log
        // message so testers can tell the two cases apart — both paths unload.
        if await ExecutionSuspensionService.shared.hasPendingSuspensions() {
            logger.notice("MLX idle timeout during a parked HITL request — releasing memory; the model lazy-reloads when the run resumes.")
        } else {
            logger.notice("MLX Service has been idle for \(self.idleTimeoutDescription). Releasing memory.")
        }
        _ = unloadModel()
    }
}
