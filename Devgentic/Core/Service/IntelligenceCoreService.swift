//
//  IntelligenceCoreService.swift
//  Devgentic
//
//  Created by Antigravity on 12/03/26.
//

import Foundation
import MLX
import MLXLLM
@preconcurrency import MLXLMCommon
import os

// MARK: - IC Caller Identification

/// Identifies which feature is invoking the Intelligence Core.
/// Used for structured logging and diagnostics.
enum ICCallerFeature: String, Sendable {
    case ragRewriting = "RAG Query Rewriting"
    case morningBrief = "Morning Brief"
    case suggestion = "Context-Aware Suggestion"
    case userPersonal = "User Personal"
    case responseSynthesis = "Response Synthesis"
    case historyCompaction = "History Compaction"
    case unknown = "Unknown"
}

/// A service for managing the Intelligence Core MLX model.
/// Uses whichever model the user has selected in Core Intelligence settings
/// from the standard MLX Model Store — no bundled/built-in model.
actor IntelligenceCoreService {

    static let shared = IntelligenceCoreService()

    private let logger = DGLogger(category: "IntelligenceCoreService")

    private var modelContainer: ModelContainer?

    /// Tracks which feature currently holds the model in memory.
    private var currentCaller: ICCallerFeature?

    /// Timestamp when the model was last loaded — used to calculate session duration.
    private var loadTimestamp: Date?

    /// Cumulative inference count since app launch.
    private var totalInferenceCount: Int = 0

    private init() {}

    // MARK: - Model Resolution

    /// The user-selected model name from UserDefaults, or empty if none selected.
    private var selectedModelName: String {
        UserDefaults.standard.string(forKey: AppSettings.coreIntelligenceModelKey) ?? ""
    }

    /// Whether a model has been selected in Core Intelligence settings.
    var hasModelSelected: Bool {
        !selectedModelName.isEmpty
    }

    /// Resolves the local path of the selected model from MLXModelService.
    private func resolveModelPath() async -> URL? {
        let modelName = selectedModelName
        guard !modelName.isEmpty else { return nil }
        // See AgentConnect: the scan is off-actor, so wait for it rather than risk
        // reading an empty list and rejecting a model that is installed.
        await MLXModelService.shared.ensureLoaded()
        return await MainActor.run {
            MLXModelService.shared.installedModel(named: modelName)?.localPath
        }
    }

    // MARK: - Memory Snapshot

    /// Captures a snapshot of current memory state for logging.
    private func memorySnapshot() -> (available: String, gpuCache: String) {
        let profile = SystemHardwareProfiler.shared.profile
        let gpuActive = MLX.GPU.activeMemory
        let gpuCache = MLX.GPU.cacheMemory
        let availableStr = profile.formattedAvailableRAM
        let gpuStr = "active=\(ByteCountFormatter.string(fromByteCount: Int64(gpuActive), countStyle: .memory)), cache=\(ByteCountFormatter.string(fromByteCount: Int64(gpuCache), countStyle: .memory))"
        return (availableStr, gpuStr)
    }

    // MARK: - Model Lifecycle

    /// Loads the user-selected model into memory.
    /// - Parameter caller: The feature requesting the load — used for diagnostics.
    func load(caller: ICCallerFeature = .unknown) async throws {
        // Any new demand cancels a pending idle free — this is what lets a turn's
        // sequential IC features (RAG rewrite → compaction → synthesis) share one load.
        cancelIdleRelease()
        releasePolicy.didLoad()

        if modelContainer != nil {
            logger.info("[IC Load] Model already in memory — reusing for \(caller.rawValue). Previous caller: \(self.currentCaller?.rawValue ?? "none")")
            currentCaller = caller
            return
        }

        guard hasModelSelected else {
            logger.error("[IC Load] REJECTED — No model selected. Caller: \(caller.rawValue)")
            throw NSError(
                domain: "IntelligenceCoreService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "No Intelligence Core model selected. Choose one in Settings → Core Intelligence."]
            )
        }

        guard let localPath = await resolveModelPath() else {
            logger.error("[IC Load] REJECTED — Model '\(self.selectedModelName)' not found on disk. Caller: \(caller.rawValue)")
            throw NSError(
                domain: "IntelligenceCoreService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Selected model '\(selectedModelName)' not found. It may have been deleted from the Model Store."]
            )
        }

        let preMemory = memorySnapshot()
        let loadStart = CFAbsoluteTimeGetCurrent()

        logger.notice("[IC Load] BEGIN — Model: \(self.selectedModelName), Caller: \(caller.rawValue)")
        logger.info("[IC Load] Pre-load memory — System: \(preMemory.available), GPU: \(preMemory.gpuCache)")

        // mlx-swift-lm 3.x: `loadModelContainer(from:using:)` replaces the old
        // `loadModelContainer(configuration:)`. The tokenizer loader is our own bridge
        // backed by swift-transformers' AutoTokenizer (see MLXTokenizerBridge.swift).
        let container = try await MLXLMCommon.loadModelContainer(
            from: localPath,
            using: HuggingFaceTokenizerLoader()
        )
        self.modelContainer = container
        self.currentCaller = caller
        self.loadTimestamp = Date()

        let loadDuration = CFAbsoluteTimeGetCurrent() - loadStart
        let postMemory = memorySnapshot()

        logger.notice("[IC Load] COMPLETE — \(String(format: "%.2f", loadDuration))s, Caller: \(caller.rawValue)")
        logger.info("[IC Load] Post-load memory — System: \(postMemory.available), GPU: \(postMemory.gpuCache)")
    }

    // MARK: - Release Policy
    //
    // The IC model is shared by several features that run SEQUENTIALLY within a single
    // chat turn (RAG query rewriting → history compaction → response synthesis). Freeing
    // the model the instant each one finishes made every turn pay 2-3 multi-second MLX
    // loads, so `releaseHold` only marks the model *releasable*: the actual free happens
    // after an idle grace period, and any new load cancels it. A turn's features therefore
    // share ONE load, while an idle app still gives the memory back.
    //
    // `activeLeases` additionally guarantees a feature can never free the model out from
    // under another's in-flight generation. That was previously possible: `unload` nil'd
    // the container and called `MLX.GPU.clearCache()` unconditionally. The generation
    // itself survived (it captures the container before its first suspension) but the
    // cache was cleared mid-inference and the next caller reloaded a resident model.

    /// Seconds the model stays resident after the last feature releases it.
    private static let idleReleaseSeconds: Double = 60

    /// Residency decision table — see `ICReleasePolicy` (pure, unit-tested).
    private var releasePolicy = ICReleasePolicy()

    /// Pending idle free. Cancelled by any new load.
    private var idleReleaseTask: Task<Void, Never>?

    private func beginLease() {
        releasePolicy.beginLease()
        cancelIdleRelease()
    }

    private func endLease(caller: ICCallerFeature) {
        apply(releasePolicy.endLease(), caller: caller, reason: "last generation finished")
    }

    private func cancelIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = nil
    }

    /// Performs whatever the policy decided.
    private func apply(_ action: ICReleasePolicy.Action, caller: ICCallerFeature, reason: String) {
        switch action {
        case .none:
            if releasePolicy.activeLeases > 0 {
                logger.info("[IC Release] Release requested by \(caller.rawValue), but \(self.releasePolicy.activeLeases) generation(s) still in flight — deferred until they finish.")
            }
        case .scheduleIdleRelease:
            scheduleIdleRelease(caller: caller)
        case .freeNow:
            cancelIdleRelease()
            performUnload(caller: caller, reason: reason)
        }
    }

    private func scheduleIdleRelease(caller: ICCallerFeature) {
        cancelIdleRelease()
        guard modelContainer != nil else { return }
        let seconds = Self.idleReleaseSeconds
        logger.info("[IC Release] Idle release scheduled in \(Int(seconds))s — requested by: \(caller.rawValue). Any request before then reuses the loaded model.")
        idleReleaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performIdleRelease(caller: caller)
        }
    }

    private func performIdleRelease(caller: ICCallerFeature) {
        // Re-checked under actor isolation: demand may have arrived while we slept.
        guard !Task.isCancelled, releasePolicy.shouldHonorElapsedIdleRelease else {
            logger.info("[IC Release] Idle release skipped — model is back in use (leases: \(self.releasePolicy.activeLeases)).")
            return
        }
        performUnload(caller: caller, reason: "idle for \(Int(Self.idleReleaseSeconds))s")
    }

    /// Signals that `caller` is finished with the model. Does NOT free immediately — see
    /// the release-policy note above. Safe to call while other features are mid-flight.
    func releaseHold(caller: ICCallerFeature = .unknown) {
        apply(releasePolicy.requestRelease(), caller: caller, reason: "released by \(caller.rawValue)")
    }

    /// Frees the model as soon as it is safe to do so, skipping the idle grace period.
    /// For deliberate teardown — Core Intelligence switched off, or the IC model changed,
    /// where lingering residency would let the next inference reuse the OLD model.
    func unloadNow(caller: ICCallerFeature = .unknown) {
        apply(releasePolicy.requestImmediateRelease(), caller: caller, reason: "immediate teardown")
    }

    /// Unloads the model from memory and clears GPU cache.
    /// - Parameter caller: The feature requesting the unload.
    private func performUnload(caller: ICCallerFeature = .unknown, reason: String) {
        cancelIdleRelease()
        releasePolicy.didFree()

        guard modelContainer != nil else {
            logger.debug("[IC Unload] No-op — model not loaded. Caller: \(caller.rawValue)")
            return
        }

        let preMemory = memorySnapshot()
        let sessionDuration: String
        if let loadTime = loadTimestamp {
            let elapsed = Date().timeIntervalSince(loadTime)
            sessionDuration = String(format: "%.1fs", elapsed)
        } else {
            sessionDuration = "unknown"
        }

        modelContainer = nil
        MLX.GPU.clearCache()

        let postMemory = memorySnapshot()

        logger.notice("[IC Unload] Model released — Session: \(sessionDuration), Reason: \(reason), Loaded by: \(self.currentCaller?.rawValue ?? "unknown"), Unloaded by: \(caller.rawValue)")
        logger.info("[IC Unload] Memory freed — Before GPU: \(preMemory.gpuCache) → After GPU: \(postMemory.gpuCache)")

        currentCaller = nil
        loadTimestamp = nil
    }

    // MARK: - Inference

    /// Generates a response from the Intelligence Core model (collects all tokens).
    /// - Parameters:
    ///   - messages: Chat messages in `[role: content]` format.
    ///   - maxTokens: Maximum tokens to generate.
    ///   - temperature: Sampling temperature.
    ///   - caller: The feature requesting generation.
    func generate(messages: [[String: String]], maxTokens: Int = 1024, temperature: Float = 0.6, caller: ICCallerFeature = .unknown) async throws -> String {
        try await load(caller: caller)

        guard let container = modelContainer else {
            throw NSError(domain: "IntelligenceCoreService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model container not available."])
        }

        // Hold a lease for the whole generation so no other feature can free the model (or
        // clear the GPU cache) mid-inference. `defer` covers the throwing paths too.
        beginLease()
        defer { endLease(caller: caller) }

        let genStart = CFAbsoluteTimeGetCurrent()
        let promptTokenCount = messages.reduce(0) { $0 + ($1["content"]?.count ?? 0) / 4 } // Rough estimate
        totalInferenceCount += 1
        let inferenceNum = totalInferenceCount

        logger.notice("[IC Generate #\(inferenceNum)] BEGIN — Caller: \(caller.rawValue), maxTokens: \(maxTokens), temp: \(temperature), ~promptTokens: \(promptTokenCount)")

        let wrapped = UnsafeSendable(messages)
        let result = try await container.perform { context in
            let promptTokens = try context.tokenizer.applyChatTemplate(messages: wrapped.value.map { $0 as [String: any Sendable] })
            let lmInput = LMInput(tokens: MLXArray(promptTokens))
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: temperature)

            let stream = try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            )

            var fullText = ""
            for await generation in stream {
                if case .chunk(let text) = generation {
                    fullText += text
                }
            }
            return fullText
        }

        let genDuration = CFAbsoluteTimeGetCurrent() - genStart
        let outputTokenEstimate = result.count / 4
        let tokPerSec = genDuration > 0 ? Double(outputTokenEstimate) / genDuration : 0

        logger.notice("[IC Generate #\(inferenceNum)] COMPLETE — \(String(format: "%.2f", genDuration))s, ~\(outputTokenEstimate) output tokens, ~\(String(format: "%.1f", tokPerSec)) tok/s, Caller: \(caller.rawValue)")

        let postMemory = memorySnapshot()
        logger.info("[IC Generate #\(inferenceNum)] Post-generate GPU: \(postMemory.gpuCache)")

        return result
    }
}
